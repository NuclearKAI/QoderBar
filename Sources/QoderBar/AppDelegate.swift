import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let openPanelOnLaunch: Bool
    private let debugView: String?
    private let debugUser: String?
    private var model: AppModel?
    private var statusController: StatusItemController?

    private static let firstLaunchKey = "QoderBarDidFirstLaunch"

    init(openPanelOnLaunch: Bool, debugView: String? = nil, debugUser: String? = nil) {
        // 首次启动自动展开面板，让用户一眼看到它在工作
        let firstLaunch = !UserDefaults.standard.bool(forKey: Self.firstLaunchKey)
        if firstLaunch { UserDefaults.standard.set(true, forKey: Self.firstLaunchKey) }
        self.openPanelOnLaunch = openPanelOnLaunch || firstLaunch
        self.debugView = debugView
        self.debugUser = debugUser
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        if let debugUser { model.selectUser(debugUser) }
        switch debugView {
        case "day": model.range = .day
        case "week": model.range = .week
        case "month": model.range = .month
        case "heatmap": model.range = .heatmap
        case "settings":
            // 等弹窗显示并定位完成后再弹出设置，模拟点击齿轮的时序
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak model] in
                model?.showSettings = true
            }
        default: break
        }
        statusController = StatusItemController(model: model, openPanelOnLaunch: openPanelOnLaunch)
        Engine.shared.start()

        if model.settings.notificationsEnabled && model.settings.dailyCreditBudget > 0 {
            BudgetNotificationCenter.shared.requestAuthorizationIfNeeded()
        }

        // 启动后静默检查更新（24 小时节流，仅访问 GitHub）
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak model] in
            model?.checkForUpdates(interactive: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.settings.save()
    }
}
