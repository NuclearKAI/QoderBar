import Foundation

enum CLIDump {
    /// --quota-test：诊断官方额度抓取链路（Qoder 钥匙串 → 解密 → 接口；WorkBuddy 登录态 → 接口）
    static func runQuotaTest() {
        let settings = AppSettings.load()
        let fmt = ISO8601DateFormatter()

        print("── Qoder（\(settings.quotaSite.title)）──")
        print("凭据源: \(settings.quotaCookie.isEmpty ? "自动（读取 Qoder 客户端登录态）" : "配置的 Cookie")")
        do {
            let q = try QoderIDEClient.fetch(
                cookie: settings.quotaCookie.isEmpty ? nil : settings.quotaCookie,
                site: settings.quotaSite, timeout: 15)
            print(String(format: "官方额度: 已用 %.2f / %.2f（%.1f%%）· 剩余 %.2f %@",
                         q.used, q.total, q.percentage, q.remaining, q.unit ?? "credits"))
            print("重置/到期: \(q.resetsAt.map { fmt.string(from: $0) } ?? "未知")  来源: \(q.source.rawValue)")
        } catch {
            print("读取失败: \(error.localizedDescription)")
        }

        print("── WorkBuddy ──")
        if FileManager.default.fileExists(atPath: WorkBuddyQuota.infoURL.path) {
            do {
                let w = try WorkBuddyQuota.fetch(timeout: 15)
                print(String(format: "积分余额: 已用 %.2f / %.2f（%.1f%%）· 剩余 %.2f %@",
                             w.used, w.total, w.percentage, w.remaining, w.unit ?? "credits"))
                print("来源: \(w.source.rawValue)")
            } catch {
                print("读取失败: \(error.localizedDescription)")
            }
        } else {
            print("未发现 WorkBuddy 登录态")
        }
    }

    /// --check-update：检查 GitHub Releases 是否有新版本
    static func runCheckUpdate() {
        guard UpdateChecker.isConfigured else {
            print("未配置更新源（UpdateChecker.defaultRepo 留空）")
            return
        }
        print("当前版本: \(AppInfo.version)  更新源: \(UpdateChecker.repo)")
        switch UpdateChecker.check() {
        case .upToDate(let current):
            print("已是最新版本（\(current)）")
        case .available(let release):
            print("发现新版本 \(release.version)")
            if !release.notes.isEmpty { print("说明: \(release.notes.prefix(300))") }
            print("下载页: \(release.htmlURL?.absoluteString ?? release.zipURL.absoluteString)")
        case .failed(let message):
            print("检查失败: \(message)")
        case .notConfigured:
            print("未配置更新源")
        }
    }

    /// --json：机器可读输出（脚本/CI 用）
    static func runJSON() {
        let engine = Engine.shared
        engine.scanSynchronously()
        let settings = AppSettings.load()
        let snap = engine.snapshot(range: .month, userKey: nil, settings: settings)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        func totals(_ t: TokenTotals) -> [String: Any] {
            ["input": t.input, "output": t.output, "cacheRead": t.cacheRead, "cacheWrite": t.cacheWrite]
        }

        var root: [String: Any] = [:]
        root["generatedAt"] = iso.string(from: snap.generatedAt)
        root["database"] = engine.databasePath()
        root["eventCount"] = snap.eventCount
        root["lastScanAt"] = snap.lastScanAt.map { iso.string(from: $0) }
        root["users"] = snap.users.map { u -> [String: Any] in
            ["key": u.userKey, "name": u.name, "product": u.product.rawValue,
             "todayTokens": u.todayTokens, "todayCredits": u.todayCredits,
             "hasRealTokens": u.hasRealTokens,
             "lastEventAt": u.lastEventAt.map { iso.string(from: $0) } ?? NSNull()]
        }
        root["today"] = [
            "credits": snap.todayCredits, "cost": snap.todayCost,
            "calls": snap.todayCalls, "sessions": snap.todaySessions,
            "tokens": totals(snap.today),
            "peakTPS": snap.todayPeakTPS, "avgTPS": snap.todayAvgTPS, "maxCallTPS": snap.todayMaxCallTPS,
            "hasRealTokens": snap.hasRealTokens
        ]
        root["month"] = ["credits": snap.monthCredits, "cost": snap.monthCost, "tokens": snap.monthTokens]
        root["last30"] = ["credits": snap.last30Credits, "cost": snap.last30Cost, "tokens": snap.last30Tokens]
        func productDict(_ dict: [QoderProduct: ProductTotals]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (p, t) in dict {
                out[p.rawValue] = ["credits": t.credits, "cost": t.cost, "tokens": t.tokens, "calls": t.calls]
            }
            return out
        }
        root["byProduct"] = [
            "today": productDict(snap.todayByProduct),
            "month": productDict(snap.monthByProduct),
            "last30": productDict(snap.last30ByProduct)
        ]
        root["range"] = [
            "name": snap.range.rawValue, "credits": snap.rangeCredits,
            "calls": snap.rangeCalls, "tokens": totals(snap.rangeTotals),
            "peakTPS": snap.rangePeakTPS, "avgTPS": snap.rangeAvgTPS
        ]

        // 官方额度：按产品分别抓取（Qoder：客户端登录态/Cookie；WorkBuddy：客户端登录态）
        var quotaDict: [String: Any] = [:]
        let qoderKey = settings.quotaSite == .cn ? QoderProduct.qoderCN.rawValue : QoderProduct.qoderINTL.rawValue
        do {
            let q = try QoderIDEClient.fetch(
                cookie: settings.quotaCookie.isEmpty ? nil : settings.quotaCookie,
                site: settings.quotaSite, timeout: 10)
            quotaDict[q.product.rawValue] = [
                "source": "official", "via": q.source.rawValue, "site": q.site?.rawValue ?? "",
                "used": q.used, "total": q.total, "remaining": q.remaining,
                "percentage": q.percentage,
                "resetsAt": q.resetsAt.map { iso.string(from: $0) } ?? NSNull()
            ] as [String: Any]
        } catch {
            if settings.monthlyCreditBudget > 0 {
                let cal = Calendar.current
                let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
                let reset = cal.date(byAdding: .month, value: 1, to: start) ?? start
                quotaDict[qoderKey] = [
                    "source": "budget", "used": snap.monthByProduct[.qoderCN]?.credits ?? 0,
                    "total": settings.monthlyCreditBudget,
                    "resetsAt": iso.string(from: reset),
                    "officialError": error.localizedDescription
                ] as [String: Any]
            } else {
                quotaDict[qoderKey] = ["source": "none", "error": error.localizedDescription]
            }
        }
        if FileManager.default.fileExists(atPath: WorkBuddyQuota.infoURL.path) {
            do {
                let w = try WorkBuddyQuota.fetch(timeout: 10)
                quotaDict[w.product.rawValue] = [
                    "source": "official", "via": w.source.rawValue,
                    "used": w.used, "total": w.total, "remaining": w.remaining,
                    "percentage": w.percentage
                ] as [String: Any]
            } catch {
                quotaDict[QoderProduct.workbuddy.rawValue] = ["source": "none", "error": error.localizedDescription]
            }
        }
        root["quota"] = quotaDict
        root["issues"] = snap.sourceIssues

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func run() {
        let engine = Engine.shared
        engine.scanSynchronously()

        let settings = AppSettings.load()
        let snap = engine.snapshot(range: .month, userKey: nil, settings: settings)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        print("══════════════════════════════════════════")
        print(" QoderBar 数据自检")
        print("══════════════════════════════════════════")
        print("数据库: \(engine.databasePath())")
        let realNote = snap.allRealTokens ? "有" : (snap.anyRealTokens ? "部分（其余为估算值）" : "无（使用估算值）")
        print("事件总数: \(snap.eventCount)  真实token: \(realNote)")
        print("最后扫描: \(snap.lastScanAt.map { df.string(from: $0) } ?? "-")")
        print("")

        print("── 用户（身份时间线） ──")
        for u in snap.users {
            print(String(format: "  [%@] %@  今日 %@ tokens%@ / %.2f 积分  最近活动 %@",
                         u.product.badge, u.name, Fmt.compact(u.todayTokens), u.hasRealTokens ? "" : "(估)", u.todayCredits,
                         u.lastEventAt.map { Fmt.relative($0) } ?? "无"))
        }
        if snap.users.isEmpty { print("  （未发现）") }
        print("")

        print("── 今日汇总 ──")
        print("  输出 tokens\(snap.hasRealTokens ? "" : "(估算)") \(Fmt.compact(snap.today.output))  积分 \(creditsSplit(snap.todayByProduct))")
        print("  输入 tokens(按上下文标定) \(Fmt.compact(snap.today.input))  其中命中缓存 \(Fmt.compact(snap.today.cacheRead)) · 新建 \(Fmt.compact(snap.today.cacheWrite))")
        print("  \(snap.todayCalls) 次调用，\(snap.todaySessions) 个会话")
        print(String(format: "  峰值 TPS %@  平均 TPS %@  单次最高 %@  实时 %@",
                     Fmt.tps(snap.todayPeakTPS), Fmt.tps(snap.todayAvgTPS),
                     Fmt.tps(snap.todayMaxCallTPS), Fmt.tps(snap.liveTPS)))
        print("  本月积分 \(creditsSplit(snap.monthByProduct))")
        if settings.creditPrice > 0 {
            print("  费用估算（分产品折算，按 \(String(format: "%.2f", settings.creditPrice)) 元/积分）")
            print("    今日 \(costSplit(snap.todayByProduct, settings) ?? "0")")
            print("    本月 \(costSplit(snap.monthByProduct, settings) ?? "0")")
        } else {
            print("  费用估算 未启用（单价为 0）")
        }
        print("")

        print("── 会话明细（近 7 天） ──")
        for s in snap.sessions {
            print(String(format: "  %@  %@  [%@]", String(s.sessionId.prefix(8)), s.projectName, s.product.badge))
            print(String(format: "      %@ → %@  调用 %d  输出 %@ tokens%@  积分 %.2f  平均 %@ t/s  峰值 %@ t/s",
                         df.string(from: s.start), df.string(from: s.end),
                         s.calls, Fmt.compact(s.totals.output), s.hasRealTokens ? "" : "(估)", s.credits,
                         Fmt.tps(s.avgTPS), Fmt.tps(s.peakTPS)))
            print(String(format: "      输入 %@ tokens（命中 %@ · 新建 %@）",
                         Fmt.compact(s.totals.input), Fmt.compact(s.totals.cacheRead), Fmt.compact(s.totals.cacheWrite)))
        }
        print("")

        print("── 解析异常 ──")
        if snap.sourceIssues.isEmpty { print("  无") }
        else { for i in snap.sourceIssues { print("  \(i)") } }
    }

    /// "CN 175.48 · WB 34.85"（积分为两套账，不跨产品相加）
    private static func creditsSplit(_ dict: [QoderProduct: ProductTotals]) -> String {
        let parts = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = dict[p], t.calls > 0 else { return nil }
            return String(format: "%@ %.2f", p.badge, t.credits)
        }
        return parts.isEmpty ? "0" : parts.joined(separator: " · ")
    }

    private static func costSplit(_ dict: [QoderProduct: ProductTotals], _ settings: AppSettings) -> String? {
        let parts = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = dict[p], t.calls > 0 else { return nil }
            return "\(p.badge) \(settings.money(t.cost))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
