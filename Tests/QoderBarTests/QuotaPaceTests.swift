import Testing
@testable import QoderBar
import Foundation

/// Pace 文案：可用天数 + 能否撑到重置
@Suite struct QuotaPaceTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func canLastToReset() {
        // 剩 5838 / 日均 162 ≈ 36 天，重置还有 30 天
        let reset = now.addingTimeInterval(30 * 86_400)
        let r = QuotaPace.describe(used: 162, total: 6000, daily: 162, label: "周期日均", resetsAt: reset, now: now)
        #expect(r?.warning == false)
        #expect(r?.text == "周期日均 162.0 积分 · 可用约 36 天，撑得到重置")
    }

    @Test func cannotLastToReset() {
        // 剩 5838 / 日均 290 ≈ 20 天 < 30 天
        let reset = now.addingTimeInterval(30 * 86_400)
        let r = QuotaPace.describe(used: 162, total: 6000, daily: 290, label: "周期日均", resetsAt: reset, now: now)
        #expect(r?.warning == true)
        #expect(r?.text == "周期日均 290.0 积分 · 约 20 天后用尽，撑不到重置")
    }

    @Test func withoutResetDate() {
        let r = QuotaPace.describe(used: 192.3, total: 2600, daily: 22.1, label: "近 7 天日均", resetsAt: nil, now: now)
        #expect(r?.warning == false)
        #expect(r?.text == "近 7 天日均 22.1 积分 · 可用约 109 天")
    }

    @Test func exhausted() {
        let r = QuotaPace.describe(used: 300, total: 300, daily: 10, label: "周期日均", resetsAt: nil, now: now)
        #expect(r?.warning == true)
        #expect(r?.text == "额度已用尽")
    }

    @Test func nilWhenNoRateOrNoQuota() {
        #expect(QuotaPace.describe(used: 1, total: 300, daily: 0, label: "周期日均", resetsAt: nil, now: now) == nil)
        #expect(QuotaPace.describe(used: 1, total: 0, daily: 5, label: "周期日均", resetsAt: nil, now: now) == nil)
    }

    @Test func veryLongRunway() {
        let r = QuotaPace.describe(used: 1, total: 100_000, daily: 1, label: "周期日均", resetsAt: nil, now: now)
        #expect(r?.text.contains("可用一年以上") == true)
    }
}
