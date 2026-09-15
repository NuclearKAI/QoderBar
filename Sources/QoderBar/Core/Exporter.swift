import Foundation
import AppKit

enum Exporter {
    static func csv(events: [UsageEvent], users: [IdentityRecord], settings: AppSettings) -> String {
        let userName: (String?) -> String = { key in
            guard let key else { return "未归属" }
            return users.first { $0.userKey == key }?.displayName ?? key
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = []
        lines.append("时间,用户,产品,会话,项目,模型,输入 tokens,输出 tokens(实际),输出 tokens(估算),缓存读,缓存写,积分,时长(秒),TPS,RawID")
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            let fields: [String] = [
                df.string(from: e.ts),
                userName(e.userKey),
                e.product.displayName,
                e.sessionId,
                e.project,
                e.model,
                String(e.inputTokens),
                String(e.outputTokens),
                String(e.effectiveOutputTokens),
                String(e.cacheRead),
                String(e.cacheWrite),
                String(format: "%.6f", e.credits),
                e.duration.map { String(format: "%.2f", $0) } ?? "",
                e.callTPS.map { String(format: "%.2f", $0) } ?? "",
                e.id
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func saveWithPanel(content: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
