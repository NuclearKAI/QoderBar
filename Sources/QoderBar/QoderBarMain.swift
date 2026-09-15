import AppKit

enum AppInfo {
    static let name = "QoderBar"
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1.0"
}

@main
enum QoderBarMain {
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            exit(0)
        }

        if arguments.contains("--version") {
            print("QoderBar \(AppInfo.version)")
            exit(0)
        }

        if arguments.contains("--dump") {
            CLIDump.run()
            exit(0)
        }

        if arguments.contains("--json") {
            CLIDump.runJSON()
            exit(0)
        }

        if arguments.contains("--quota-test") {
            CLIDump.runQuotaTest()
            exit(0)
        }

        if arguments.contains("--check-update") {
            CLIDump.runCheckUpdate()
            exit(0)
        }

        let debugView = arguments.compactMap { arg -> String? in
            arg.hasPrefix("--panel=") ? String(arg.dropFirst("--panel=".count)) : nil
        }.first

        let debugUser = arguments.compactMap { arg -> String? in
            arg.hasPrefix("--user=") ? String(arg.dropFirst("--user=".count)) : nil
        }.first

        guard SingleInstance.acquire() else {
            FileHandle.standardError.write("QoderBar 已在运行\n".data(using: .utf8)!)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(
            openPanelOnLaunch: arguments.contains("--open-panel") || debugView != nil || debugUser != nil,
            debugView: debugView,
            debugUser: debugUser)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func printHelp() {
        print("""
        QoderBar \(AppInfo.version) — Qoder / WorkBuddy 用量菜单栏监控

        用法:
          QoderBar                     启动菜单栏应用
          QoderBar --dump              扫描数据并打印自检报告（不启动 UI）
          QoderBar --json              输出机器可读 JSON（脚本/CI 用）
          QoderBar --quota-test        诊断官方额度抓取链路
          QoderBar --check-update      检查 GitHub Releases 是否有新版本
          QoderBar --version           打印版本
          QoderBar --help              显示帮助
          QoderBar --open-panel        启动后自动展开面板（调试用）
          QoderBar --panel=<view>      展开面板并定位视图（调试用）
                                       view: live | day | week | month | heatmap | settings
          QoderBar --user=<userKey>    启动后选中指定用户（调试用）
        """)
    }
}
