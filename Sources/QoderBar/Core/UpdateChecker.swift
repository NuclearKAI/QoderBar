import Foundation
import CryptoKit
import AppKit

/// 从 GitHub Releases 检查并安装更新。
/// 安全约束：
/// 1. 只访问 api.github.com / github.com / *.githubusercontent.com（HTTPS），不接受其它来源；
/// 2. 下载后先校验发布页同款 `.sha256` 资产，再校验解压产物的代码签名与包标识一致；
/// 3. 更新包直接原地替换并重启，失败时回退到 Finder 手动替换。
enum UpdateChecker {
    /// 发布仓库（owner/repo）。留空表示未配置，自动更新功能关闭。
    static let defaultRepo = "NuclearKAI/QoderBar"

    static var repo: String {
        if let override = UserDefaults.standard.string(forKey: "QoderBarUpdateRepo"), !override.isEmpty {
            return override
        }
        return defaultRepo
    }

    static var isConfigured: Bool { !repo.isEmpty }

    static let allowedHosts: Set<String> = [
        "api.github.com", "github.com", "www.github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "codeload.github.com"
    ]

    static let skippedVersionKey = "QoderBarSkippedVersion"
    static let lastCheckKey = "QoderBarLastUpdateCheck"
    static let autoCheckKey = "QoderBarAutoUpdateCheck"

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }
}

// MARK: - 模型

struct UpdateRelease: Equatable {
    var version: String
    var notes: String
    var zipURL: URL
    var sha256URL: URL?
    var htmlURL: URL?
}

enum UpdateCheckOutcome: Equatable {
    case notConfigured
    case upToDate(current: String)
    case available(UpdateRelease)
    case failed(String)
}

enum UpdateError: LocalizedError {
    case notConfigured
    case badResponse(String)
    case disallowedHost(String)
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)
    case signatureInvalid(String)
    case bundleMismatch(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置更新源"
        case .badResponse(let m): return "更新源响应异常：\(m)"
        case .disallowedHost(let h): return "下载地址不在允许的 GitHub 域名内：\(h)"
        case .checksumMissing: return "发布资产缺少 sha256 校验文件"
        case .checksumMismatch(let e, let a): return "校验不通过（期望 \(e.prefix(12))… 实际 \(a.prefix(12))…）"
        case .signatureInvalid(let m): return "更新包签名无效：\(m)"
        case .bundleMismatch(let m): return "更新包与当前应用不一致：\(m)"
        case .installFailed(let m): return "安装失败：\(m)"
        }
    }
}

// MARK: - 网络（可注入，便于测试）

protocol UpdateTransport {
    func data(from url: URL) throws -> Data
    func download(from url: URL) throws -> URL
}

struct LiveUpdateTransport: UpdateTransport {
    func data(from url: URL) throws -> Data {
        guard let host = url.host, UpdateChecker.allowedHosts.contains(host) else {
            throw UpdateError.disallowedHost(url.host ?? url.absoluteString)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error>!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QoderBar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                outcome = .failure(UpdateError.badResponse("HTTP \(http.statusCode)"))
                return
            }
            outcome = .success(data ?? Data())
        }.resume()
        semaphore.wait()
        return try outcome.get()
    }

    func download(from url: URL) throws -> URL {
        guard let host = url.host, UpdateChecker.allowedHosts.contains(host) else {
            throw UpdateError.disallowedHost(url.host ?? url.absoluteString)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<URL, Error>!
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("QoderBar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                outcome = .failure(UpdateError.badResponse("HTTP \(http.statusCode)"))
                return
            }
            guard let location else {
                outcome = .failure(UpdateError.badResponse("空下载"))
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("QoderBarUpdate-\(UUID().uuidString)")
                .appendingPathExtension("zip")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                outcome = .success(dest)
            } catch {
                outcome = .failure(error)
            }
        }.resume()
        semaphore.wait()
        return try outcome.get()
    }
}

// MARK: - 检查与安装

extension UpdateChecker {
    static func check(current: String = AppInfo.version, transport: UpdateTransport = LiveUpdateTransport()) -> UpdateCheckOutcome {
        guard isConfigured else { return .notConfigured }
        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            let data = try transport.data(from: url)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failed("无法解析发布信息")
            }
            if let message = root["message"] as? String {
                return .failed(message)
            }
            guard let tag = root["tag_name"] as? String else {
                return .failed("发布信息缺少 tag")
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = root["body"] as? String ?? ""
            let htmlURL = (root["html_url"] as? String).flatMap(URL.init(string:))

            let assets = root["assets"] as? [[String: Any]] ?? []
            let zipName = "QoderBar-\(version).zip"
            guard let zipAsset = assets.first(where: { $0["name"] as? String == zipName }),
                  let zipStr = zipAsset["browser_download_url"] as? String,
                  let zipURL = URL(string: zipStr) else {
                return .failed("该版本没有 \(zipName) 资产")
            }
            let shaURL = assets.first { $0["name"] as? String == "\(zipName).sha256" }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }

            guard isNewer(version, than: current) else { return .upToDate(current: current) }
            return .available(UpdateRelease(version: version, notes: notes, zipURL: zipURL, sha256URL: shaURL, htmlURL: htmlURL))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 下载 → sha256 校验 → 代码签名校验 → 原地替换并重启
    static func downloadAndInstall(
        _ release: UpdateRelease,
        transport: UpdateTransport = LiveUpdateTransport(),
        currentBundlePath: String = Bundle.main.bundlePath,
        verifySignature: Bool = true,
        relaunch: Bool = true
    ) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("QoderBarUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let zip = try transport.download(from: release.zipURL)

        // 1) sha256 校验（发布页同名资产）
        if let shaURL = release.sha256URL {
            let shaData = try transport.data(from: shaURL)
            let expected = String(data: shaData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init) ?? ""
            let actual = try sha256Hex(ofFile: zip)
            guard expected.count == 64 else { throw UpdateError.checksumMissing }
            guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                throw UpdateError.checksumMismatch(expected: expected, actual: actual)
            }
        } else {
            throw UpdateError.checksumMissing
        }

        // 2) 解压并校验签名 / 标识
        let extractDir = workDir.appendingPathComponent("extract")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])
        let newApp = extractDir.appendingPathComponent("QoderBar.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw UpdateError.installFailed("压缩包内缺少 QoderBar.app")
        }
        let currentBundleID = Bundle(path: currentBundlePath)?.bundleIdentifier
            ?? Bundle.main.bundleIdentifier ?? "com.kailab.qoderbar"
        if verifySignature {
            try verify(appPath: newApp.path, expectedBundleID: currentBundleID, currentBundlePath: currentBundlePath)
        }

        // 3) 原地替换（由后台脚本等待本进程退出后执行）
        let parent = URL(fileURLWithPath: currentBundlePath).deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            throw UpdateError.installFailed("没有写入权限，已为你打开新版本，请手动拖入「应用程序」")
        }
        if relaunch {
            let script = """
            #!/bin/sh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf \(shellQuote(currentBundlePath)) && /usr/bin/ditto \(shellQuote(newApp.path)) \(shellQuote(currentBundlePath)) && /usr/bin/open \(shellQuote(currentBundlePath))
            """
            let scriptURL = workDir.appendingPathComponent("swap.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path]
            try task.run()
        } else {
            // 测试/无重启场景：立即替换
            try? fm.removeItem(atPath: currentBundlePath)
            try fm.copyItem(at: newApp, to: URL(fileURLWithPath: currentBundlePath))
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parseVersion(a)
        let pb = parseVersion(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parseVersion(_ v: String) -> [Int] {
        let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
        return trimmed.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    static func sha256Hex(ofFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(appPath: String, expectedBundleID: String, currentBundlePath: String) throws {
        do {
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])
        } catch {
            throw UpdateError.signatureInvalid("codesign --verify 失败")
        }
        let info = try run("/usr/bin/codesign", ["-dv", "--verbose=4", appPath])
        let identifier = info.split(separator: "\n")
            .first { $0.hasPrefix("Identifier=") }?
            .replacingOccurrences(of: "Identifier=", with: "") ?? ""
        guard identifier == expectedBundleID else {
            throw UpdateError.bundleMismatch("包标识 \(identifier) ≠ \(expectedBundleID)")
        }
        let newTeam = info.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }?
            .replacingOccurrences(of: "TeamIdentifier=", with: "") ?? ""
        let currentTeam = (try? run("/usr/bin/codesign", ["-dv", "--verbose=4", currentBundlePath]))?
            .split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }?
            .replacingOccurrences(of: "TeamIdentifier=", with: "") ?? ""
        if !currentTeam.isEmpty, currentTeam != "not set", newTeam != currentTeam {
            throw UpdateError.bundleMismatch("签名团队不一致（\(newTeam) ≠ \(currentTeam)）")
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw UpdateError.installFailed("\(path) 退出码 \(p.terminationStatus)：\(output.prefix(200))")
        }
        return output
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
