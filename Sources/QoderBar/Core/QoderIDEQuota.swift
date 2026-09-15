import Foundation
import Security
import CommonCrypto

/// 读取 Qoder 客户端（IDE）本机登录态并调用官方用量接口。
/// 链路：钥匙串 "Qoder CN App Safe Storage" 密钥 → 解密 auth.v1.dat（Chromium OSCrypt v10）
/// → 取出 access token → GET openapi.qoder.com.cn/sash/api/v2/me/usage。
/// 首次读取钥匙串会触发一次系统授权弹窗，选择"始终允许"后不再询问；token 不落盘。
enum QoderIDEClient {
    struct Credentials {
        var service: String
        var account: String
        var authFile: URL
        var usageURL: URL
        var site: QuotaSite
    }

    static func credentials(for site: QuotaSite) -> Credentials? {
        let home = Paths.home
        switch site {
        case .cn:
            return Credentials(
                service: "Qoder CN App Safe Storage",
                account: "Qoder CN App Key",
                authFile: home.appendingPathComponent(
                    "Library/Application Support/com.qodercn.app.stable/auth.v1.dat"),
                usageURL: URL(string: "https://openapi.qoder.com.cn/sash/api/v2/me/usage")!,
                site: site)
        case .intl:
            return Credentials(
                service: "Qoder App Safe Storage",
                account: "Qoder App Key",
                authFile: home.appendingPathComponent(
                    "Library/Application Support/Qoder/auth.v1.dat"),
                usageURL: URL(string: "https://openapi.qoder.com/sash/api/v2/me/usage")!,
                site: site)
        }
    }

    /// 读取钥匙串中的 safeStorage 密钥（首次会弹系统授权）
    static func safeStorageKey(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// 解密 auth.v1.dat（Chromium OSCrypt：v10 前缀 + PBKDF2-SHA1(1003, "saltysalt") + AES-128-CBC）
    static func decryptAuthFile(_ url: URL, key: Data) throws -> [String: Any] {
        let raw = try Data(contentsOf: url)
        guard raw.count > 3, raw.prefix(3) == Data("v10".utf8) else {
            throw QuotaFetchError.parse("auth.v1.dat 格式未知")
        }
        let ciphertext = raw.dropFirst(3)

        var derived = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let keyBytes = [UInt8](key)
        let status = salt.withUnsafeBufferPointer { saltBuf in
            keyBytes.withUnsafeBufferPointer { keyBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    keyBuf.baseAddress, keyBuf.count,
                    saltBuf.baseAddress, saltBuf.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw QuotaFetchError.parse("密钥派生失败") }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let ct = [UInt8](ciphertext)
        let cryptStatus = ct.withUnsafeBufferPointer { ctBuf in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                derived, derived.count,
                iv,
                ctBuf.baseAddress, ctBuf.count,
                &output, output.count,
                &outputLength)
        }
        guard cryptStatus == kCCSuccess else { throw QuotaFetchError.parse("解密失败（密钥不匹配）") }
        let plain = Data(output.prefix(outputLength))
        guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw QuotaFetchError.parse("解密结果不是 JSON")
        }
        return obj
    }

    /// 取出当前有效的 access token（按文件 mtime 缓存，IDE 刷新文件后自动重新解密）
    private static var cachedToken: (path: String, mtime: Date, token: String)?

    static func accessToken(for creds: Credentials) throws -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: creds.authFile.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        if let cached = cachedToken, cached.path == creds.authFile.path, cached.mtime == mtime {
            return cached.token
        }
        guard FileManager.default.fileExists(atPath: creds.authFile.path) else {
            throw QuotaFetchError.parse("未找到 Qoder 客户端登录文件")
        }
        guard let key = safeStorageKey(service: creds.service, account: creds.account) else {
            throw QuotaFetchError.parse("钥匙串读取失败（请在弹窗中选择\"始终允许\"）")
        }
        let obj = try decryptAuthFile(creds.authFile, key: key)
        guard let token = obj["token"] as? String, !token.isEmpty else {
            throw QuotaFetchError.parse("登录文件中缺少 token")
        }
        cachedToken = (creds.authFile.path, mtime, token)
        return token
    }

    static func fetch(cookie: String? = nil, site: QuotaSite, timeout: TimeInterval = 15) throws -> QuotaSnapshot {
        guard let creds = credentials(for: site) else { throw QuotaFetchError.parse("不支持的站点") }
        let token: String
        let source: QuotaSource
        if let cookie, !cookie.isEmpty {
            // 显式 Cookie 优先（用户覆盖）
            return try QuotaFetcher.fetch(cookie: cookie, site: site, timeout: timeout)
        } else {
            token = try accessToken(for: creds)
            source = .client
        }
        let data = try authorizedGET(creds.usageURL, token: token, timeout: timeout)
        return try parseUsage(data, site: site, source: source)
    }

    /// 官方近一年 credits 汇总：totalCredits / peakCredits（credits-summary）
    static func fetchCreditsSummary(site: QuotaSite = .cn, timeout: TimeInterval = 15) throws -> (total: Double, peak: Double) {
        guard let creds = credentials(for: site) else { throw QuotaFetchError.parse("不支持的站点") }
        let token = try accessToken(for: creds)
        var comps = URLComponents(url: creds.usageURL, resolvingAgainstBaseURL: false)!
        comps.path = "/sash/api/v1/ai-conversations/credits-summary"
        comps.query = "product=app"
        let data = try authorizedGET(comps.url!, token: token, timeout: timeout)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError.parse("credits-summary 解析失败")
        }
        return (double(root["totalCredits"]) ?? 0, double(root["peakCredits"]) ?? 0)
    }

    /// 官方每日 credits（credits-heatmap）：[(yyyy-MM-dd, credits)]
    static func fetchCreditsHeatmap(days: Int = 120, site: QuotaSite = .cn, timeout: TimeInterval = 15) throws -> [(date: String, value: Double)] {
        guard let creds = credentials(for: site) else { throw QuotaFetchError.parse("不支持的站点") }
        let token = try accessToken(for: creds)
        var comps = URLComponents(url: creds.usageURL, resolvingAgainstBaseURL: false)!
        comps.path = "/sash/api/v1/ai-conversations/credits-heatmap"
        comps.query = "organization_id=&days=\(days)&product=app"
        let data = try authorizedGET(comps.url!, token: token, timeout: timeout)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw QuotaFetchError.parse("credits-heatmap 解析失败")
        }
        return items.compactMap { item in
            guard let date = item["date"] as? String else { return nil }
            return (date, double(item["value"]) ?? 0)
        }
    }

    /// 带 Bearer 的 GET（与 IDE 相同的头）
    private static func authorizedGET(_ url: URL, token: String, timeout: TimeInterval) throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("10", forHTTPHeaderField: "Cosy-ClientType")
        request.setValue("Qoder", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error>!
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
                cachedToken = nil
                outcome = .failure(QuotaFetchError.invalidCredentials)
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                outcome = .failure(QuotaFetchError.http(http.statusCode))
                return
            }
            outcome = .success(data)
        }.resume()
        semaphore.wait()
        return try outcome.get()
    }

    /// 解析 /sash/api/v2/me/usage：(qoderUsage.userQuota + addOnQuota) 合并
    static func parseUsage(_ data: Data, site: QuotaSite, source: QuotaSource, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = (root["qoderUsage"] ?? root["qoder_usage"]) as? [String: Any] else {
            throw QuotaFetchError.parse("响应缺少 qoderUsage")
        }
        var used = 0.0
        var total = 0.0
        var remaining = 0.0
        var percentage: Double?
        var unit: String?
        var hasQuota = false
        for key in ["userQuota", "user_quota", "addOnQuota", "add_on_quota"] {
            guard let q = usage[key] as? [String: Any] else { continue }
            let u = double(q["used"]) ?? 0
            let t = double(q["total"]) ?? 0
            let r = double(q["remaining"]) ?? max(0, t - u)
            used += u
            total += t
            remaining += r
            if percentage == nil { percentage = double(q["percentage"]) }
            if unit == nil { unit = q["unit"] as? String }
            hasQuota = true
        }
        guard hasQuota else { throw QuotaFetchError.parse("响应缺少额度数据") }

        var pct = percentage ?? (total > 0 ? used / total * 100 : 0)
        if pct <= 1 { pct *= 100 }
        let resetsAt = parseDate(usage["expiresAt"] ?? usage["expires_at"])
            ?? parseDate(usage["nextResetAt"] ?? usage["resetAt"])
        return QuotaSnapshot(
            product: site == .cn ? .qoderCN : .qoderINTL,
            used: used, total: total, remaining: remaining,
            percentage: pct, unit: unit, resetsAt: resetsAt, updatedAt: now, source: source, site: site)
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
