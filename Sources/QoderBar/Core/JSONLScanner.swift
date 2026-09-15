import Foundation

struct FileScanOutput {
    var events: [UsageEvent]
    var endOffset: Int
    var lastTs: Date?
    var size: Int
    var mtime: Double
}

/// 一条助手消息在 JSONL 中被拆成多行写入（thinking/text/tool_use 各一行、时间戳相同），
/// usage 与 credits 只出现在最后一行，因此需要按 message id 归集所有行的内容块。
private struct PendingMessage {
    var cjk = 0
    var other = 0
    var ts: Date?
    var duration: Double?
    var sessionId = ""
    var project = ""
    var model = "unknown"
    var version = ""
    var usage: [String: Any]?
    var ctxRatio: Double?
}

final class JSONLScanner {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = any as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e9 { return Date(timeIntervalSince1970: v) }
        }
        return nil
    }

    /// 从 startOffset 增量扫描一个会话 JSONL 文件。
    func scanFile(url: URL, product: QoderProduct, startOffset: Int, prevTs: Date?) -> FileScanOutput? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let mtimeDate = attrs[.modificationDate] as? Date
        else { return nil }
        let mtime = mtimeDate.timeIntervalSince1970

        var offset = startOffset
        if offset > size { offset = 0 }

        guard size > offset else {
            return FileScanOutput(events: [], endOffset: offset, lastTs: prevTs, size: size, mtime: mtime)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch { return nil }
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            return FileScanOutput(events: [], endOffset: offset, lastTs: prevTs, size: size, mtime: mtime)
        }

        // 只处理完整的行，保留未写完的尾部
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            return FileScanOutput(events: [], endOffset: offset, lastTs: prevTs, size: size, mtime: mtime)
        }
        let parseEnd = chunk.index(after: lastNewline)
        let parseData = chunk[chunk.startIndex..<parseEnd]
        let newOffset = offset + parseData.count

        var pending: [String: PendingMessage] = [:]
        var order: [String] = []
        // 保留最近的时间戳序列：流式消息会以相同时间戳批量写入多行，
        // 求生成时长时必须找到严格早于当前时间的事件时间
        var recent: [Date] = []
        if let prevTs { recent.append(prevTs) }

        var lineStart = parseData.startIndex
        while lineStart < parseData.endIndex {
            guard let nl = parseData[lineStart...].firstIndex(of: 0x0A) else { break }
            let lineData = parseData[lineStart..<nl]
            lineStart = parseData.index(after: nl)
            if lineData.isEmpty { continue }

            guard let dict = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            let type = dict["type"] as? String ?? ""
            let ts = Self.parseDate(dict["timestamp"])

            if type == "assistant",
               let message = dict["message"] as? [String: Any],
               let messageId = (message["id"] as? String) ?? (dict["uuid"] as? String) {
                var p = pending[messageId] ?? PendingMessage()
                if pending[messageId] == nil { order.append(messageId) }

                Self.accumulateContent(message["content"], &p.cjk, &p.other)
                if let ts, p.ts == nil { p.ts = ts }
                if p.sessionId.isEmpty, let s = dict["sessionId"] as? String { p.sessionId = s }
                if p.project.isEmpty, let c = dict["cwd"] as? String { p.project = c }
                if let m = message["model"] as? String, !m.isEmpty { p.model = m }
                if let v = dict["version"] as? String, !v.isEmpty { p.version = v }
                if let usage = message["usage"] as? [String: Any] {
                    p.usage = usage
                    let ratio = doubleVal(usage["context_usage_ratio"])
                    p.ctxRatio = ratio > 0 ? ratio : nil
                    if let ts {
                        p.ts = ts
                        p.duration = Self.durationFrom(recent: recent, to: ts)
                    }
                }
                pending[messageId] = p
            }

            if let ts {
                recent.append(ts)
                if recent.count > 200 { recent.removeFirst(recent.count - 200) }
            }
        }

        var events: [UsageEvent] = []
        events.reserveCapacity(order.count)
        for messageId in order {
            guard let p = pending[messageId], let usage = p.usage, let ts = p.ts else { continue }
            events.append(UsageEvent(
                id: "\(p.sessionId):\(messageId)",
                sessionId: p.sessionId,
                project: p.project,
                model: p.model,
                ts: ts,
                inputTokens: intVal(usage["input_tokens"]),
                outputTokens: intVal(usage["output_tokens"]),
                cacheRead: intVal(usage["cache_read_input_tokens"]),
                cacheWrite: intVal(usage["cache_creation_input_tokens"]),
                credits: doubleVal(usage["credits"]),
                estOutputTokens: Self.estimateTokens(cjk: p.cjk, other: p.other),
                duration: p.duration,
                product: product,
                userKey: nil,
                version: p.version,
                ctxRatio: p.ctxRatio
            ))
        }

        return FileScanOutput(events: events, endOffset: newOffset, lastTs: recent.last ?? prevTs, size: size, mtime: mtime)
    }

    /// 找到严格早于 ts 的最近事件时间，得到生成时长（秒）。WorkBuddyScanner 同样复用。
    /// 同一次调用内的记录对（如 reasoning 与最终 message）间隔不足 0.2s 无法作为起点，继续向前找。
    static func durationFrom(recent: [Date], to ts: Date) -> Double? {
        for t in recent.reversed() {
            if t < ts {
                let d = ts.timeIntervalSince(t)
                if d >= 0.2 { return d <= 900 ? d : nil }
            }
        }
        return nil
    }

    /// 按内容块字符数估算输出 tokens（CJK 约 0.75 token/字，其他约 4 字符/token）。
    static func estimateTokens(cjk: Int, other: Int) -> Int {
        Int((Double(cjk) * 0.75 + Double(other) / 4.0).rounded())
    }

    /// 累计内容块中的字符数：text / thinking / tool_use 的输入都会被计入。
    static func accumulateContent(_ content: Any?, _ cjk: inout Int, _ other: inout Int) {
        guard let blocks = content as? [[String: Any]] else { return }
        for block in blocks {
            let type = block["type"] as? String ?? ""
            switch type {
            case "text":
                if let s = block["text"] as? String { countScript(s, &cjk, &other) }
            case "thinking":
                if let s = block["thinking"] as? String { countScript(s, &cjk, &other) }
            case "tool_use":
                if let input = block["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let s = String(data: data, encoding: .utf8) {
                    countScript(s, &cjk, &other)
                }
            default:
                break
            }
        }
    }

    private static func countScript(_ s: String, _ cjk: inout Int, _ other: inout Int) {
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x2E80 && scalar.value <= 0x9FFF
                || scalar.value >= 0xF900 && scalar.value <= 0xFAFF
                || scalar.value >= 0xFF00 && scalar.value <= 0xFFEF {
                cjk += 1
            } else {
                other += 1
            }
        }
    }

    private func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private func doubleVal(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }
}
