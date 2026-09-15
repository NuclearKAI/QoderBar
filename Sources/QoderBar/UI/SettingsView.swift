import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rescanning = false
    @State private var notificationStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QoderBar 设置")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("菜单栏") {
                        Picker("显示内容", selection: $model.settings.menuBarMode) {
                            ForEach(MenuBarMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingsSection("预算提醒") {
                        HStack {
                            Text("每日积分预算")
                            Spacer()
                            TextField("0", value: $model.settings.dailyCreditBudget, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            Text("积分")
                                .foregroundStyle(.secondary)
                        }
                        Toggle("超预算时发送系统通知", isOn: $model.settings.notificationsEnabled)
                            .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                                if enabled {
                                    BudgetNotificationCenter.shared.requestAuthorizationIfNeeded { granted in
                                        notificationStatus = granted ? "通知权限已开启" : "未获得通知权限（需在系统设置中允许）"
                                    }
                                }
                            }
                        if let s = notificationStatus {
                            Text(s)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    settingsSection("费用估算") {
                        HStack {
                            Text("每积分单价")
                            Spacer()
                            TextField("0.04", value: $model.settings.creditPrice, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            TextField("¥", text: $model.settings.currencySymbol)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 40)
                                .multilineTextAlignment(.center)
                        }
                        Text("内置官方参考价 ¥40 / 1000 credits（0.04 元/积分），可自行调整；设为 0 则不显示费用。费用仅用于本地估算。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    settingsSection("额度") {
                        HStack {
                            Text("月度积分额度")
                            Spacer()
                            TextField("0", value: $model.settings.monthlyCreditBudget, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            Text("积分")
                                .foregroundStyle(.secondary)
                        }
                        Text("作为官方额度读取失败时的本地回退，同时用于菜单栏进度环与 Pace 预测；0 表示不启用。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        if let quota = model.quotas[model.settings.quotaSite == .cn ? .qoderCN : .qoderINTL] {
                            Text("Qoder 官方额度：已用 \(Fmt.compact(Int(quota.used.rounded()))) / \(Fmt.compact(Int(quota.total.rounded()))) 积分（\(quota.source == .client ? "客户端登录态" : "Cookie")，更新于 \(Fmt.relative(quota.updatedAt))）")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let wb = model.quotas[.workbuddy] {
                            Text("WorkBuddy 官方余额：剩余 \(Fmt.compact(Int(wb.remaining.rounded()))) / \(Fmt.compact(Int(wb.total.rounded()))) 积分（更新于 \(Fmt.relative(wb.updatedAt))）")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let error = model.quotaErrors[model.settings.quotaSite == .cn ? .qoderCN : .qoderINTL] {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        if let error = model.quotaErrors[.workbuddy] {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        Text("官方额度全部自动读取、无需配置：Qoder 用客户端本机登录态（首次会弹一次系统钥匙串授权，选「始终允许」后不再询问），WorkBuddy 用其客户端登录态；每 10 分钟刷新。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        DisclosureGroup("高级：手动 Cookie 覆盖（可选）") {
                            Picker("官方额度站点", selection: $model.settings.quotaSite) {
                                ForEach(QuotaSite.allCases) { s in
                                    Text(s.title).tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                            HStack {
                                Text("Cookie")
                                Spacer()
                                TextField("粘贴浏览器请求中的 Cookie 头", text: $model.settings.quotaCookie)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .font(.system(size: 10))
                            }
                            Text("留空即自动读取；仅当需要读取国际站或自动读取失败时使用。Cookie 只保存在本机。")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 10.5))
                    }

                    settingsSection("通用") {
                        Toggle("登录时自动启动", isOn: Binding(
                            get: { model.settings.launchAtLogin },
                            set: { v in
                                let ok = LoginItem.setEnabled(v)
                                model.settings.launchAtLogin = ok ? v : LoginItem.isEnabled()
                            }
                        ))
                        Toggle("隐藏近 120 天无数据的用户/产品", isOn: $model.settings.hideInactiveUsers)
                    }

                    settingsSection("更新") {
                        HStack {
                            Text("当前版本")
                            Spacer()
                            Text(AppInfo.version)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button("检查更新") {
                                model.checkForUpdates(interactive: true)
                            }
                            .disabled(!UpdateChecker.isConfigured)
                        }
                        if UpdateChecker.isConfigured {
                            Toggle("自动检查更新（每日一次）", isOn: Binding(
                                get: { UpdateChecker.autoCheckEnabled },
                                set: { UpdateChecker.autoCheckEnabled = $0 }))
                        } else {
                            Text("未配置更新源：发布时在 UpdateChecker.defaultRepo 填入 owner/repo。")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        if let status = model.updateStatus {
                            Text(status)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text("更新只访问 GitHub（api.github.com / github.com）：下载后先核对发布页的 sha256，再校验代码签名与包标识，任一不符都会拒绝安装。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    settingsSection("数据") {
                        HStack {
                            Button {
                                rescanning = true
                                model.engine.rescanAll()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    rescanning = false
                                    model.refresh()
                                }
                            } label: {
                                Label(rescanning ? "正在重新扫描…" : "重新扫描全部数据", systemImage: "arrow.clockwise")
                            }
                            .disabled(rescanning)
                            Spacer()
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.appSupport.path)
                            } label: {
                                Label("打开数据目录", systemImage: "folder")
                            }
                        }
                        Text("数据库：\(model.engine.databasePath())")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        if !model.snapshot.sourceIssues.isEmpty {
                            ForEach(model.snapshot.sourceIssues.prefix(3), id: \.self) { i in
                                Text("⚠︎ \(i)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    settingsSection("账户") {
                        let identities = model.engine.store.identities()
                        if identities.isEmpty {
                            Text("尚未识别到登录账户")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(identities) { identity in
                            HStack(spacing: 6) {
                                ProductBadge(product: identity.product)
                                Text(identity.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                if let email = identity.email {
                                    Text(email)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if isCurrent(identity) {
                                    Text("当前登录")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.green.opacity(0.18)))
                                        .foregroundStyle(.green)
                                }
                                Text(Fmt.relative(identity.lastSeen))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("切换账号后，新产生的用量会自动归入新账户；历史记录按登录时间线归属。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    settingsSection("关于") {
                        Text("QoderBar \(AppInfo.version)")
                            .font(.system(size: 11, weight: .medium))
                        Text("本地用量监测：读取本机会话记录（Qoder：~/.qoder-cn、~/.qoder；WorkBuddy：~/.workbuddy、~/.codebuddy），并从客户端本机登录态自动读取官方额度/余额（凭据仅用于本机请求，不落盘、不上传）。WorkBuddy 使用服务端返回的真实 token；Qoder CN 服务端仅返回积分与上下文占比，其 token 量与 TPS 为估算值。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 420, height: 560)
    }

    private func isCurrent(_ identity: IdentityRecord) -> Bool {
        model.engine.currentUser(product: identity.product)?.key == identity.userKey
    }

    @ViewBuilder
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .card(padding: 10)
        }
    }
}
