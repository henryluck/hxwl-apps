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
    private var singleFixContinuation: CheckedContinuation<LocationSnapshot?, Never>?
    private var singleFixTimeout: Task<Void, Never>?
    private var continuousHandler: ((LocationSnapshot) -> Void)?

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

    // MARK: - 单次定位（NAV-04：防重复，只保留一项在途）

    @discardableResult
    public func requestSingleFix(timeout: TimeInterval = 12) async -> LocationSnapshot? {
        refreshAuthState()
        guard authState.isUsable else {
            lastError = authState == .servicesOff ? .locationServicesOff : .locationDenied
            return nil
        }
        if let existing = singleFixContinuation {
            // 已有在途请求：复用同一结果，不发起第二个任务
            return await withCheckedContinuation { cont in
                Task { @MainActor in
                    let result = await self.awaitExisting()
                    cont.resume(returning: result)
                }
            }
        }
        isLocating = true
        lastError = nil
        return await withCheckedContinuation { continuation in
            singleFixContinuation = continuation
            manager.requestLocation()
            singleFixTimeout?.cancel()
            singleFixTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let cont = self.singleFixContinuation else { return }
                    self.singleFixContinuation = nil
                    self.isLocating = false
                    self.lastError = .weakLocation
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func awaitExisting() async -> LocationSnapshot? {
        while isLocating {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return snapshot
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
            // 撤权后不得继续显示正常定位（NAV-03）
            if !self.authState.isUsable {
                self.snapshot = nil
                self.lastError = self.authState == .servicesOff ? .locationServicesOff : .locationDenied
                if self.isContinuous { self.stopContinuous() }
                if let cont = self.singleFixContinuation {
                    self.singleFixContinuation = nil
                    self.isLocating = false
                    cont.resume(returning: nil)
                }
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // 过期回调不采纳（NAV-38）
        guard abs(location.timestamp.timeIntervalSinceNow) < 30 else { return }
        Task { @MainActor in
            let snap = LocationSnapshot(location)
            self.snapshot = snap
            if let cont = self.singleFixContinuation {
                self.singleFixContinuation = nil
                self.isLocating = false
                self.singleFixTimeout?.cancel()
                cont.resume(returning: snap)
            }
            self.continuousHandler?(snap)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let nsError = error as NSError
            if nsError.code == CLError.denied.rawValue {
                self.lastError = .locationDenied
                self.refreshAuthState()
            } else {
                self.lastError = .locationUnavailable
            }
            if let cont = self.singleFixContinuation {
                self.singleFixContinuation = nil
                self.isLocating = false
                self.singleFixTimeout?.cancel()
                cont.resume(returning: nil)
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
