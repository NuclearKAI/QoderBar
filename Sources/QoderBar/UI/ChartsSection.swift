import SwiftUI
import Charts

struct RangeSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.range) {
                ForEach(TimeRange.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.range == .heatmap {
                HeatmapView(days: model.snapshot.days,
                            hasRealTokens: model.snapshot.rangeHasRealTokens,
                            byProduct: model.snapshot.heatmapByProduct)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader(
                        title: "积分消耗（分时）",
                        trailing: creditsTrailing
                    )
                    CreditsChart(buckets: model.snapshot.buckets, range: model.range)
                }
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeader(
                        title: model.snapshot.rangeHasRealTokens ? "分时 TPS" : "分时 TPS（估算）",
                        trailing: "区间峰值 \(Fmt.tps(model.snapshot.rangePeakTPS)) · 平均 \(Fmt.tps(model.snapshot.rangeAvgTPS))"
                    )
                    TPSChart(buckets: model.snapshot.buckets, range: model.range, peak: model.snapshot.rangePeakTPS)
                }
            }
        }
    }

    /// 区间合计按产品分列："合计 CN 12.3 · WB 5.6 · 峰值 4.1/分"
    private var creditsTrailing: String {
        let split = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = model.snapshot.rangeByProduct[p], t.credits > 0.05 else { return nil }
            return String(format: "%@ %.1f", p.badge, t.credits)
        }.joined(separator: " · ")
        let head = split.isEmpty ? "合计 0" : "合计 " + split
        return head + String(format: " · 峰值 %.1f/分", model.snapshot.rangePeakCreditRate)
    }
}

private func barUnit(for range: TimeRange) -> Calendar.Component {
    switch range {
    case .live: return .minute
    case .day: return .hour
    case .week, .month, .heatmap: return .day
    }
}

private func axisFormat(for range: TimeRange) -> Date.FormatStyle {
    switch range {
    case .live: return .dateTime.hour().minute()
    case .day: return .dateTime.hour()
    case .week: return .dateTime.month(.defaultDigits).day()
    case .month, .heatmap: return .dateTime.month(.defaultDigits).day()
    }
}

struct CreditsChart: View {
    var buckets: [Bucket]
    var range: TimeRange

    private var products: [QoderProduct] {
        QoderProduct.allCases.filter { p in
            buckets.contains { ($0.creditsByProduct[p] ?? 0) > 0 }
        }
    }

    private func color(for product: QoderProduct) -> Color {
        switch product {
        case .qoderCN: return .red
        case .qoderINTL: return .blue
        case .workbuddy: return .teal
        }
    }

    var body: some View {
        ZStack {
            Chart {
                ForEach(buckets) { b in
                    ForEach(products, id: \.self) { p in
                        BarMark(
                            x: .value("时间", b.start, unit: barUnit(for: range)),
                            y: .value("积分", b.creditsByProduct[p] ?? 0)
                        )
                        .foregroundStyle(by: .value("产品", p.badge))
                        .cornerRadius(1.5)
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: products.map(\.badge),
                range: products.map { color(for: $0) })
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: axisFormat(for: range))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: v >= 10 ? "%.0f" : "%.2f", v))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if buckets.allSatisfy({ $0.credits == 0 }) {
                Text("该时间范围内暂无数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 74)
    }
}

struct TPSChart: View {
    var buckets: [Bucket]
    var range: TimeRange
    var peak: Double

    var body: some View {
        ZStack {
            Chart {
                ForEach(buckets) { b in
                    AreaMark(
                        x: .value("时间", b.start),
                        y: .value("TPS", b.tps)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.tpsColor.opacity(0.30), Theme.tpsColor.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("时间", b.start),
                        y: .value("TPS", b.tps)
                    )
                    .foregroundStyle(Theme.tpsColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
                }
                if peak > 0 {
                    RuleMark(y: .value("峰值", peak))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.tpsColor.opacity(0.45))
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel(format: axisFormat(for: range))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.tps(v))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if buckets.allSatisfy({ $0.tps == 0 }) {
                Text("该时间范围内暂无数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 74)
    }
}

struct HeatmapView: View {
    var days: [DayStat]
    var hasRealTokens: Bool
    var byProduct: [QoderProduct: ProductTotals]

    private let cell: CGFloat = 13
    private let spacing: CGFloat = 3

    var body: some View {
        let weeks = chunkWeeks()
        let maxCredits = days.map(\.credits).max() ?? 0
        let totalCredits = days.reduce(0) { $0 + $1.credits }
        let totalTokens = days.reduce(0) { $0 + $1.totals.output }

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: spacing) {
                ForEach(weeks.indices, id: \.self) { wi in
                    VStack(spacing: spacing) {
                        ForEach(weeks[wi].indices, id: \.self) { di in
                            if let day = weeks[wi][di] {
                                cellView(day: day, maxCredits: maxCredits)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text("\(Fmt.shortDate(days.first?.day)) 起")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("少")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(intensityColor(0.15 + Double(i) / 4 * 0.85))
                        .frame(width: 9, height: 9)
                }
                Text("多")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text(heatmapTotalLine(totalCredits: totalCredits, totalTokens: totalTokens))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// 合计按产品分列，不跨产品相加
    private func heatmapTotalLine(totalCredits: Double, totalTokens: Int) -> String {
        let split = QoderProduct.allCases.compactMap { p -> String? in
            guard let t = byProduct[p], t.credits > 0.05 else { return nil }
            return String(format: "%@ %.1f", p.badge, t.credits)
        }.joined(separator: " · ")
        let creditsText = split.isEmpty ? String(format: "%.1f 积分", totalCredits) : "\(split) 积分"
        return "近 120 天合计 \(creditsText) · 输出 \(Fmt.compact(totalTokens)) tokens\(hasRealTokens ? "" : "（估算）")"
    }

    private func cellView(day: DayStat, maxCredits: Double) -> some View {
        let ratio = maxCredits > 0 ? day.credits / maxCredits : 0
        let intensity = ratio > 0 ? (0.15 + sqrt(ratio) * 0.85) : 0
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(day.credits > 0 ? intensityColor(intensity) : Color.primary.opacity(0.05))
            .frame(width: cell, height: cell)
            .help("\(Fmt.shortDate(day.day)) · \(String(format: "%.1f", day.credits)) 积分 · 输出 \(Fmt.compact(day.totals.output)) tokens · \(day.calls) 次调用")
    }

    private func intensityColor(_ intensity: Double) -> Color {
        Theme.creditsColor.opacity(min(1, intensity))
    }

    /// 把逐日数据按自然周切列，周日/周一起始由系统日历决定。
    private func chunkWeeks() -> [[DayStat?]] {
        guard !days.isEmpty else { return [] }
        let cal = Calendar.current
        let firstWeekday = cal.firstWeekday
        var result: [[DayStat?]] = []
        var current: [DayStat?] = []

        if let first = days.first {
            let weekday = cal.component(.weekday, from: first.day)
            let pad = (weekday - firstWeekday + 7) % 7
            for _ in 0..<pad { current.append(nil) }
        }
        for day in days {
            current.append(day)
            if current.count == 7 {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            while current.count < 7 { current.append(nil) }
            result.append(current)
        }
        return result
    }
}
