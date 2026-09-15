import Foundation
import Combine
import SwiftUI

final class AppModel: ObservableObject {
    @Published var snapshot: MetricsSnapshot = .empty
    @Published var range: TimeRange = .live { didSet { refresh() } }
    @Published var selectedUserKey: String? { didSet { refresh() } }
    @Published var settings: AppSettings = AppSettings.load() {
        didSet {
            settings.save()
            QuotaStore.shared.refreshIfNeeded(cookie: settings.quotaCookie, site: settings.quotaSite)
        }
    }
    @Published var showSettings = false
    @Published var menuBarTitle: String = ""
    @Published var meter: MenuBarMeter?
    @Published var quotas: [QoderProduct: QuotaSnapshot] = [:]
    @Published var quotaErrors: [QoderProduct: String] = [:]
    @Published var updateStatus: String?
    @Published var availableUpdate: UpdateRelease?
    /// 面板是否展开：关闭时暂停向视图推送快照，避免无谓的 SwiftUI 重绘
    var panelVisible = false

    let engine = Engine.shared
    private var timer: Timer?
    private var hasLoaded = false
    private var tickCount = 0
    private var lastQuotaTrigger = Date.distantPast

    init() {
        Engine.shared.onUpdate = { [weak self] in
            self?.refresh()
        }
        QuotaStore.shared.onChange = { [weak self] in
            self?.refresh(force: true)
        }
        refresh(force: true)
        // 1 秒心跳；空闲且面板收起时每 5 拍才做一次聚合（自适应）
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func tick() {
        tickCount += 1
        let recent = Date().timeIntervalSince(engine.lastActivity() ?? .distantPast) < 120
        let every = (panelVisible || recent) ? 1 : 5
        guard tickCount % every == 0 else { return }
        refresh()
    }

    func refresh(force: Bool = false) {
        let snap = engine.snapshot(range: range, userKey: selectedUserKey, settings: settings)
        menuBarTitle = Self.title(for: snap, settings: settings)
        meter = Self.meter(for: snap, settings: settings)
        BudgetNotifier.check(snapshot: snap, settings: settings)
        if panelVisible || force || !hasLoaded {
            snapshot = snap
            hasLoaded = true
        }
        quotas = QuotaStore.shared.snapshots
        quotaErrors = QuotaStore.shared.errors
        if Date().timeIntervalSince(lastQuotaTrigger) > 60 {
            lastQuotaTrigger = Date()
            QuotaStore.shared.refreshIfNeeded(cookie: settings.quotaCookie, site: settings.quotaSite)
        }
    }

    func panelDidOpen() {
        panelVisible = true
        engine.requestScanNow()
        refresh(force: true)
    }

    func panelDidClose() {
        panelVisible = false
    }

    // MARK: - 更新（GitHub Releases）

    /// 检查更新。interactive=false 时按 24 小时节流静默检查。
    func checkForUpdates(interactive: Bool) {
        guard UpdateChecker.isConfigured else {
            if interactive {
                updateStatus = "未配置更新源（发布前在 UpdateChecker.defaultRepo 填入 owner/repo）"
            }
            return
        }
        if !interactive {
            guard UpdateChecker.autoCheckEnabled else { return }
            if let last = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < 24 * 3600 {
                return
            }
        }
        updateStatus = "正在检查更新…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = UpdateChecker.check()
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: UpdateChecker.lastCheckKey)
                self?.handleUpdateOutcome(outcome, interactive: interactive)
            }
        }
    }

    private func handleUpdateOutcome(_ outcome: UpdateCheckOutcome, interactive: Bool) {
        switch outcome {
        case .notConfigured:
            updateStatus = "未配置更新源"
        case .upToDate(let current):
            updateStatus = "已是最新版本（\(current)）"
        case .failed(let message):
            updateStatus = "检查失败：\(message)"
            if interactive { presentAlert(title: "检查更新失败", text: message, buttons: ["好"]) }
        case .available(let release):
            updateStatus = "发现新版本 \(release.version)"
            let skipped = UserDefaults.standard.string(forKey: UpdateChecker.skippedVersionKey)
            if !interactive, skipped == release.version { return }
            availableUpdate = release
            presentUpdateAlert(release)
        }
    }

    private func presentUpdateAlert(_ release: UpdateRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        alert.informativeText = release.notes.isEmpty
            ? "是否现在下载并安装？"
            : String(release.notes.prefix(400))
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            updateStatus = "正在下载更新…"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    try UpdateChecker.downloadAndInstall(release)
                    DispatchQueue.main.async {
                        self?.updateStatus = "更新完成，应用即将重启"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            NSApp.terminate(nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.updateStatus = "更新失败：\(error.localizedDescription)"
                        self?.presentAlert(title: "更新失败", text: error.localizedDescription, buttons: ["好"])
                    }
                }
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: UpdateChecker.skippedVersionKey)
            updateStatus = "已跳过 \(release.version)"
        default:
            updateStatus = "有新版本 \(release.version) 可用"
        }
    }

    private func presentAlert(title: String, text: String, buttons: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for b in buttons { alert.addButton(withTitle: b) }
        alert.runModal()
    }

    func selectUser(_ key: String?) {
        selectedUserKey = key
    }

    /// 当前查看范围对应的产品：选中用户按其产品；"全部用户"默认 Qoder CN
    static func scopedProduct(for snap: MetricsSnapshot) -> QoderProduct {
        if let key = snap.selectedUserKey,
           let u = snap.users.first(where: { $0.userKey == key }) {
            return u.product
        }
        return .qoderCN
    }

    /// 菜单栏仪表：按当前查看范围的产品取官方额度；Qoder CN 无官方数据时退回本地预算
    static func meter(for snap: MetricsSnapshot, settings: AppSettings) -> MenuBarMeter? {
        func make(_ f: Double) -> MenuBarMeter {
            let level: MenuBarMeter.Level = f >= 1 ? .over : (f >= 0.8 ? .warn : .normal)
            return MenuBarMeter(fraction: min(1, max(0, f)), level: level)
        }
        let product = scopedProduct(for: snap)
        if let q = QuotaStore.shared.snapshot(for: product), q.total > 0 {
            return make(q.used / q.total)
        }
        guard product == .qoderCN else { return nil }
        if settings.monthlyCreditBudget > 0 {
            return make((snap.monthByProduct[.qoderCN]?.credits ?? 0) / settings.monthlyCreditBudget)
        }
        if settings.dailyCreditBudget > 0 {
            return make(primaryCredits(for: snap).credits / settings.dailyCreditBudget)
        }
        return nil
    }

    /// 菜单栏积分口径：优先 Qoder CN；当前范围只有单一产品时按其显示（不跨产品相加）
    static func primaryCredits(for snap: MetricsSnapshot) -> (credits: Double, cost: Double) {
        if let cn = snap.todayByProduct[.qoderCN] { return (cn.credits, cn.cost) }
        if snap.todayByProduct.count == 1, let only = snap.todayByProduct.values.first {
            return (only.credits, only.cost)
        }
        return (0, 0)
    }

    static func title(for snap: MetricsSnapshot, settings: AppSettings) -> String {
        switch settings.menuBarMode {
        case .iconOnly:
            return ""
        case .todayTokens:
            return Fmt.compact(snap.today.output)
        case .todayCredits:
            return String(format: "%.1f", primaryCredits(for: snap).credits)
        case .todayCost:
            let p = primaryCredits(for: snap)
            return p.cost > 0 ? settings.money(p.cost) : String(format: "%.1f", p.credits)
        case .liveTPS:
            let active = snap.isGenerating || snap.liveTPS > 0
            if active { return "\(Fmt.tps(snap.liveTPS)) t/s" }
            return String(format: "%.1f", primaryCredits(for: snap).credits)
        }
    }
}

enum BudgetNotifier {
    private static let notifyKey = "QoderBarLastBudgetNotifyDay"

    static func check(snapshot: MetricsSnapshot, settings: AppSettings) {
        guard settings.notificationsEnabled else { return }
        let budget = settings.dailyCreditBudget
        let used = AppModel.primaryCredits(for: snapshot).credits
        guard budget > 0, used >= budget else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayKey = df.string(from: Date())
        guard UserDefaults.standard.string(forKey: notifyKey) != todayKey else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }

        BudgetNotificationCenter.shared.send(
            title: "QoderBar 预算提醒",
            body: String(format: "今日已消耗 %.1f 积分，超过预算 %.1f 积分", used, budget)
        )
        UserDefaults.standard.set(todayKey, forKey: notifyKey)
    }
}
