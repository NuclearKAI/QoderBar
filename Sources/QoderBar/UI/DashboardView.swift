import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider().opacity(0.4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    QuotaCard(model: model)
                    statGrid
                    RangeSection(model: model)
                    if !model.snapshot.sourceIssues.isEmpty {
                        IssuesRow(issues: model.snapshot.sourceIssues)
                    }
                    ModelsSection(snapshot: model.snapshot)
                    ProjectsSection(snapshot: model.snapshot)
                    SessionsSection(model: model)
                }
                .padding(12)
            }
            Divider().opacity(0.4)
            FooterView(model: model)
        }
        .frame(width: Theme.panelWidth)
        .frame(height: 648)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
    }

    private var statGrid: some View {
        let snap = model.snapshot
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            SplitStatCard(
                title: "今日积分",
                items: splitItems(snap.todayByProduct) { String(format: "%.1f", $0.credits) },
                accent: Theme.creditsColor,
                caption: compactSplit(snap.monthByProduct) { String(format: "%.1f", $0.credits) }
                    .map { "本月 \($0) 积分" },
                caption2: moneySplitLine(snap.monthByProduct, prefix: "≈ ")
            )
            StatCard(
                title: snap.hasRealTokens ? "今日输出 Tokens" : "今日输出 Tokens（估算）",
                value: Fmt.compact(snap.today.output),
                caption: "\(snap.todayCalls) 次调用 · \(snap.todaySessions) 个会话",
                caption2: snap.hasRealTokens ? nil : "按回复内容长度折算"
            )
            StatCard(
                title: "今日输入 Tokens（上下文）",
                value: Fmt.compact(snap.today.input),
                caption: "命中缓存 \(Fmt.compact(snap.today.cacheRead)) · 新建 \(Fmt.compact(snap.today.cacheWrite))",
                caption2: "每次调用重发全量上下文，按占比标定"
            )
            StatCard(
                title: snap.liveHasRealTokens ? "实时 TPS" : "实时 TPS（估算）",
                value: Fmt.tps(snap.liveTPS),
                accent: snap.isGenerating ? Theme.positive : .primary,
                caption: snap.isGenerating ? "生成中…" : (snap.liveTPS > 0 ? "近 60 秒活跃" : "空闲"),
                caption2: snap.liveOutputTokens > 0 ? "近 60s 输出 \(Fmt.compact(snap.liveOutputTokens))" : nil
            )
            StatCard(
                title: "今日峰值 / 平均 TPS",
                value: Fmt.tps(snap.todayPeakTPS),
                accent: Theme.tpsColor,
                caption: "平均 \(Fmt.tps(snap.todayAvgTPS)) · 单次最高 \(Fmt.tps(snap.todayMaxCallTPS))",
                caption2: snap.todayPeakAt.map { "峰值时刻 \(Fmt.clock($0))" }
            )
            SplitStatCard(
                title: model.settings.creditPrice > 0 ? "近 30 天费用" : "近 30 天积分",
                items: splitItems(snap.last30ByProduct) { t in
                    model.settings.creditPrice > 0
                        ? model.settings.money(t.cost)
                        : String(format: "%.1f", t.credits)
                },
                accent: Theme.creditsColor,
                caption: compactSplit(snap.last30ByProduct) { "\(Fmt.compact($0.tokens)) tok" }
                    .map { "输出 \($0)" },
                caption2: moneySplitLine(snap.monthByProduct, prefix: "本月 ")
            )
        }
    }

    /// 每产品一行（多产品并列展示，不跨产品相加）
    private func splitItems(_ dict: [QoderProduct: ProductTotals], _ format: (ProductTotals) -> String) -> [SplitStatCard.Item] {
        QoderProduct.allCases.compactMap { p in
            guard let t = dict[p], t.calls > 0 else { return nil }
            return SplitStatCard.Item(product: p, value: format(t))
        }
    }

    /// 紧凑分产品文案："CN 177.3 · WB 160.0"
    private func compactSplit(_ dict: [QoderProduct: ProductTotals], _ format: (ProductTotals) -> String) -> String? {
        let parts = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = dict[p], t.calls > 0 else { return nil }
            return "\(p.badge) \(format(t))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 分产品费用文案："CN ¥7.1 · WB ¥6.4"
    private func moneySplitLine(_ dict: [QoderProduct: ProductTotals], prefix: String) -> String? {
        guard model.settings.creditPrice > 0 else { return nil }
        let parts = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = dict[p], t.calls > 0, t.cost > 0 else { return nil }
            return "\(p.badge) \(model.settings.money(t.cost))"
        }
        return parts.isEmpty ? nil : prefix + parts.joined(separator: " · ")
    }
}

struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    model.selectUser(nil)
                } label: {
                    Label("全部用户", systemImage: "person.2.fill")
                }
                Divider()
                ForEach(model.snapshot.users) { u in
                    Button {
                        model.selectUser(u.userKey)
                    } label: {
                        Text("\(u.name)（\(u.product.displayName)）— 今日 \(String(format: "%.1f", u.todayCredits)) 积分")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(selectedColor)
                        .frame(width: 8, height: 8)
                    Text(selectedName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ForEach(selectedProducts, id: \.self) { p in
                ProductBadge(product: p)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(model.snapshot.isGenerating ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(model.snapshot.isGenerating ? "生成中" : "空闲")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var selectedName: String {
        if let key = model.selectedUserKey,
           let u = model.snapshot.users.first(where: { $0.userKey == key }) {
            return u.name
        }
        return "全部用户"
    }

    private var selectedColor: Color {
        if let key = model.selectedUserKey,
           let u = model.snapshot.users.first(where: { $0.userKey == key }) {
            return Theme.userColor(u.colorIndex)
        }
        return .accentColor
    }

    private var selectedProducts: [QoderProduct] {
        if let key = model.selectedUserKey,
           let u = model.snapshot.users.first(where: { $0.userKey == key }) {
            return [u.product]
        }
        return QoderProduct.allCases.filter { p in
            model.snapshot.users.contains { $0.product == p }
        }
    }
}

struct IssuesRow: View {
    var issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(issues.prefix(3), id: \.self) { issue in
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(issue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .card()
    }
}

struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("更新于 \(Fmt.clock(model.snapshot.generatedAt)) · \(model.snapshot.eventCount) 条记录")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                export()
            } label: {
                Label("导出 CSV", systemImage: "square.and.arrow.up")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func export() {
        let events = model.engine.exportEvents(userKey: model.selectedUserKey)
        let identities = model.engine.store.identities()
        let csv = Exporter.csv(events: events, users: identities, settings: model.settings)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        Exporter.saveWithPanel(content: csv, suggestedName: "QoderBar-\(df.string(from: Date())).csv")
    }
}
