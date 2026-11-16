import CoreKit
import CoreLocation
import Foundation
import AMapFoundationKit
import AMapSearchKit

public struct RouteResult: Sendable {
    public var routes: [RouteOption]
    public var failure: NavFailure?
}

/// 算路服务：高德搜索 SDK 标准路径规划接口（驾车 AMapDrivingRouteSearch /
/// 步行 AMapWalkingRouteSearch / 骑行 AMapRidingRouteSearch），多方案按引擎
/// 返回，不复制凑数（NAV-17/18/21）。
///
/// 高德搜索 SDK 是回调式（AMapSearchDelegate），这里用 Continuation 桥接成
/// async；同一时刻每请求独立 AMapSearchAPI 实例，互不串扰。
@MainActor
public final class RouteService: NSObject, AMapSearchDelegate {

    override public init() {
        super.init()
        Self.active = self
    }

    // MARK: - 请求上下文（request → continuation 映射）

    private final class PendingRequest {
        let id: String
        let continuation: CheckedContinuation<AMapRouteSearchResponse?, Never>
        init(id: String, continuation: CheckedContinuation<AMapRouteSearchResponse?, Never>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private var pending: [ObjectIdentifier: PendingRequest] = [:]
    /// 持有在途 AMapSearchAPI 实例防止过早释放（SDK 弱引用 delegate，实例释放则回调丢失）
    private var activeSearches: [ObjectIdentifier: AMapSearchAPI] = [:]
    private var apiCounter = 0

    public func routes(from origin: Place,
                       to destination: Place,
                       mode: TravelMode,
                       requestId: String) async -> RouteResult {
        guard origin.hasValidCoordinate, destination.hasValidCoordinate else {
            return RouteResult(routes: [], failure: .invalidPlace)
        }

        // 高德规划接口吃 GCJ-02 坐标（Place.gcj02Coordinate 已统一转换）
        let originPoint = AMapGeoPoint.location(withLatitude: origin.gcj02Coordinate.latitude,
                                                longitude: origin.gcj02Coordinate.longitude)
        let destPoint = AMapGeoPoint.location(withLatitude: destination.gcj02Coordinate.latitude,
                                              longitude: destination.gcj02Coordinate.longitude)

        let request: AMapRouteSearchBaseRequest
        switch mode {
        case .driving:
            let driving = AMapDrivingRouteSearchRequest()
            // 10：多备选（时间最短/距离最短/躲避拥堵），返回 1~3 条方案
            driving.strategy = 10
            request = driving
        case .walking:
            let walking = AMapWalkingRouteSearchRequest()
            walking.alternativeRoute = 1   // 多备选
            request = walking
        case .cycling:
            let riding = AMapRidingRouteSearchRequest()
            request = riding
        }
        request.origin = originPoint
        request.destination = destPoint

        // 桥接回调 → async（带 15s 超时：SDK 偶发不回调时取消在途请求，UI 可重试）
        let response: AMapRouteSearchResponse? = await Self.withTimeout(seconds: 15) {
            await self.dispatch(request: request)
        }
        guard let response else {
            return RouteResult(routes: [], failure: .serviceError)
        }

        let options = Self.options(from: response, mode: mode, requestId: requestId)
        guard !options.isEmpty else {
            return RouteResult(routes: [], failure: .noRoute)
        }
        return RouteResult(routes: options, failure: nil)
    }

    /// 发起一次规划请求并等待回调
    private func dispatch(request: AMapRouteSearchBaseRequest) async -> AMapRouteSearchResponse? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AMapRouteSearchResponse?, Never>) in
            guard let search = AMapSearchAPI() else {
                Log.error("[AMapRoute] AMapSearchAPI 初始化失败")
                continuation.resume(returning: nil)
                return
            }
            search.delegate = self
            search.timeout = 14   // SDK 侧超时略小于外层竞速超时
            apiCounter += 1
            let key = ObjectIdentifier(search)
            // ⚠️ 必须持有 API 实例直到回调：局部变量在闭包结束后释放，
            // SDK 异步回调时对象已销毁，onRouteSearchDone 永远不会触发。
            activeSearches[key] = search
            pending[key] = PendingRequest(id: "api-\(apiCounter)", continuation: continuation)
            Log.info("[AMapRoute] 发起规划请求 #\(apiCounter)")
            switch request {
            case let driving as AMapDrivingRouteSearchRequest:
                search.aMapDrivingRouteSearch(driving)
            case let walking as AMapWalkingRouteSearchRequest:
                search.aMapWalkingRouteSearch(walking)
            case let riding as AMapRidingRouteSearchRequest:
                search.aMapRidingRouteSearch(riding)
            default:
                activeSearches.removeValue(forKey: key)
                pending.removeValue(forKey: key)
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - AMapSearchDelegate

    nonisolated public func onRouteSearchDone(_ request: AMapRouteSearchBaseRequest,
                                              response: AMapRouteSearchResponse) {
        Log.info("[AMapRoute] 收到规划回调")
        Task { @MainActor in
            self.finishPending(response: response)
        }
    }

    nonisolated public func aMapSearchRequest(_ request: Any!, didFailWithError error: Error) {
        Log.error("[AMapRoute] 规划请求失败: \(error.localizedDescription)")
        Task { @MainActor in
            self.finishPending(response: nil)
        }
    }

    private func finishPending(response: AMapRouteSearchResponse?) {
        // 在途通常只有一个请求（引擎串行调用）；多请求并发时按先进先出消费
        guard let key = pending.keys.first,
              let item = pending.removeValue(forKey: key) else { return }
        activeSearches.removeValue(forKey: key)   // 回调完成，释放 SDK 实例
        item.continuation.resume(returning: response)
    }

    /// 超时兜底：operation 是回调桥接（continuation 挂起，不可取消），TaskGroup 的
    /// cancelAll() 对它无效 —— 所以超时返回 nil 的同时必须**主动结束在途请求**
    ///（SDK 侧 cancelAllRequests 触发错误回调清掉 pending），否则：
    ///   ① continuation 永久悬挂 → async 链卡死，UI 永远「正在规划」；
    ///   ② 迟到的回调 resume 已超时的 continuation → 崩溃（Continuation leak）。
    private nonisolated static func withTimeout(seconds: TimeInterval,
                                                operation: @escaping () async -> AMapRouteSearchResponse?) async -> AMapRouteSearchResponse? {
        await withTaskGroup(of: TimeoutRace.self) { group in
            group.addTask {
                let value = await operation()
                return .value(value)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            switch first {
            case .value(let value):
                return value
            case .timedOut:
                Log.warn("[AMapRoute] 规划请求超时（\(Int(seconds))s），取消在途请求")
                await MainActor.run { RouteService.active?.cancelAll() }
                return nil
            }
        }
    }

    private enum TimeoutRace {
        case value(AMapRouteSearchResponse?)
        case timedOut
    }

    /// 弱引用宿主，供超时路径取消在途 SDK 请求（RouteService 是 MainActor 单例生命周期）
    private static weak var active: RouteService?

    /// 超时路径专用：清空在途请求并以 nil 结束全部 continuation（MainActor 隔离）
    private func cancelAll() {
        guard !pending.isEmpty else { return }
        let waiters = pending
        pending.removeAll()
        activeSearches.removeAll()   // 释放 SDK 实例（其内部请求随实例销毁）
        // 全部以 nil 结束（超时失败）；迟到的 SDK 回调因 pending 已空被安全忽略
        for item in waiters.values {
            item.continuation.resume(returning: nil)
        }
    }

    // MARK: - 响应 → RouteOption（NAV-17/18）

    private static func options(from response: AMapRouteSearchResponse,
                                mode: TravelMode,
                                requestId: String) -> [RouteOption] {
        var options: [RouteOption] = []
        var seenSignatures = Set<String>()
        for (index, path) in (response.route?.paths ?? []).enumerated() {
            let polyline = Self.coordinates(from: path)
            guard polyline.count >= 2 else { continue }
            // 重复线过滤：几何签名一致视为同一条（NAV-17）
            let signature = Self.signature(polyline)
            if seenSignatures.contains(signature) { continue }
            seenSignatures.insert(signature)

            let steps = Self.steps(from: path, routeId: requestId)
            let option = RouteOption(
                id: "\(requestId)#\(index)",
                mode: mode,
                distance: Double(path.distance),
                expectedTravelTime: Double(path.duration),
                steps: steps,
                polyline: polyline,
                engineLabel: index == 0 ? (path.strategy ?? "推荐") : "备选\(index)",
                requestId: requestId)
            options.append(option)
            if options.count >= 3 { break }
        }
        return options
    }

    /// path.steps[].polyline（"lng,lat;lng,lat;..."）→ 坐标数组（GCJ-02）
    static func coordinates(from path: AMapPath) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for step in path.steps ?? [] {
            result.append(contentsOf: coordinates(fromPolylineString: step.polyline))
        }
        return result
    }

    static func coordinates(fromPolylineString polyline: String?) -> [CLLocationCoordinate2D] {
        guard let polyline, !polyline.isEmpty else { return [] }
        var result: [CLLocationCoordinate2D] = []
        for pair in polyline.components(separatedBy: ";") {
            let parts = pair.components(separatedBy: ",")
            guard parts.count == 2,
                  let lon = Double(parts[0]), let lat = Double(parts[1]) else { continue }
            result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return result
    }

    static func steps(from path: AMapPath, routeId: String) -> [NavStep] {
        let steps = path.steps ?? []
        var result: [NavStep] = []
        for (index, step) in steps.enumerated() {
            let coords = coordinates(fromPolylineString: step.polyline)
            guard let end = coords.last else { continue }
            let isArrival = index == steps.count - 1
            let rawInstruction = step.instruction ?? ""
            let instruction = rawInstruction.isEmpty
                ? (isArrival ? "到达目的地" : "继续前行")
                : rawInstruction
            result.append(NavStep(id: "\(routeId)#\(index)",
                                  index: index,
                                  instruction: instruction,
                                  distance: Double(step.distance),
                                  coordinate: end,
                                  roadName: step.road ?? "",
                                  isArrivalStep: isArrival))
        }
        return result
    }

    static func signature(_ polyline: [CLLocationCoordinate2D]) -> String {
        guard let first = polyline.first, let last = polyline.last else { return "empty" }
        let length = Int(Geo.length(of: polyline).rounded())
        return String(format: "%.4f,%.4f-%.4f,%.4f-%d",
                      first.latitude, first.longitude, last.latitude, last.longitude, length)
    }
}
