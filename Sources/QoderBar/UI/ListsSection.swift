import SwiftUI

struct ModelsSection: View {
    var snapshot: MetricsSnapshot

    var body: some View {
        if !snapshot.models.isEmpty {
            let maxCredits = snapshot.models.map(\.credits).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "模型分布（当前区间）", trailing: "\(snapshot.models.count) 个模型")
                VStack(spacing: 6) {
                    ForEach(snapshot.models.prefix(5)) { m in
                        VStack(spacing: 3) {
                            HStack {
                                Text(m.model)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(m.calls) 次")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "%.1f 积分", m.credits))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.creditsColor)
                                    .monospacedDigit()
                                Text("均 \(Fmt.tps(m.avgTPS)) t/s")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 74, alignment: .trailing)
                            }
                            ShareBar(fraction: maxCredits > 0 ? m.credits / maxCredits : 0, color: Theme.creditsColor)
                        }
                    }
                }
                .card()
            }
        }
    }
}

struct ProjectsSection: View {
    var snapshot: MetricsSnapshot

    var body: some View {
        if !snapshot.projects.isEmpty {
            let maxCredits = snapshot.projects.map(\.credits).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "项目（本月）", trailing: "\(snapshot.projects.count) 个项目")
                VStack(spacing: 6) {
                    ForEach(snapshot.projects.prefix(5)) { p in
                        VStack(spacing: 3) {
                            HStack {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(p.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .help(p.path)
                                Spacer()
                                Text("\(p.sessions) 会话 · \(p.calls) 次")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "%.1f 积分", p.credits))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.creditsColor)
                                    .monospacedDigit()
                                    .frame(width: 66, alignment: .trailing)
                            }
                            ShareBar(fraction: maxCredits > 0 ? p.credits / maxCredits : 0, color: .accentColor)
                        }
                    }
                }
                .card()
            }
        }
    }
}

struct SessionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sessions = model.snapshot.sessions
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "会话（近 7 天）", trailing: "\(sessions.count) 个")
                VStack(spacing: 2) {
                    ForEach(sessions.prefix(12)) { s in
                        SessionRow(session: s, user: userName(for: s.userKey))
                    }
                }
                .card(padding: 6)
            }
        }
    }

    private func userName(for key: String?) -> String? {
        guard let key else { return nil }
        return model.snapshot.users.first { $0.userKey == key }?.name
    }
}

struct SessionRow: View {
    var session: SessionStat
    var user: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    ProductBadge(product: session.product)
                    Spacer()
                    Text("\(session.calls) 次")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1f", session.credits))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.creditsColor)
                        .monospacedDigit()
                    Text(Fmt.relative(session.end))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("时间", "\(Fmt.shortDateTime(session.start)) → \(Fmt.shortDateTime(session.end))")
                    detailRow("输出", "\(Fmt.compact(session.totals.output)) tokens\(session.hasRealTokens ? "" : "（估算）")")
                    detailRow("输入", "\(Fmt.compact(session.totals.input)) tokens（命中 \(Fmt.compact(session.totals.cacheRead)) · 新建 \(Fmt.compact(session.totals.cacheWrite))）")
                    detailRow("积分", String(format: "%.2f", session.credits))
                    detailRow("TPS", "平均 \(Fmt.tps(session.avgTPS)) · 峰值 \(Fmt.tps(session.peakTPS)) t/s")
                    detailRow("模型", session.models.joined(separator: ", "))
                    if let user { detailRow("用户", user) }
                    detailRow("会话", String(session.sessionId.prefix(18)))
                    if !session.project.isEmpty {
                        detailRow("项目", session.project)
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
