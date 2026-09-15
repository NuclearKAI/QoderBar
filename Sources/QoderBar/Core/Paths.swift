import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var appSupport: URL {
        let url = home.appendingPathComponent("Library/Application Support/QoderBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var databaseURL: URL { appSupport.appendingPathComponent("usage.sqlite") }
    static var lockURL: URL { appSupport.appendingPathComponent("app.lock") }

    struct ProductSource {
        var product: QoderProduct
        var roots: [URL]
        var statusFile: URL
    }

    static var sources: [ProductSource] {
        [
            ProductSource(
                product: .qoderCN,
                roots: [home.appendingPathComponent(".qoder-cn/projects", isDirectory: true)],
                statusFile: home.appendingPathComponent(".qoder-cn/.qoder-app-status.json")
            ),
            ProductSource(
                product: .qoderINTL,
                roots: [home.appendingPathComponent(".qoder/projects", isDirectory: true)],
                statusFile: home.appendingPathComponent(".qoder/.qoder-app-status.json")
            ),
            ProductSource(
                product: .workbuddy,
                roots: [
                    home.appendingPathComponent(".workbuddy/projects", isDirectory: true),
                    home.appendingPathComponent(".codebuddy/projects", isDirectory: true)
                ],
                statusFile: home.appendingPathComponent(
                    "Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
            )
        ]
    }

    static let launchAgentLabel = "com.kailab.qoderbar"
    static var launchAgentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }
}
