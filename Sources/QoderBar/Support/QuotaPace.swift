import Foundation

/// Pace 预测文案：回答"按当前速度还能用多久、能不能撑到重置"
enum QuotaPace {
    struct Result: Equatable {
        var text: String
        var warning: Bool
    }

    /// - Parameters:
    ///   - daily: 日均消耗（积分/天）
    ///   - resetsAt: 额度重置时间（WorkBuddy 这类无重置的传 nil）
    static func describe(
        used: Double,
        total: Double,
        daily: Double,
        label: String,
        resetsAt: Date?,
        now: Date = Date()
    ) -> Result? {
        guard total > 0 else { return nil }
        let remaining = max(0, total - used)
        if remaining <= 0 {
            return Result(text: "额度已用尽", warning: true)
        }
        guard daily > 0.05 else { return nil }

        let daysToExhaust = remaining / daily
        let exhaustText: String
        if daysToExhaust >= 365 {
            exhaustText = "可用一年以上"
        } else if daysToExhaust >= 1 {
            exhaustText = String(format: "可用约 %.0f 天", daysToExhaust)
        } else {
            exhaustText = "不足 1 天可用"
        }

        if let resetsAt {
            let daysToReset = max(0, resetsAt.timeIntervalSince(now) / 86_400)
            if daysToExhaust < daysToReset {
                return Result(
                    text: String(format: "%@ %.1f 积分 · 约 %.0f 天后用尽，撑不到重置", label, daily, daysToExhaust),
                    warning: true)
            }
            return Result(text: "\(label) \(String(format: "%.1f", daily)) 积分 · \(exhaustText)，撑得到重置", warning: false)
        }
        return Result(text: "\(label) \(String(format: "%.1f", daily)) 积分 · \(exhaustText)", warning: false)
    }
}
