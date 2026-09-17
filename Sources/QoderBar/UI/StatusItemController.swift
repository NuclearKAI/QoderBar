import AppKit
import SwiftUI
import Combine

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escMonitor: Any?

    init(model: AppModel, openPanelOnLaunch: Bool = false) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "QoderBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let host = NSHostingController(rootView: DashboardView(model: model))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: Theme.panelWidth, height: 648)
        // .transient 在应用未激活时点开会被系统当成"外部点击"立即关闭，
        // 因此改为手动管理：全局鼠标监听负责点击他处关闭，ESC 关闭。
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        model.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.updateTitle(title)
            }
            .store(in: &cancellables)

        model.$meter
            .receive(on: RunLoop.main)
            .sink { [weak self] meter in
                self?.updateMeter(meter)
            }
            .store(in: &cancellables)

        if openPanelOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.showPopover()
            }
        }
    }

    private var lastTitle: String?

    private func updateTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        if title == lastTitle { return }
        lastTitle = title
        let display = title.isEmpty ? "" : " " + title
        button.attributedTitle = NSAttributedString(
            string: display,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                .baselineOffset: -0.5
            ]
        )
    }

    private var lastMeter: MenuBarMeter?

    /// 图标即用量表：有额度/预算时绘制进度环（正常单色、接近橙色、超限红色）
    private func updateMeter(_ meter: MenuBarMeter?) {
        guard let button = statusItem.button else { return }
        if meter == lastMeter { return }
        lastMeter = meter
        if let meter {
            let image = Self.meterImage(fraction: meter.fraction, level: meter.level)
            button.image = image
            button.image?.isTemplate = (meter.level == .normal)
        } else {
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "QoderBar")
            button.image?.isTemplate = true
        }
    }

    private static func meterImage(fraction: Double, level: MenuBarMeter.Level) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let lineWidth: CGFloat = 2.4
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 9 - lineWidth / 2 - 0.8

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth

            switch level {
            case .normal:
                // 模板图：菜单栏按系统主题着色，轨道用半透明显得更轻
                NSColor.black.withAlphaComponent(0.25).setStroke()
                track.stroke()
                if fraction > 0.001 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                    arc.lineWidth = lineWidth
                    arc.lineCapStyle = .round
                    NSColor.black.setStroke()
                    arc.stroke()
                }
            case .warn, .over:
                NSColor.tertiaryLabelColor.setStroke()
                track.stroke()
                let color: NSColor = level == .over ? .systemRed : .systemOrange
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.02, fraction), clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // macOS 14 起为协作式激活：旧的 activate(ignoringOtherApps:) 常被系统忽略，
        // 应用不成为前台时面板内的菜单等控件交互不可靠
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKeyAndOrderFront(nil)
        }
        installMonitors()
        model.panelDidOpen()
        // 兜底：激活若被系统暂缓（协作式激活），用户首次点击后再补一次，
        // 否则处于非激活状态时面板里的控件可能吞掉点击
        if !NSApp.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self?.popover.isShown == true, !NSApp.isActive else { return }
                NSApp.activate()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeMonitors()
        model.panelDidClose()
    }

    /// 面板被系统/其它路径关闭时同步状态，避免 panelVisible 卡住导致界面"不刷新"
    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        model.panelDidClose()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.popover.isShown == true else { return event }
            self?.closePopover()
            return nil
        }
    }

    private func removeMonitors() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(contextOpen), keyEquivalent: "").target = self
        let site = model.settings.quotaSite
        let siteName = site == .cn ? "中国站" : "国际站"
        let usageItem = menu.addItem(
            withTitle: "打开 Qoder 用量页（\(siteName)）",
            action: #selector(contextOpenUsage), keyEquivalent: "")
        usageItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 QoderBar", action: #selector(contextQuit), keyEquivalent: "q").target = self
        // 不把菜单挂到 statusItem.menu 上（挂上后左键会变成弹菜单且可能残留状态），
        // 直接在按钮下方弹出菜单
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
    }

    @objc private func contextOpen() {
        showPopover()
    }

    @objc private func contextOpenUsage() {
        NSWorkspace.shared.open(model.settings.quotaSite.dashboardURL)
    }

    @objc private func contextQuit() {
        NSApp.terminate(nil)
    }
}
