import SwiftUI
import StoreKit

// MARK: - ReviewService 真实实现：SKStoreReviewController

public struct StoreReviewService: ReviewService {
    /// 距上次弹出最少间隔天数（同一 App 内苹果也会限频，这里再兜一层）
    private let minIntervalDays: Int
    private let lastAskedKey = "review.lastAsked"

    public init(minIntervalDays: Int = 30) {
        self.minIntervalDays = minIntervalDays
    }

    public func maybeAsk() {
        let last = UserDefaults.standard.object(forKey: lastAskedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Double(minIntervalDays * 86400) else { return }
        UserDefaults.standard.set(Date(), forKey: lastAskedKey)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}
