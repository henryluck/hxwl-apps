import CoreLocation
import CoreKit
import Foundation
import UIKit

/// 定位状态（NAV-03：未询问/使用期间/仅一次/拒绝/限制/系统关闭/近似/设置撤回分别处理）
public enum LocationAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case servicesOff
    case approximate      // 近似位置：不等于拒绝

    public var isUsable: Bool {
        self == .authorized || self == .approximate
    }

    public var guidance: String? {
        switch self {
        case .notDetermined: return nil
        case .authorized: return nil
        case .denied: return "请在设置中允许使用位置"
        case .restricted: return "定位权限受限，请检查系统限制"
        case .servicesOff: return "请开启系统定位服务"
        case .approximate: return "当前为近似位置，可打开精确定位提高准确度"
        }
    }
}

/// 定位服务：单次定位与连续定位分离，权限/服务状态真实读取（NAV-03/04/26）
@MainActor
public final class LocationService: NSObject, ObservableObject {
    @Published public private(set) var authState: LocationAuthState = .notDetermined
    @Published public private(set) var snapshot: LocationSnapshot?
    @Published public private(set) var heading: Double?          // 真北角度
    @Published public private(set) var magneticHeading: Double?
    @Published public private(set) var isLocating = false
    @Published public private(set) var lastError: NavFailure?
    /// 连续定位是否在跑（活动导航期间为 true）
    @Published public private(set) var isContinuous = false

    private let manager = CLLocationManager()
    /// 单次定位在途的等待者（可多个并发复用同一结果）
    private var singleFixContinuations: [CheckedContinuation<LocationSnapshot?, Never>] = []
    private var singleFixTimeout: Task<Void, Never>?
    private var continuousHandler: ((LocationSnapshot) -> Void)?
    /// 授权等待者（notDetermined 弹窗期间挂起，用户选择或超时后一起唤醒）
    private var authWaiters: [CheckedContinuation<Bool, Never>] = []
    private var authTimeout: Task<Void, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        refreshAuthState()
    }

    // MARK: - 权限

    public func refreshAuthState() {
        guard CLLocationManager.locationServicesEnabled() else {
            authState = .servicesOff
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined: authState = .notDetermined
        case .restricted: authState = .restricted
        case .denied: authState = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            authState = manager.accuracyAuthorization == .reducedAccuracy ? .approximate : .authorized
        @unknown default: authState = .notDetermined
        }
    }

    /// 功能触发时才解释并请求（首页不强制索权，NAV-03）
    public func requestAuthorization() {
        refreshAuthState()
        if authState == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 请求授权并等待用户给出明确结果（或超时）。
    /// - 返回 true：权限已可用（authorized/approximate）
    /// - 返回 false：仍未授权（拒绝/受限/系统关闭/超时未响应）
    public func waitForAuthorization(timeout: TimeInterval = 30) async -> Bool {
        refreshAuthState()
        if authState.isUsable { return true }
        if authState != .notDetermined { return false }

        requestAuthorization()
        let granted: Bool = await withCheckedContinuation { cont in
            authWaiters.append(cont)
            authTimeout?.cancel()
            authTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.finishAuthWait(granted: self.authState.isUsable)
                }
            }
        }
        return granted
    }

    /// 唤醒所有授权等待者（授权回调或超时；只结算一次）
    private func finishAuthWait(granted: Bool) {
        authTimeout?.cancel()
        authTimeout = nil
        let waiters = authWaiters
        authWaiters.removeAll()
        for cont in waiters {
            cont.resume(returning: granted)
        }
    }

    // MARK: - 单次定位（NAV-04：并发请求共享同一次系统调用，无轮询、无泄漏）

    /// 有快照且仍然新鲜（可作为规划起点）时直接复用，不再发起系统定位
    private func freshSnapshot() -> LocationSnapshot? {
        guard let snap = snapshot, snap.isUsable else { return nil }
        return snap
    }

    /// 有在途定位时加入等待列表，随该次定位一起返回（可能为 nil）
    private func joinInFlightFix() async -> LocationSnapshot? {
        await withCheckedContinuation { cont in
            singleFixContinuations.append(cont)
        }
    }

    /// 结束本轮单次定位：唤醒所有等待者并清理状态
    private func finishSingleFix(with result: LocationSnapshot?, error: NavFailure?) {
        singleFixTimeout?.cancel()
        singleFixTimeout = nil
        let waiters = singleFixContinuations
        singleFixContinuations.removeAll()
        isLocating = false
        if let error { lastError = error }
        for cont in waiters {
            cont.resume(returning: result)
        }
    }

    @discardableResult
    public func requestSingleFix(timeout: TimeInterval = 8) async -> LocationSnapshot? {
        refreshAuthState()
        guard authState.isUsable else {
            lastError = authState == .servicesOff ? .locationServicesOff : .locationDenied
            return nil
        }
        // 已有新鲜快照：直接返回（NAV-38 快照年龄与精度达标的真实数据可复用）
        if let fresh = freshSnapshot() { return fresh }
        // 已有在途请求：并入等待，共享同一结果
        if isLocating { return await joinInFlightFix() }

        isLocating = true
        lastError = nil
        manager.requestLocation()
        singleFixTimeout?.cancel()
        singleFixTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // 超时兜底：若期间已收到可用快照（虽过期未唤醒的边缘）优先用数据
                let result = self.freshSnapshot()
                self.finishSingleFix(with: result, error: result == nil ? .weakLocation : nil)
            }
        }
        return await joinInFlightFix()
    }

    // MARK: - 连续定位（活动导航会话；结束即释放，NAV-31/39）

    public func startContinuous(handler: @escaping (LocationSnapshot) -> Void) {
        refreshAuthState()
        guard authState.isUsable else {
            lastError = authState == .servicesOff ? .locationServicesOff : .locationDenied
            return
        }
        continuousHandler = handler
        guard !isContinuous else { return }
        isContinuous = true
        manager.allowsBackgroundLocationUpdates = Self.backgroundLocationEnabled
        manager.showsBackgroundLocationIndicator = Self.backgroundLocationEnabled
        manager.startUpdatingLocation()
    }

    public func stopContinuous() {
        continuousHandler = nil
        guard isContinuous else { return }
        isContinuous = false
        manager.stopUpdatingLocation()
    }

    public func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }

    public func stopHeading() {
        manager.stopUpdatingHeading()
    }

    /// 后台定位需 Info.plist 声明 UIBackgroundModes=location，未声明时不开启以免崩溃
    private static var backgroundLocationEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") ?? false
    }

    /// 打开本 App 设置（仅系统允许方式，不伪造「网络授权」按钮，NAV-05）
    public func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension LocationService: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthState()
            // 授权回调：有明确结果即唤醒等待者（含被拒绝的情形，等待方按 false 分流）
            if self.authState != .notDetermined, !self.authWaiters.isEmpty {
                self.finishAuthWait(granted: self.authState.isUsable)
            }
            // 撤权后不得继续显示正常定位（NAV-03）
            if !self.authState.isUsable {
                self.snapshot = nil
                if self.isContinuous { self.stopContinuous() }
                if self.isLocating {
                    let error: NavFailure = self.authState == .servicesOff ? .locationServicesOff : .locationDenied
                    self.finishSingleFix(with: nil, error: error)
                } else {
                    self.lastError = self.authState == .servicesOff ? .locationServicesOff : .locationDenied
                }
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let snap = LocationSnapshot(location)
            self.snapshot = snap
            if self.isLocating {
                // 无论新值新鲜与否都结束本轮等待：调用方拿到最新数据后按 isUsable 自行分流，
                // 避免旧缓存把等待者挂死到超时
                self.finishSingleFix(with: snap, error: nil)
            }
            self.continuousHandler?(snap)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let nsError = error as NSError
            let failure: NavFailure
            if nsError.code == CLError.denied.rawValue {
                self.refreshAuthState()
                failure = self.authState == .servicesOff ? .locationServicesOff : .locationDenied
            } else {
                failure = .locationUnavailable
            }
            if self.isLocating {
                self.finishSingleFix(with: nil, error: failure)
            } else {
                self.lastError = failure
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            // 无效 heading（干扰/校准中）不显示正常指向（NAV-25/罗盘 R-025）
            guard newHeading.headingAccuracy >= 0 else { return }
            self.heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
            self.magneticHeading = newHeading.magneticHeading
        }
    }
}
