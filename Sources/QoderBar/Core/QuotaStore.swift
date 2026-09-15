import Foundation

/// 官方额度快照（Qoder 或 WorkBuddy）
struct QuotaSnapshot: Equatable {
    var product: QoderProduct
    var used: Double
    var total: Double
    var remaining: Double
    var percentage: Double
    var unit: String?
    var resetsAt: Date?
    var updatedAt: Date
    var source: QuotaSource
    /// Qoder 站点（用于打开用量页）；WorkBuddy 为 nil
    var site: QuotaSite?
}

enum QuotaSource: String {
    /// 自动读取客户端本机登录态
    case client
    /// 用户粘贴的 Cookie
    case cookie
}

enum QuotaFetchError: LocalizedError {
    case invalidCredentials
    case http(Int)
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Cookie 无效或已过期，请重新登录后复制新的 Cookie"
        case .http(let code): return "接口返回 HTTP \(code)"
        case .network(let msg): return "网络错误：\(msg)"
        case .parse(let msg): return "响应解析失败：\(msg)"
        }
    }
}

enum QuotaFetcher {
    static func fetch(cookie: String, site: QuotaSite, timeout: TimeInterval = 15) throws -> QuotaSnapshot {
        var request = URLRequest(url: site.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue(site.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(site.webOrigin)/account/usage", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<QuotaSnapshot, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(QuotaFetchError.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(QuotaFetchError.network("无响应"))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome = .failure(QuotaFetchError.invalidCredentials)
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                outcome = .failure(QuotaFetchError.http(http.statusCode))
                return
            }
            do {
                outcome = .success(try parse(data, site: site))
            } catch {
                outcome = .failure(error)
            }
        }.resume()
        semaphore.wait()
        return try outcome.get()
    }

    static func parse(_ data: Data, site: QuotaSite, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError.parse("invalid JSON")
        }
        var used = 0.0
        var total = 0.0
        var remaining = 0.0
        var percentage: Double?
        var unit: String?
        var hasQuota = false
        for key in ["totalQuota", "total_quota", "sharedQuota", "shared_quota"] {
            guard let container = root[key] as? [String: Any] else { continue }
            guard let summary = (container["quotaSummary"] ?? container["quota_summary"]) as? [String: Any] else { continue }
            let u = double(summary["usedValue"] ?? summary["used_value"]) ?? 0
            let l = double(summary["limitValue"] ?? summary["limit_value"]) ?? 0
            let r = double(summary["remainingValue"] ?? summary["remaining_value"]) ?? max(0, l - u)
            used += u
            total += l
            remaining += r
            if percentage == nil { percentage = double(summary["usagePercentage"] ?? summary["usage_percentage"]) }
            if unit == nil { unit = summary["unit"] as? String }
            hasQuota = true
        }
        guard hasQuota else { throw QuotaFetchError.parse("missing quotaSummary") }

        let pct = percentage ?? (total > 0 ? used / total * 100 : 0)
        let resetsAt = parseDate(root["nextResetAt"] ?? root["next_reset_at"])
        return QuotaSnapshot(
            product: site == .cn ? .qoderCN : .qoderINTL,
            used: used, total: total, remaining: remaining,
            percentage: pct, unit: unit, resetsAt: resetsAt, updatedAt: now, source: .cookie, site: site)
    }

    private static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            return JSONLScanner.isoFractional.date(from: s) ?? JSONLScanner.isoPlain.date(from: s)
        }
        if let n = any as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e9 { return Date(timeIntervalSince1970: v) }
        }
        return nil
    }
}

/// 官方额度缓存与轮询（后台队列拉取，回调到主线程通知 UI）。
/// 同时维护 Qoder（客户端登录态或 Cookie）与 WorkBuddy（客户端登录态）两份额度。
final class QuotaStore {
    static let shared = QuotaStore()

    private(set) var snapshots: [QoderProduct: QuotaSnapshot] = [:]
    private(set) var errors: [QoderProduct: String] = [:]
    private var lastAttempt: [QoderProduct: Date] = [:]
    private var lastCookie = ""
    private var lastSite: QuotaSite = .cn
    private let queue = DispatchQueue(label: "qoderbar.quota", qos: .utility)
    private var inFlight: Set<QoderProduct> = []

    var onChange: (() -> Void)?

    func snapshot(for product: QoderProduct) -> QuotaSnapshot? { snapshots[product] }
    func error(for product: QoderProduct) -> String? { errors[product] }

    /// 距上次尝试超过 interval 秒才会再次请求；Cookie/站点变化时 Qoder 侧立即重拉
    func refreshIfNeeded(cookie: String, site: QuotaSite, interval: TimeInterval = 600) {
        queue.async {
            let configChanged = cookie != self.lastCookie || site != self.lastSite
            self.lastCookie = cookie
            self.lastSite = site

            let qoderProduct: QoderProduct = site == .cn ? .qoderCN : .qoderINTL
            self.refreshLocked(product: qoderProduct, interval: configChanged ? 0 : interval) {
                try QoderIDEClient.fetch(cookie: cookie.isEmpty ? nil : cookie, site: site)
            }
            guard FileManager.default.fileExists(atPath: WorkBuddyQuota.infoURL.path) else { return }
            self.refreshLocked(product: .workbuddy, interval: interval) {
                try WorkBuddyQuota.fetch()
            }
        }
    }

    private func refreshLocked(product: QoderProduct, interval: TimeInterval, work: () throws -> QuotaSnapshot) {
        guard !inFlight.contains(product) else { return }
        if let t = lastAttempt[product], Date().timeIntervalSince(t) < interval { return }
        inFlight.insert(product)
        lastAttempt[product] = Date()
        do {
            let snap = try work()
            snapshots[product] = snap
            errors[product] = nil
        } catch {
            errors[product] = error.localizedDescription
        }
        inFlight.remove(product)
        DispatchQueue.main.async { self.onChange?() }
    }
}
