import Foundation

/// WorkBuddy（腾讯）会话 JSONL 扫描器。
/// 与 Qoder 不同，记录按类型分行（message / function_call / reasoning / function_call_result 等），
/// 每次真实的模型 API 调用会在记录顶层 providerData.rawUsage 中给出服务端真实用量：
/// prompt/completion tokens、prompt_cache_hit/miss_tokens、credit（积分）。
final class WorkBuddyScanner {
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

        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            return FileScanOutput(events: [], endOffset: offset, lastTs: prevTs, size: size, mtime: mtime)
        }
        let parseEnd = chunk.index(after: lastNewline)
        let parseData = chunk[chunk.startIndex..<parseEnd]
        let newOffset = offset + parseData.count

        var events: [UsageEvent] = []
        // 记录各类型行的时间戳序列：生成时长 ≈ 本调用时间 - 上一条记录时间（跳过同一调用内的近似同步行）
        var recent: [Date] = []
        if let prevTs { recent.append(prevTs) }

        var lineStart = parseData.startIndex
        while lineStart < parseData.endIndex {
            guard let nl = parseData[lineStart...].firstIndex(of: 0x0A) else { break }
            let lineData = parseData[lineStart..<nl]
            lineStart = parseData.index(after: nl)
            if lineData.isEmpty { continue }

            guard let dict = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            let ts = JSONLScanner.parseDate(dict["timestamp"])

            if let ts,
               let providerData = dict["providerData"] as? [String: Any],
               let rawUsage = providerData["rawUsage"] as? [String: Any], !rawUsage.isEmpty,
               let recordId = dict["id"] as? String,
               let sessionId = dict["sessionId"] as? String {
                // requestModelName 可能是"快速/Auto"等路由别名，优先用 providerData.model 的精确模型 ID
                let model = (providerData["model"] as? String)
                    ?? (providerData["requestModelName"] as? String) ?? "unknown"
                events.append(UsageEvent(
                    id: "\(sessionId):\(recordId)",
                    sessionId: sessionId,
                    project: dict["cwd"] as? String ?? "",
                    model: model,
                    ts: ts,
                    inputTokens: Self.intVal(rawUsage["prompt_tokens"]),
                    outputTokens: Self.intVal(rawUsage["completion_tokens"]),
                    cacheRead: Self.intVal(rawUsage["prompt_cache_hit_tokens"]),
                    cacheWrite: Self.intVal(rawUsage["prompt_cache_miss_tokens"]),
                    credits: Self.doubleVal(rawUsage["credit"]),
                    estOutputTokens: 0,
                    duration: JSONLScanner.durationFrom(recent: recent, to: ts),
                    product: product,
                    userKey: nil,
                    version: "",
                    ctxRatio: nil
                ))
            }

            if let ts {
                recent.append(ts)
                if recent.count > 200 { recent.removeFirst(recent.count - 200) }
            }
        }

        return FileScanOutput(events: events, endOffset: newOffset, lastTs: recent.last ?? prevTs, size: size, mtime: mtime)
    }

    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func doubleVal(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }
}
