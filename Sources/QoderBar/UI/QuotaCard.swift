import SwiftUI

/// 额度卡：跟随当前查看的产品。
/// - Qoder CN/INTL：官方额度（客户端登录态或 Cookie），无官方数据时回退本地月度预算
/// - WorkBuddy：官方积分余额（客户端登录态）
/// 含重置倒计时与 Pace 预测。
struct QuotaCard: View {
    @ObservedObject var model: AppModel

    private var product: QoderProduct { AppModel.scopedProduct(for: model.snapshot) }
    private var quota: QuotaSnapshot? { model.quotas[product] }
    private var officialError: String? { model.quotaErrors[product] }

    var body: some View {
        if let quota {
            officialCard(quota)
        } else if product == .qoderCN && model.settings.monthlyCreditBudget > 0 {
            budgetCard
        } else {
            hint
        }
    }

    private func officialCard(_ quota: QuotaSnapshot) -> some View {
        let fraction = quota.total > 0 ? quota.used / quota.total : 0
        let percent = fraction * 100
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(quota.product == .workbuddy ? "积分余额" : "本月额度")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(badgeText(quota))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("更新于 \(Fmt.relative(quota.updatedAt))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                if let url = quota.site?.dashboardURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("打开 Qoder 用量页")
                }
            }

            ShareBar(fraction: fraction, color: barColor(percent))

            HStack(alignment: .firstTextBaseline) {
                Text("已用 \(Fmt.compact(Int(quota.used.rounded()))) / \(Fmt.compact(Int(quota.total.rounded()))) 积分")
                    .font(.system(size: 11.5, weight: .medium))
                Text(String(format: "%.1f%%", percent))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(barColor(percent))
                Spacer()
                if let resetsAt = quota.resetsAt {
                    Text("距重置 \(Fmt.countdown(resetsAt.timeIntervalSinceNow))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("剩余 \(Fmt.compact(Int(quota.remaining.rounded()))) 积分")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let paceLine = paceLine(for: quota) {
                Text(paceLine)
                    .font(.system(size: 10))
                    .foregroundStyle(paceLine.contains("用尽") ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            if let officialError {
                Text(officialError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func badgeText(_ quota: QuotaSnapshot) -> String {
        if quota.product == .workbuddy { return "WorkBuddy 官方" }
        let siteName = quota.site == .intl ? "国际站" : "中国站"
        return "Qoder 官方 · \(siteName)"
    }

    /// 本地月度预算（仅 Qoder CN，官方数据不可用时的回退）
    private var budgetCard: some View {
        let used = model.snapshot.monthByProduct[.qoderCN]?.credits ?? 0
        let total = model.settings.monthlyCreditBudget
        let percent = total > 0 ? used / total * 100 : 0
        let reset = nextMonthStart
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("本月预算")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("本地月度预算 · Qoder CN")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ShareBar(fraction: total > 0 ? used / total : 0, color: barColor(percent))
            HStack(alignment: .firstTextBaseline) {
                Text("已用 \(Fmt.compact(Int(used.rounded()))) / \(Fmt.compact(Int(total.rounded()))) 积分")
                    .font(.system(size: 11.5, weight: .medium))
                Text(String(format: "%.1f%%", percent))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(barColor(percent))
                Spacer()
                Text("距重置 \(Fmt.countdown(reset.timeIntervalSinceNow))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let line = budgetPaceLine(used: used, total: total) {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(line.contains("用尽") ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            if let officialError {
                Text(officialError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(product == .workbuddy
                     ? "正在自动读取 WorkBuddy 官方积分余额…"
                     : "正在自动读取 Qoder 官方额度…（首次需在系统弹窗中允许访问钥匙串）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let officialError {
                    Text(officialError)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("去设置") {
                model.showSettings = true
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var nextMonthStart: Date {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return cal.date(byAdding: .month, value: 1, to: start) ?? start
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 100 { return .red }
        if percent >= 80 { return .orange }
        return Theme.creditsColor
    }

    /// Pace 预测：判断能否撑到重置（官方模式按"计费周期已过天数"分摊官方用量，最准）
    private func paceLine(for quota: QuotaSnapshot) -> String? {
        let daily: Double
        let label: String
        if let reset = quota.resetsAt,
           let start = Calendar.current.date(byAdding: .month, value: -1, to: reset),
           quota.used > 0 {
            // 周期刚开始时用不足 1 天，摊出来会失真，下限取 1 天
            let elapsedDays = max(1.0, Date().timeIntervalSince(start) / 86_400)
            daily = quota.used / elapsedDays
            label = "周期日均"
        } else {
            daily = model.snapshot.weekDailyByProduct[quota.product] ?? 0
            label = "近 7 天日均"
        }
        guard quota.total > 0, daily > 0.05 else { return nil }
        let daysToExhaust = max(0, quota.total - quota.used) / daily
        if let resetAt = quota.resetsAt {
            let remainDays = max(0, resetAt.timeIntervalSinceNow / 86_400)
            if daysToExhaust < remainDays {
                return String(format: "%@ %.1f 积分 · 约 %.1f 天后用尽，撑不到重置", label, daily, daysToExhaust)
            }
            let projected = quota.used + daily * remainDays
            return String(format: "%@ %.1f 积分 · 预计重置时 %@（额度 %@）",
                          label, daily, Fmt.compact(Int(projected.rounded())), Fmt.compact(Int(quota.total.rounded())))
        }
        return String(format: "%@ %.1f 积分 · 约 %.1f 天后用尽", label, daily, daysToExhaust)
    }

    private func budgetPaceLine(used: Double, total: Double) -> String? {
        let daily = model.snapshot.weekDailyByProduct[.qoderCN] ?? 0
        guard total > 0, daily > 0.05 else { return nil }
        let remainDays = max(0, nextMonthStart.timeIntervalSinceNow / 86_400)
        let daysToExhaust = max(0, total - used) / daily
        if daysToExhaust < remainDays {
            return String(format: "近 7 天日均 %.1f 积分 · 约 %.1f 天后用尽，撑不到重置", daily, daysToExhaust)
        }
        let projected = used + daily * remainDays
        return String(format: "近 7 天日均 %.1f 积分 · 预计重置时 %@（额度 %@）",
                      daily, Fmt.compact(Int(projected.rounded())), Fmt.compact(Int(total.rounded())))
    }
}
