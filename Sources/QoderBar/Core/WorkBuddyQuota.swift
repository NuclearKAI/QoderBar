import Foundation

/// WorkBuddy（腾讯）官方积分余额：读取客户端登录态（明文 JSON）+ 资源汇总接口。
/// POST https://copilot.tencent.com/billing/meter/get-user-resource-summary
/// 返回 data.Packages[{CycleTotalCapacity, CycleRemainCapacity, CycleUsedCapacity}]（字符串数字）。
/// token 只在内存中使用，不落盘。
enum WorkBuddyQuota {
    static let infoURL = Paths.home.appendingPathComponent(
        "Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
    static let summaryURL = URL(string: "https://copilot.tencent.com/billing/meter/get-user-resource-summary")!

    static func accessToken() throws -> String {
        guard let data = try? Data(contentsOf: infoURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = obj["auth"] as? [String: Any],
              let token = auth["accessToken"] as? String, !token.isEmpty
        else {
            throw QuotaFetchError.parse("未找到 WorkBuddy 登录态，请在 WorkBuddy 客户端登录后重试")
        }
        return token
    }

    static func fetch(timeout: TimeInterval = 15) throws -> QuotaSnapshot {
        let token = try accessToken()
        var request = URLRequest(url: summaryURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WorkBuddy", forHTTPHeaderField: "User-Agent")

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
                outcome = .success(try parse(data))
            } catch {
                outcome = .failure(error)
            }
        }.resume()
        semaphore.wait()
        return try outcome.get()
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError.parse("invalid JSON")
        }
        if let code = root["code"] as? Int, code != 0 {
            throw QuotaFetchError.parse("接口返回 code=\(code) \(root["msg"] as? String ?? "")")
        }
        guard let payload = root["data"] as? [String: Any],
              let packages = payload["Packages"] as? [[String: Any]] else {
            throw QuotaFetchError.parse("响应缺少 Packages")
        }
        var total = 0.0
        var remain = 0.0
        var used = 0.0
        for p in packages {
            total += double(p["CycleTotalCapacity"]) ?? 0
            remain += double(p["CycleRemainCapacity"]) ?? 0
            used += double(p["CycleUsedCapacity"]) ?? 0
        }
        let pct = total > 0 ? used / total * 100 : 0
        return QuotaSnapshot(
            product: .workbuddy,
            used: used, total: total, remaining: remain,
            percentage: pct, unit: "credits", resetsAt: nil,
            updatedAt: now, source: .client, site: nil)
    }

    private static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
