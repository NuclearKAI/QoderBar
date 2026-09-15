import SwiftUI
import Combine

enum Theme {
    static let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint, .red, .cyan]

    static func userColor(_ index: Int) -> Color {
        palette[abs(index) % palette.count]
    }

    static let panelWidth: CGFloat = 412
    static let creditsColor = Color(red: 0.98, green: 0.62, blue: 0.15)
    static let tpsColor = Color(red: 0.35, green: 0.55, blue: 0.98)
    static let positive = Color.green
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
    }
}

extension View {
    func card(padding: CGFloat = 10) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

struct StatCard: View {
    var title: String
    var value: String
    var accent: Color = .primary
    var caption: String?
    var caption2: String?
    var mono = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: mono ? .rounded : .default))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let caption2 {
                Text(caption2)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// 按产品分列的统计卡：单产品时与原 StatCard 一致，多产品时并列展示各自数值
struct SplitStatCard: View {
    struct Item: Identifiable {
        var product: QoderProduct
        var value: String
        var id: QoderProduct { product }
    }

    var title: String
    var items: [Item]
    var accent: Color = .primary
    var caption: String?
    var caption2: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if items.count <= 1 {
                Text(items.first?.value ?? "0")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    ForEach(items) { item in
                        HStack(spacing: 4) {
                            ProductBadge(product: item.product)
                            Text(item.value)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let caption2 {
                Text(caption2)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProductBadge: View {
    var product: QoderProduct
    var body: some View {
        Text(product.badge)
            .font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badgeColor.opacity(0.18))
            )
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch product {
        case .qoderCN: return .red
        case .qoderINTL: return .blue
        case .workbuddy: return .teal
        }
    }
}

struct ShareBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.opacity(0.75))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}
