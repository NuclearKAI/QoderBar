import Testing
@testable import QoderBar
import Foundation

/// 指标聚合：产品分账、时间窗口、TPS 与预算口径
@Suite struct MetricsTests {
    private func event(
        _ product: QoderProduct,
        credits: Double,
        output: Int = 0,
        estOutput: Int = 0,
        input: Int = 100,
        ts: Date,
        session: String = "s1",
        user: String? = nil,
        model: String = "m1",
        duration: Double? = 10
    ) -> UsageEvent {
        UsageEvent(
            id: UUID().uuidString, sessionId: session, project: "p", model: model, ts: ts,
            inputTokens: input, outputTokens: output, cacheRead: 0, cacheWrite: 0,
            credits: credits, estOutputTokens: estOutput, duration: duration,
            product: product, userKey: user, version: "", ctxRatio: nil)
    }

    private func build(
        _ events: [UsageEvent],
        identities: [IdentityRecord] = [],
        selectedUser: String? = nil,
        settings: AppSettings = AppSettings(),
        now: Date
    ) -> MetricsSnapshot {
        Metrics.build(
            events: events, identities: identities, selectedUser: selectedUser, range: .day,
            now: now, settings: settings, lastScanAt: now, lastFileActivity: nil,
            issues: [], totalEventCount: events.count)
    }

    @Test func perProductCreditsAreNotSummed() {
        let now = Date()
        let events = [
            event(.qoderCN, credits: 10, output: 100, ts: now),
            event(.workbuddy, credits: 5, output: 50, ts: now)
        ]
        let snap = build(events, now: now)
        #expect(snap.todayByProduct[.qoderCN]?.credits == 10)
        #expect(snap.todayByProduct[.workbuddy]?.credits == 5)
        #expect(snap.monthByProduct[.qoderCN]?.credits == 10)
        #expect(snap.monthByProduct[.workbuddy]?.credits == 5)
        #expect(snap.todayCredits == 15) // 原始聚合仍保留，仅供内部使用
    }

    @Test func selectedUserScopesAllMetrics() {
        let now = Date()
        let events = [
            event(.qoderCN, credits: 10, output: 100, ts: now, user: "cn:u1"),
            event(.workbuddy, credits: 5, output: 50, ts: now, user: "workbuddy:u1")
        ]
        let snap = build(events, selectedUser: "workbuddy:u1", now: now)
        #expect(snap.todayCredits == 5)
        #expect(snap.todayByProduct[.qoderCN] == nil)
        #expect(snap.todayByProduct[.workbuddy]?.credits == 5)
    }

    @Test func weekDailyByProduct() {
        let now = Date()
        let events = [
            event(.qoderCN, credits: 7, ts: now.addingTimeInterval(-86_400)),
            event(.qoderCN, credits: 7, ts: now),
            event(.workbuddy, credits: 14, ts: now)
        ]
        let snap = build(events, now: now)
        #expect(abs((snap.weekDailyByProduct[.qoderCN] ?? 0) - 2) < 0.001)
        #expect(abs((snap.weekDailyByProduct[.workbuddy] ?? 0) - 2) < 0.001)
    }

    @Test func oldEventsAreExcludedFromTodayAndMonth() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let events = [event(.qoderCN, credits: 99, ts: old), event(.qoderCN, credits: 1, ts: now)]
        let snap = build(events, now: now)
        #expect(snap.todayCredits == 1)
        #expect(snap.monthCredits == 1)
    }

    @Test func hasRealTokensReflectsOutputTokens() {
        let now = Date()
        let wb = build([event(.workbuddy, credits: 1, output: 42, ts: now)], now: now)
        #expect(wb.hasRealTokens)
        let cn = build([event(.qoderCN, credits: 1, estOutput: 42, ts: now)], now: now)
        #expect(!cn.hasRealTokens)
        #expect(cn.today.output == 42) // 无真实输出时使用估算值
    }

    @Test func hideInactiveUsersFiltersEmptyIdentities() {
        let now = Date()
        let identities = [
            IdentityRecord(userKey: "cn:u1", name: "A", email: nil, avatarURL: nil,
                           product: .qoderCN, firstSeen: now, lastSeen: now),
            IdentityRecord(userKey: "workbuddy:u2", name: "B", email: nil, avatarURL: nil,
                           product: .workbuddy, firstSeen: now, lastSeen: now)
        ]
        var settings = AppSettings()
        settings.hideInactiveUsers = true
        let events = [event(.qoderCN, credits: 1, ts: now, user: "cn:u1")]
        let snap = build(events, identities: identities, settings: settings, now: now)
        #expect(snap.users.map(\.userKey) == ["cn:u1"])
    }

    @Test func peakTPSUsesSlidingWindow() {
        let now = Date()
        // 同一 60s 窗口内两次调用共 300 tokens → 峰值 TPS 至少 5/s
        let events = [
            event(.qoderCN, credits: 1, output: 150, ts: now.addingTimeInterval(-30)),
            event(.qoderCN, credits: 1, output: 150, ts: now)
        ]
        let snap = build(events, now: now)
        #expect(snap.todayPeakTPS >= 5)
        #expect(snap.todayAvgTPS > 0)
    }

    @Test func costUsesCreditPrice() {
        let now = Date()
        var settings = AppSettings()
        settings.creditPrice = 0.04
        let snap = build([event(.qoderCN, credits: 100, ts: now)], settings: settings, now: now)
        #expect(abs(snap.todayCost - 4.0) < 0.001)
        #expect(abs((snap.monthByProduct[.qoderCN]?.cost ?? 0) - 4.0) < 0.001)
    }
}
