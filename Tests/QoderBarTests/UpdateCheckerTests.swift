import Testing
@testable import QoderBar
import Foundation

/// 自动更新：版本比较、发布解析、下载→校验→安装管线
/// （串行执行：部分用例共享 UserDefaults 中的更新源覆盖值）
@Suite(.serialized) struct UpdateCheckerTests {
    // MARK: - 版本比较

    @Test func versionComparison() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        #expect(UpdateChecker.isNewer("1.1.1", than: "1.1.0"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewer("1.0.9", than: "1.1.0"))
        #expect(UpdateChecker.parseVersion("v1.2.3-beta") == [1, 2, 3])
    }

    // MARK: - 发布解析

    @Test func checkParsesLatestRelease() throws {
        let repo = "owner/repo"
        UserDefaults.standard.set(repo, forKey: "QoderBarUpdateRepo")
        defer { UserDefaults.standard.removeObject(forKey: "QoderBarUpdateRepo") }

        let json = #"""
        {"tag_name":"v1.2.0","body":"更新说明","html_url":"https://github.com/owner/repo/releases/tag/v1.2.0",
        "assets":[
          {"name":"QoderBar-1.2.0.zip","browser_download_url":"https://github.com/owner/repo/releases/download/v1.2.0/QoderBar-1.2.0.zip"},
          {"name":"QoderBar-1.2.0.zip.sha256","browser_download_url":"https://github.com/owner/repo/releases/download/v1.2.0/QoderBar-1.2.0.zip.sha256"}
        ]}
        """#
        let key = "https://api.github.com/repos/\(repo)/releases/latest"
        let transport = MockTransport(dataMap: [key: Data(json.utf8)])

        let outcome = UpdateChecker.check(current: "1.1.0", transport: transport)
        guard case .available(let release) = outcome else {
            Issue.record("应识别到新版本，实际: \(outcome)"); return
        }
        #expect(release.version == "1.2.0")
        #expect(release.notes == "更新说明")
        #expect(release.zipURL.absoluteString.hasSuffix("QoderBar-1.2.0.zip"))
        #expect(release.sha256URL != nil)

        // 同版本 → upToDate
        if case .upToDate = UpdateChecker.check(current: "1.2.0", transport: transport) {} else {
            Issue.record("同版本应判定为最新")
        }
    }

    @Test func checkRejectsMissingZipAsset() {
        let repo = "owner/repo"
        UserDefaults.standard.set(repo, forKey: "QoderBarUpdateRepo")
        defer { UserDefaults.standard.removeObject(forKey: "QoderBarUpdateRepo") }
        let key = "https://api.github.com/repos/\(repo)/releases/latest"
        let transport = MockTransport(dataMap: [key: Data(#"{"tag_name":"v9.9.9","assets":[]}"#.utf8)])
        if case .failed = UpdateChecker.check(current: "1.1.0", transport: transport) {} else {
            Issue.record("缺少资产应报失败")
        }
    }

    // MARK: - 下载 → sha256 → 签名校验 → 安装

    @Test func installPipelineSwapsBundleAfterVerification() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("QoderBarUpdateTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 当前安装（1.1.0）与新版本（1.2.0）
        let currentDir = root.appendingPathComponent("current")
        let newDir = root.appendingPathComponent("new")
        try fm.createDirectory(at: currentDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeFakeApp(in: currentDir, version: "1.1.0")
        try makeFakeApp(in: newDir, version: "1.2.0")

        // 打包新版本并生成校验文件
        let zip = root.appendingPathComponent("QoderBar-1.2.0.zip")
        try runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", newDir.appendingPathComponent("QoderBar.app").path, zip.path])
        let hash = try UpdateChecker.sha256Hex(ofFile: zip)

        let repo = "owner/repo"
        let zipURL = URL(string: "https://github.com/owner/repo/releases/download/v1.2.0/QoderBar-1.2.0.zip")!
        let shaURL = URL(string: "\(zipURL.absoluteString).sha256")!
        let transport = MockTransport(
            dataMap: [shaURL.absoluteString: Data("\(hash)  QoderBar-1.2.0.zip\n".utf8)],
            downloadMap: [zipURL.absoluteString: zip])

        let release = UpdateRelease(version: "1.2.0", notes: "", zipURL: zipURL, sha256URL: shaURL, htmlURL: nil)
        let currentAppPath = currentDir.appendingPathComponent("QoderBar.app", isDirectory: true).path

        try UpdateChecker.downloadAndInstall(
            release, transport: transport, currentBundlePath: currentAppPath,
            verifySignature: true, relaunch: false)

        // 直接读 Info.plist（Bundle(path:) 在本进程内有缓存，会读到替换前的旧包）
        let installedPlist = NSDictionary(contentsOf: URL(fileURLWithPath: currentAppPath)
            .appendingPathComponent("Contents/Info.plist"))
        #expect(installedPlist?["CFBundleShortVersionString"] as? String == "1.2.0")
    }

    @Test func installRejectsChecksumMismatch() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("QoderBarUpdateTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let newDir = root.appendingPathComponent("new")
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeFakeApp(in: newDir, version: "1.2.0")
        let zip = root.appendingPathComponent("QoderBar-1.2.0.zip")
        try runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", newDir.appendingPathComponent("QoderBar.app").path, zip.path])

        let zipURL = URL(string: "https://github.com/owner/repo/releases/download/v1.2.0/QoderBar-1.2.0.zip")!
        let shaURL = URL(string: "\(zipURL.absoluteString).sha256")!
        let transport = MockTransport(
            dataMap: [shaURL.absoluteString: Data(String(repeating: "0", count: 64).utf8)],
            downloadMap: [zipURL.absoluteString: zip])

        let release = UpdateRelease(version: "1.2.0", notes: "", zipURL: zipURL, sha256URL: shaURL, htmlURL: nil)
        let currentAppPath = root.appendingPathComponent("current/QoderBar.app").path
        #expect(throws: (any Error).self) {
            try UpdateChecker.downloadAndInstall(
                release, transport: transport, currentBundlePath: currentAppPath,
                verifySignature: false, relaunch: false)
        }
    }

    @Test func disallowedHostIsRejected() {
        let urls = ["https://evil.example.com/QoderBar-1.2.0.zip", "https://raw.githubusercontent.com/x/y"]
        for s in urls {
            let transport = LiveUpdateTransport()
            #expect(throws: (any Error).self) { _ = try transport.data(from: URL(string: s)!) }
        }
    }

    // MARK: - 工具

    private func makeFakeApp(in dir: URL, version: String) throws {
        let app = dir.appendingPathComponent("QoderBar.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.kailab.qoderbar</string>
        <key>CFBundleExecutable</key><string>QoderBar</string>
        <key>CFBundleName</key><string>QoderBar</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let bin = macos.appendingPathComponent("QoderBar")
        try "#!/bin/sh\nexit 0\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    private func runProcess(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.installFailed("\(path) exit \(p.terminationStatus)") }
    }
}

private struct MockTransport: UpdateTransport {
    var dataMap: [String: Data] = [:]
    var downloadMap: [String: URL] = [:]

    func data(from url: URL) throws -> Data {
        guard let d = dataMap[url.absoluteString] else {
            throw UpdateError.badResponse("no mock for \(url.absoluteString)")
        }
        return d
    }

    func download(from url: URL) throws -> URL {
        guard let u = downloadMap[url.absoluteString] else {
            throw UpdateError.badResponse("no mock for \(url.absoluteString)")
        }
        return u
    }
}
