import Testing
@testable import QoderBar
import Foundation

/// 官方额度解析（Qoder 客户端接口 / WorkBuddy 资源接口 / Cookie 接口）
@Suite struct QuotaParsingTests {
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Qoder（openapi /sash/api/v2/me/usage）

    @Test func qoderClientUsageParsesCamelCase() throws {
        let json = #"""
        {"displayMode":"qoder","qoderUsage":{"userType":"personal","expiresAt":1789020869000,
        "userQuota":{"used":125,"total":500,"remaining":375,"percentage":0.25,"unit":"credits"}}}
        """#
        let snap = try QoderIDEClient.parseUsage(Data(json.utf8), site: .cn, source: .client, now: now)
        #expect(snap.product == .qoderCN)
        #expect(snap.used == 125)
        #expect(snap.total == 500)
        #expect(snap.remaining == 375)
        #expect(snap.percentage == 25) // 0~1 小数应换算成百分比
        #expect(snap.unit == "credits")
        #expect(snap.source == .client)
        #expect(snap.resetsAt != nil)
    }

    @Test func qoderClientUsageParsesSnakeCase() throws {
        let json = #"""
        {"qoder_usage":{"user_type":"personal","expires_at":"2026-09-28T10:14:29Z",
        "user_quota":{"used":10,"total":100,"remaining":90,"percentage":10,"unit":"credit"}}}
        """#
        let snap = try QoderIDEClient.parseUsage(Data(json.utf8), site: .intl, source: .client, now: now)
        #expect(snap.product == .qoderINTL)
        #expect(snap.used == 10)
        #expect(snap.percentage == 10) // 已大于 1 的百分比不再换算
        #expect(snap.resetsAt != nil)
    }

    @Test func qoderClientUsageMergesAddOnQuota() throws {
        let json = #"""
        {"qoderUsage":{"userType":"personal",
        "userQuota":{"used":100,"total":300,"remaining":200,"percentage":0.33},
        "addOnQuota":{"used":20,"total":50,"remaining":30,"percentage":0.4}}}
        """#
        let snap = try QoderIDEClient.parseUsage(Data(json.utf8), site: .cn, source: .client, now: now)
        #expect(snap.used == 120)
        #expect(snap.total == 350)
        #expect(snap.remaining == 230)
    }

    @Test func qoderClientUsageRejectsInvalidPayload() {
        #expect(throws: (any Error).self) {
            try QoderIDEClient.parseUsage(Data("{}".utf8), site: .cn, source: .client, now: now)
        }
        #expect(throws: (any Error).self) {
            try QoderIDEClient.parseUsage(Data("not json".utf8), site: .cn, source: .client, now: now)
        }
    }

    // MARK: - Qoder（Cookie /api/v2/me/usages/big_model_credits）

    @Test func qoderCookieParse() throws {
        let json = #"""
        {"totalQuota":{"quotaSummary":{"usedValue":125,"limitValue":500,"remainingValue":375,
        "usagePercentage":25,"unit":"credit"}},"nextResetAt":"2024-09-01T00:00:00Z"}
        """#
        let snap = try QuotaFetcher.parse(Data(json.utf8), site: .cn, now: now)
        #expect(snap.product == .qoderCN)
        #expect(snap.source == .cookie)
        #expect(snap.used == 125)
        #expect(snap.total == 500)
        #expect(snap.percentage == 25)
        #expect(snap.resetsAt == ISO8601DateFormatter().date(from: "2024-09-01T00:00:00Z"))
    }

    // MARK: - WorkBuddy（copilot.tencent.com /billing/meter/get-user-resource-summary）

    @Test func workBuddyParse() throws {
        let json = #"""
        {"code":0,"msg":"OK","data":{"Packages":[
        {"PackageCode":"p1","CycleTotalCapacity":"2100","CycleRemainCapacity":"2100","CycleUsedCapacity":"0"},
        {"PackageCode":"p2","CycleTotalCapacity":"500","CycleRemainCapacity":"307.70000013","CycleUsedCapacity":"192.29999987"}
        ],"IsPaidUser":false}}
        """#
        let snap = try WorkBuddyQuota.parse(Data(json.utf8), now: now)
        #expect(snap.product == .workbuddy)
        #expect(abs(snap.used - 192.3) < 0.01)
        #expect(abs(snap.total - 2600) < 0.01)
        #expect(abs(snap.remaining - 2407.7) < 0.01)
        #expect(abs(snap.percentage - 192.3 / 2600 * 100) < 0.01)
        #expect(snap.resetsAt == nil)
    }

    @Test func workBuddyRejectsErrorCode() {
        let json = #"{"code":401,"msg":"unauthorized","data":null}"#
        #expect(throws: (any Error).self) {
            try WorkBuddyQuota.parse(Data(json.utf8), now: now)
        }
    }

    @Test func workBuddyRejectsMissingPackages() {
        #expect(throws: (any Error).self) {
            try WorkBuddyQuota.parse(Data(#"{"code":0,"data":{}}"#.utf8), now: now)
        }
    }
}
