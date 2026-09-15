import Foundation
import AppKit

enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case liveTPS
    case todayCredits
    case todayTokens
    case todayCost
    case iconOnly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveTPS: return "实时 TPS（空闲时显示今日积分）"
        case .todayCredits: return "今日积分"
        case .todayTokens: return "今日 Tokens（估算）"
        case .todayCost: return "今日费用估算"
        case .iconOnly: return "仅图标"
        }
    }
}

enum QuotaSite: String, Codable, CaseIterable, Identifiable {
    case cn
    case intl
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cn: return "Qoder 中国站（qoder.com.cn）"
        case .intl: return "Qoder 国际站（qoder.com）"
        }
    }

    var usageURL: URL {
        switch self {
        case .cn: return URL(string: "https://qoder.com.cn/api/v2/me/usages/big_model_credits")!
        case .intl: return URL(string: "https://qoder.com/api/v2/me/usages/big_model_credits")!
        }
    }

    var dashboardURL: URL {
        switch self {
        case .cn: return URL(string: "https://qoder.com.cn/account/usage")!
        case .intl: return URL(string: "https://qoder.com/account/usage")!
        }
    }

    var webOrigin: String {
        switch self {
        case .cn: return "https://qoder.com.cn"
        case .intl: return "https://qoder.com"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var menuBarMode: MenuBarMode = .liveTPS
    /// 每日积分预算，0 表示不启用
    var dailyCreditBudget: Double = 0
    /// 月度积分额度/预算，0 表示不启用（用于额度卡与 Pace 预测）
    var monthlyCreditBudget: Double = 0
    /// Qoder 官方额度接口的 Cookie 头；为空表示不启用官方额度
    var quotaCookie: String = ""
    /// 官方额度查询站点
    var quotaSite: QuotaSite = .cn
    var notificationsEnabled = true
    /// 隐藏近 120 天无任何用量的用户/产品
    var hideInactiveUsers = false
    /// 官方参考价：¥40 / 1000 credits
    static let officialCreditPrice: Double = 0.04
    /// 每积分单价，用于费用估算；0 表示不换算
    var creditPrice: Double = AppSettings.officialCreditPrice
    var currencySymbol: String = "¥"
    var launchAtLogin = false

    init() {}

    /// 容错解码：新版本新增字段时旧配置不会整体失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuBarMode = try c.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .liveTPS
        dailyCreditBudget = try c.decodeIfPresent(Double.self, forKey: .dailyCreditBudget) ?? 0
        monthlyCreditBudget = try c.decodeIfPresent(Double.self, forKey: .monthlyCreditBudget) ?? 0
        quotaCookie = try c.decodeIfPresent(String.self, forKey: .quotaCookie) ?? ""
        quotaSite = try c.decodeIfPresent(QuotaSite.self, forKey: .quotaSite) ?? .cn
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        hideInactiveUsers = try c.decodeIfPresent(Bool.self, forKey: .hideInactiveUsers) ?? false
        creditPrice = try c.decodeIfPresent(Double.self, forKey: .creditPrice) ?? AppSettings.officialCreditPrice
        currencySymbol = try c.decodeIfPresent(String.self, forKey: .currencySymbol) ?? "¥"
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    static let key = "QoderBarSettings"

    static func load() -> AppSettings {
        var s: AppSettings
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            s = decoded
        } else {
            s = AppSettings()
        }
        // 一次性迁移：旧版本默认 0 表示未配置，现改为内置官方参考价
        let migratedKey = "QoderBarOfficialPriceMigrated"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            if s.creditPrice <= 0 {
                s.creditPrice = officialCreditPrice
                s.save()
            }
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func cost(credits: Double) -> Double {
        creditPrice > 0 ? credits * creditPrice : 0
    }

    func money(_ v: Double) -> String {
        if creditPrice <= 0 { return "" }
        return "\(currencySymbol)\(String(format: v < 10 ? "%.2f" : "%.1f", v))"
    }
}

enum LoginItem {
    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: Paths.launchAgentURL.path)
    }

    static func executablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            let bin = executablePath()
            let plist: [String: Any] = [
                "Label": Paths.launchAgentLabel,
                "ProgramArguments": [bin],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "StandardOutPath": Paths.appSupport.appendingPathComponent("launch.log").path,
                "StandardErrorPath": Paths.appSupport.appendingPathComponent("launch.err.log").path
            ]
            do {
                try FileManager.default.createDirectory(
                    at: Paths.launchAgentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: Paths.launchAgentURL)
                let uid = getuid()
                _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Paths.launchAgentLabel)"])
                let rc = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", Paths.launchAgentURL.path])
                if rc != 0 {
                    _ = run("/bin/launchctl", ["load", "-w", Paths.launchAgentURL.path])
                }
                return true
            } catch {
                return false
            }
        } else {
            let uid = getuid()
            _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Paths.launchAgentLabel)"])
            try? FileManager.default.removeItem(at: Paths.launchAgentURL)
            return true
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

enum SingleInstance {
    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let path = Paths.lockURL.path
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return false
        }
        return true
    }
}
