import Foundation

enum Fmt {
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", v / 1_000_000)
        case 10_000...: return String(format: "%.1fK", v / 1_000)
        case 1_000...: return String(format: "%.2fK", v / 1_000)
        default: return "\(n)"
        }
    }

    static func tps(_ v: Double) -> String {
        if v <= 0 { return "0" }
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func money(_ v: Double) -> String {
        if v <= 0 { return "$0.00" }
        if v < 0.01 { return String(format: "$%.4f", v) }
        if v < 1000 { return String(format: "$%.2f", v) }
        return String(format: "$%.0f", v)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)秒" }
        if t < 3600 { return "\(t / 60)分\(t % 60)秒" }
        return "\(t / 3600)小时\((t % 3600) / 60)分"
    }

    /// 倒计时：距重置/到期还有多久
    static func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        let d = t / 86400
        let h = (t % 86400) / 3600
        let m = (t % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)天\(h)小时" : "\(d)天" }
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分钟" }
        return "\(t)秒"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let d = now.timeIntervalSince(date)
        if d < 5 { return "刚刚" }
        if d < 60 { return "\(Int(d))秒前" }
        if d < 3600 { return "\(Int(d / 60))分钟前" }
        if d < 86400 { return "\(Int(d / 3600))小时前" }
        return "\(Int(d / 86400))天前"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func projectName(_ path: String) -> String {
        if path.isEmpty { return "未知项目" }
        return (path as NSString).lastPathComponent
    }
}
