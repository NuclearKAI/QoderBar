import Foundation

enum Metrics {

    /// 单次调用的上下文窗口大小（tokens）。由服务端压缩事件里的真实 preTokens
    /// 结合压缩前最后一次请求的 context_usage_ratio 反解标定（误差 <0.2%）。
    static let contextWindowTokens: Double = 200_000

    struct RangeSpec {
        var span: TimeInterval
        var bucket: TimeInterval
    }

    static func spec(for range: TimeRange) -> RangeSpec {
        switch range {
        case .live: return RangeSpec(span: 600, bucket: 10)
        case .day: return RangeSpec(span: 86_400, bucket: 300)
        case .week: return RangeSpec(span: 7 * 86_400, bucket: 3_600)
        case .month: return RangeSpec(span: 30 * 86_400, bucket: 86_400)
        case .heatmap: return RangeSpec(span: 120 * 86_400, bucket: 86_400)
        }
    }

    /// 滑动窗口峰值吞吐（token/秒 或 积分/秒，按 value 单位换算）
    static func slidingPeak(
        _ events: [UsageEvent],
        window: TimeInterval = 60,
        value: (UsageEvent) -> Double
    ) -> (value: Double, at: Date?) {
        guard !events.isEmpty else { return (0, nil) }
        let sorted = events.sorted { $0.ts < $1.ts }
        var left = 0
        var sum: Double = 0
        var best: Double = 0
        var bestEnd: Date?
        for right in 0..<sorted.count {
            sum += value(sorted[right])
            while sorted[right].ts.timeIntervalSince(sorted[left].ts) > window {
                sum -= value(sorted[left])
                left += 1
            }
            if sum > best {
                best = sum
                bestEnd = sorted[right].ts
            }
        }
        return (best / window, bestEnd)
    }

    static func avgTPS(_ events: [UsageEvent]) -> Double {
        var out = 0
        var secs = 0.0
        for e in events {
            if let d = e.duration {
                out += e.effectiveOutputTokens
                secs += d
            }
        }
        guard secs > 0 else { return 0 }
        return Double(out) / secs
    }

    /// 按产品拆分统计（积分/费用不跨产品相加）
    static func byProduct(_ events: [UsageEvent], settings: AppSettings) -> [QoderProduct: ProductTotals] {
        var dict: [QoderProduct: ProductTotals] = [:]
        for e in events {
            var t = dict[e.product] ?? ProductTotals()
            t.credits += e.credits
            t.tokens += e.effectiveOutputTokens
            t.calls += 1
            dict[e.product] = t
        }
        var result: [QoderProduct: ProductTotals] = [:]
        for (p, t) in dict {
            var c = t
            c.cost = settings.cost(credits: t.credits)
            result[p] = c
        }
        return result
    }

    static func build(
        events allEvents: [UsageEvent],
        identities: [IdentityRecord],
        selectedUser: String?,
        range: TimeRange,
        now: Date = Date(),
        settings: AppSettings,
        lastScanAt: Date?,
        lastFileActivity: Date?,
        issues: [String],
        totalEventCount: Int
    ) -> MetricsSnapshot {
        let cal = Calendar.current
        var snap = MetricsSnapshot()
        snap.generatedAt = now
        snap.range = range
        snap.selectedUserKey = selectedUser
        snap.lastScanAt = lastScanAt
        snap.sourceIssues = issues
        snap.eventCount = totalEventCount
        snap.lastEventAt = allEvents.map(\.ts).max()
        snap.anyRealTokens = allEvents.contains { $0.outputTokens > 0 }
        snap.allRealTokens = !allEvents.isEmpty && allEvents.allSatisfy { $0.outputTokens > 0 }

        // 用户列表
        let todayStart = cal.startOfDay(for: now)
        for (i, identity) in identities.enumerated() {
            var summary = UserSummary(
                userKey: identity.userKey,
                name: identity.displayName,
                product: identity.product,
                avatarURL: identity.avatarURL,
                colorIndex: i
            )
            var todayCount = 0
            var todayRealCount = 0
            for e in allEvents where e.userKey == identity.userKey {
                if e.ts >= todayStart {
                    summary.todayTokens += e.effectiveOutputTokens
                    summary.todayCredits += e.credits
                    todayCount += 1
                    if e.outputTokens > 0 { todayRealCount += 1 }
                }
                if summary.lastEventAt == nil || e.ts > summary.lastEventAt! { summary.lastEventAt = e.ts }
            }
            summary.hasRealTokens = todayCount > 0 && todayRealCount == todayCount
            snap.users.append(summary)
        }

        let events = selectedUser == nil ? allEvents : allEvents.filter { $0.userKey == selectedUser }

        // 今日
        let today = events.filter { $0.ts >= todayStart }
        for e in today {
            snap.today.add(e)
            snap.todayCredits += e.credits
        }
        snap.todayCalls = today.count
        snap.todaySessions = Set(today.map(\.sessionId)).count
        snap.hasRealTokens = !today.isEmpty && today.allSatisfy { $0.outputTokens > 0 }
        snap.todayByProduct = Self.byProduct(today, settings: settings)
        let todayPeak = slidingPeak(today) { Double($0.effectiveOutputTokens) }
        snap.todayPeakTPS = todayPeak.value
        snap.todayPeakAt = todayPeak.at
        snap.todayAvgTPS = avgTPS(today)
        snap.todayMaxCallTPS = today.compactMap(\.callTPS).max() ?? 0
        snap.todayCost = settings.cost(credits: snap.todayCredits)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let monthEvents = events.filter { $0.ts >= monthStart }
        snap.monthCredits = monthEvents.reduce(0) { $0 + $1.credits }
        snap.monthCost = settings.cost(credits: snap.monthCredits)
        snap.monthTokens = monthEvents.reduce(0) { $0 + $1.effectiveOutputTokens }
        snap.monthByProduct = Self.byProduct(monthEvents, settings: settings)

        // 滚动近 30 天与近 7 天日均（费用卡、Pace 预测）
        let last30Events = events.filter { $0.ts >= now.addingTimeInterval(-30 * 86_400) }
        snap.last30Credits = last30Events.reduce(0) { $0 + $1.credits }
        snap.last30Cost = settings.cost(credits: snap.last30Credits)
        snap.last30Tokens = last30Events.reduce(0) { $0 + $1.effectiveOutputTokens }
        snap.last30ByProduct = Self.byProduct(last30Events, settings: settings)
        let week7Events = events.filter { $0.ts >= now.addingTimeInterval(-7 * 86_400) }
        var weekDaily: [QoderProduct: Double] = [:]
        for e in week7Events {
            weekDaily[e.product, default: 0] += e.credits
        }
        snap.weekDailyByProduct = weekDaily.mapValues { $0 / 7 }

        if settings.hideInactiveUsers {
            snap.users = snap.users.filter { $0.lastEventAt != nil }
        }

        // 实时
        let liveWindow: TimeInterval = 60
        let liveEvents = events.filter { $0.ts >= now.addingTimeInterval(-liveWindow) }
        snap.liveOutputTokens = liveEvents.reduce(0) { $0 + $1.effectiveOutputTokens }
        // 空闲时沿用今日口径，避免对真实 token 的产品误标"估算"
        let liveScope = liveEvents.isEmpty ? today : liveEvents
        snap.liveHasRealTokens = !liveScope.isEmpty && liveScope.allSatisfy { $0.outputTokens > 0 }
        let liveCredits = liveEvents.reduce(0) { $0 + $1.credits }
        snap.liveCreditsPerMin = liveCredits
        var liveTPS = Double(snap.liveOutputTokens) / liveWindow
        snap.isGenerating = lastFileActivity.map { now.timeIntervalSince($0) < 20 } ?? false
        if snap.isGenerating {
            // 生成中按实际生成时长加权，避免固定 60 秒除数稀释瞬时速度
            let weighted = avgTPS(liveEvents)
            if weighted > 0 {
                liveTPS = weighted
            } else if !liveEvents.isEmpty {
                liveTPS = Double(snap.liveOutputTokens) / max(1, now.timeIntervalSince(liveEvents[0].ts))
            }
        }
        snap.liveTPS = liveTPS

        // 区间
        let spec = Self.spec(for: range)
        let effectiveStart = now.addingTimeInterval(-spec.span)
        let rangeEvents = events.filter { $0.ts >= effectiveStart }
        for e in rangeEvents {
            snap.rangeTotals.add(e)
            snap.rangeCredits += e.credits
        }
        snap.rangeCalls = rangeEvents.count
        snap.rangeHasRealTokens = !rangeEvents.isEmpty && rangeEvents.allSatisfy { $0.outputTokens > 0 }
        snap.rangeByProduct = Self.byProduct(rangeEvents, settings: settings)
        let rangePeak = slidingPeak(rangeEvents) { Double($0.effectiveOutputTokens) }
        snap.rangePeakTPS = rangePeak.value
        snap.rangePeakAt = rangePeak.at
        snap.rangeAvgTPS = avgTPS(rangeEvents)
        snap.rangePeakCreditRate = slidingPeak(rangeEvents) { $0.credits }.value * 60

        // 时间桶
        if range != .heatmap {
            let step = spec.bucket
            var dict: [Int: Bucket] = [:]
            let firstKey = Int((effectiveStart.timeIntervalSince1970 / step).rounded(.down))
            let lastKey = Int((now.timeIntervalSince1970 / step).rounded(.down))
            for key in firstKey...max(firstKey, lastKey) {
                dict[key] = Bucket(start: Date(timeIntervalSince1970: Double(key) * step))
            }
            for e in rangeEvents {
                let key = Int((e.ts.timeIntervalSince1970 / step).rounded(.down))
                guard var b = dict[key] else { continue }
                b.tokens.add(e)
                b.credits += e.credits
                b.creditsByProduct[e.product, default: 0] += e.credits
                b.calls += 1
                if let d = e.duration { b.genSeconds += d }
                if let t = e.callTPS, t > b.peakTPS { b.peakTPS = t }
                dict[key] = b
            }
            snap.buckets = dict.keys.sorted().map { dict[$0]! }
        }

        // 模型维度
        var modelDict: [String: [UsageEvent]] = [:]
        for e in rangeEvents { modelDict[e.model, default: []].append(e) }
        snap.models = modelDict.map { model, list in
            var stat = ModelStat(model: model)
            for e in list {
                stat.tokens.add(e)
                stat.credits += e.credits
            }
            stat.calls = list.count
            stat.peakTPS = slidingPeak(list) { Double($0.effectiveOutputTokens) }.value
            stat.avgTPS = avgTPS(list)
            return stat
        }.sorted { $0.tokens.total > $1.tokens.total }

        // 项目维度
        var projectDict: [String: [UsageEvent]] = [:]
        for e in monthEvents { projectDict[e.project, default: []].append(e) }
        snap.projects = projectDict.map { path, list in
            var stat = ProjectStat(path: path, name: Fmt.projectName(path))
            for e in list {
                stat.tokens.add(e)
                stat.credits += e.credits
            }
            stat.calls = list.count
            stat.sessions = Set(list.map(\.sessionId)).count
            return stat
        }.sorted { $0.credits > $1.credits }

        // 会话维度（最近 7 天）
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        var sessionDict: [String: [UsageEvent]] = [:]
        for e in events where e.ts >= weekStart { sessionDict[e.sessionId, default: []].append(e) }
        var sessionResult: [SessionStat] = []
        for (sid, list) in sessionDict {
            guard let first = list.first, let last = list.max(by: { $0.ts < $1.ts }) else { continue }
            var stat = SessionStat(
                sessionId: sid,
                project: first.project,
                projectName: Fmt.projectName(first.project),
                product: first.product,
                start: list.map(\.ts).min() ?? first.ts,
                end: last.ts
            )
            stat.userKey = first.userKey
            var models: [String] = []
            for e in list {
                stat.totals.add(e)
                stat.credits += e.credits
                if !models.contains(e.model) { models.append(e.model) }
                if e.outputTokens > 0 { stat.hasRealTokens = true }
            }
            stat.models = models
            stat.calls = list.count
            stat.peakTPS = slidingPeak(list, window: 30) { Double($0.effectiveOutputTokens) }.value
            stat.avgTPS = avgTPS(list)
            sessionResult.append(stat)
        }
        snap.sessions = sessionResult.sorted { $0.end > $1.end }

        // 每日汇总（热力图，最近 120 天）
        var dayDict: [Date: DayStat] = [:]
        let heatStart = cal.startOfDay(for: now.addingTimeInterval(-119 * 86_400))
        for e in allEvents where e.ts >= heatStart {
            let day = cal.startOfDay(for: e.ts)
            var stat = dayDict[day] ?? DayStat(day: day)
            stat.totals.add(e)
            stat.credits += e.credits
            stat.calls += 1
            dayDict[day] = stat
        }
        var days: [DayStat] = []
        var d = heatStart
        while d <= now {
            days.append(dayDict[d] ?? DayStat(day: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
        }
        snap.days = days
        snap.heatmapByProduct = Self.byProduct(allEvents.filter { $0.ts >= heatStart }, settings: settings)

        return snap
    }
}
