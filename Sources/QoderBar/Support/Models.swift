import Foundation

enum QoderProduct: String, Codable, CaseIterable {
    case qoderCN = "qodercn"
    case qoderINTL = "qoder"
    case workbuddy = "workbuddy"

    var displayName: String {
        switch self {
        case .qoderCN: return "Qoder CN"
        case .qoderINTL: return "Qoder"
        case .workbuddy: return "WorkBuddy"
        }
    }

    var badge: String {
        switch self {
        case .qoderCN: return "CN"
        case .qoderINTL: return "INTL"
        case .workbuddy: return "WB"
        }
    }
}

struct UsageEvent: Identifiable, Equatable {
    var id: String
    var sessionId: String
    var project: String
    var model: String
    var ts: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheRead: Int
    var cacheWrite: Int
    var credits: Double
    var estOutputTokens: Int
    var duration: Double?
    var product: QoderProduct
    var userKey: String?
    var version: String
    /// 服务端给出的上下文占比（0~1），乘 200K 可得该次调用的输入 tokens
    var ctxRatio: Double?

    /// 优先使用服务端返回的真实输出 tokens，否则用内容长度估算
    var effectiveOutputTokens: Int { outputTokens > 0 ? outputTokens : estOutputTokens }

    var isEstimated: Bool { outputTokens == 0 && estOutputTokens > 0 }

    /// 输入已按缓存拆分（cacheRead + cacheWrite == inputTokens），避免重复计入
    var totalTokens: Int { inputTokens + outputTokens }

    var callTPS: Double? {
        guard let d = duration, d >= 0.2 else { return nil }
        return Double(effectiveOutputTokens) / d
    }
}

struct IdentityRecord: Identifiable, Equatable, Hashable {
    var userKey: String
    var name: String
    var email: String?
    var avatarURL: String?
    var product: QoderProduct
    var firstSeen: Date
    var lastSeen: Date

    var id: String { userKey }
    var displayName: String { name.isEmpty ? userKey : name }
}

struct IdentityWindow: Equatable {
    var userKey: String
    var product: QoderProduct
    var start: Date
    var end: Date?
}

struct TokenTotals: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    /// cacheRead / cacheWrite 是 input 的拆分，不重复计入
    var total: Int { input + output }

    mutating func add(_ e: UsageEvent) {
        input += e.inputTokens
        output += e.effectiveOutputTokens
        cacheRead += e.cacheRead
        cacheWrite += e.cacheWrite
    }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

struct Bucket: Identifiable, Equatable {
    var id: Date { start }
    var start: Date
    var tokens = TokenTotals()
    var credits: Double = 0
    /// 分产品积分（CN/WB 是两套账，图表按产品堆叠）
    var creditsByProduct: [QoderProduct: Double] = [:]
    var calls: Int = 0
    var genSeconds: Double = 0
    var peakTPS: Double = 0

    /// 桶内平均生成速率（调用时长加权）
    var tps: Double {
        guard genSeconds > 0 else { return 0 }
        return Double(tokens.output) / genSeconds
    }
}

/// 单产品在某个时间窗内的用量（积分不跨产品相加）
struct ProductTotals: Equatable {
    var credits: Double = 0
    var cost: Double = 0
    var tokens: Int = 0
    var calls: Int = 0
}

struct DayStat: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var totals = TokenTotals()
    var credits: Double = 0
    var calls: Int = 0
}

struct ModelStat: Identifiable, Equatable {
    var id: String { model }
    var model: String
    var tokens = TokenTotals()
    var credits: Double = 0
    var calls: Int = 0
    var peakTPS: Double = 0
    var avgTPS: Double = 0
}

struct ProjectStat: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var name: String
    var tokens = TokenTotals()
    var credits: Double = 0
    var calls: Int = 0
    var sessions: Int = 0
}

struct SessionStat: Identifiable, Equatable {
    var id: String { sessionId }
    var sessionId: String
    var project: String
    var projectName: String
    var product: QoderProduct
    var models: [String] = []
    var start: Date
    var end: Date
    var calls: Int = 0
    var totals = TokenTotals()
    var credits: Double = 0
    var peakTPS: Double = 0
    var avgTPS: Double = 0
    var userKey: String?
    var hasRealTokens = false

    var lastActive: Date { end }
}

struct UserSummary: Identifiable, Equatable {
    var id: String { userKey }
    var userKey: String
    var name: String
    var product: QoderProduct
    var avatarURL: String?
    var lastEventAt: Date?
    var todayTokens: Int = 0
    var todayCredits: Double = 0
    var colorIndex: Int
    /// 今日 tokens 是否来自服务端真实值（WorkBuddy 为真，Qoder 为估算）
    var hasRealTokens = false
}

struct MenuBarMeter: Equatable {
    enum Level {
        case normal, warn, over
    }
    var fraction: Double
    var level: Level
}

enum TimeRange: String, CaseIterable, Identifiable {
    case live, day, week, month, heatmap
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "实时"
        case .day: return "24小时"
        case .week: return "7天"
        case .month: return "30天"
        case .heatmap: return "热力图"
        }
    }
}

struct MetricsSnapshot {
    var generatedAt = Date()
    var users: [UserSummary] = []
    var selectedUserKey: String?
    var range: TimeRange = .live
    var liveTPS: Double = 0
    var liveOutputTokens: Int = 0
    var liveCreditsPerMin: Double = 0
    var isGenerating = false
    var today = TokenTotals()
    var todayCredits: Double = 0
    var todayCalls = 0
    var todaySessions = 0
    var todayPeakTPS: Double = 0
    var todayPeakAt: Date?
    var todayAvgTPS: Double = 0
    var todayMaxCallTPS: Double = 0
    var todayCost: Double = 0
    var monthCredits: Double = 0
    var monthCost: Double = 0
    var monthTokens: Int = 0
    /// 滚动近 30 天（费用卡口径）
    var last30Credits: Double = 0
    var last30Cost: Double = 0
    var last30Tokens: Int = 0
    /// 各产品近 7 天日均积分（Pace 预测用，不跨产品混算）
    var weekDailyByProduct: [QoderProduct: Double] = [:]
    var todayByProduct: [QoderProduct: ProductTotals] = [:]
    var monthByProduct: [QoderProduct: ProductTotals] = [:]
    var last30ByProduct: [QoderProduct: ProductTotals] = [:]
    var heatmapByProduct: [QoderProduct: ProductTotals] = [:]
    var rangeByProduct: [QoderProduct: ProductTotals] = [:]
    var rangeTotals = TokenTotals()
    var rangeCalls = 0
    var rangeCredits: Double = 0
    var rangePeakTPS: Double = 0
    var rangePeakAt: Date?
    var rangeAvgTPS: Double = 0
    var rangePeakCreditRate: Double = 0
    var buckets: [Bucket] = []
    var models: [ModelStat] = []
    var projects: [ProjectStat] = []
    var sessions: [SessionStat] = []
    var days: [DayStat] = []
    var lastEventAt: Date?
    var lastScanAt: Date?
    var eventCount = 0
    /// 今日事件是否全部为服务端真实 token（Qoder 为估算值，故通常为假）
    var hasRealTokens = false
    /// 最近 60 秒事件是否全部为真实 token
    var liveHasRealTokens = false
    /// 当前时间范围事件是否全部为真实 token
    var rangeHasRealTokens = false
    /// 缓存范围内（近 120 天）存在真实 token 事件
    var anyRealTokens = false
    /// 缓存范围内（近 120 天）事件全部为真实 token
    var allRealTokens = false
    var sourceIssues: [String] = []

    static let empty = MetricsSnapshot()
}
