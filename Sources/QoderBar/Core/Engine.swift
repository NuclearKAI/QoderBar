import Foundation
import SQLite3

final class Engine {
    static let shared = Engine()

    let store = Store(path: Paths.databaseURL.path)
    private let scanner = JSONLScanner()
    private let workBuddyScanner = WorkBuddyScanner()
    private let queue = DispatchQueue(label: "qoderbar.engine", qos: .utility)

    private var eventsCache: [UsageEvent] = []
    private var lastScanAt: Date?
    private var lastFileActivity: Date?
    private var issues: [String] = []
    private var currentUserKeys: [QoderProduct: String] = [:]
    private var currentUserNames: [QoderProduct: String] = [:]
    private var statCache: [String: (mtime: Double, size: Int)] = [:]
    private var lastIdentityTouch: [QoderProduct: Date] = [:]
    private var timer: DispatchSourceTimer?
    private var watcher: FSWatcher?
    private var watchedPaths: [String] = []
    private var pendingScan: DispatchWorkItem?

    var onUpdate: (() -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.bootstrap()
            self.ensureWatcher()
            self.startTimer()
        }
    }

    func scanSynchronously() {
        queue.sync { bootstrap() }
    }

    /// 立即安排一次扫描（面板打开时调用），带去抖
    func requestScanNow() {
        queue.async { self.scheduleScan(delay: 0.3) }
    }

    /// 最近一次文件活动时间（用于自适应刷新与"生成中"判断）
    func lastActivity() -> Date? {
        queue.sync { lastFileActivity }
    }

    private func bootstrap() {
        // 扫描器逻辑升级时自动重建索引
        let scannerVersion = "9"
        if store.meta("scanner_version") != scannerVersion {
            store.deleteAllData()
            store.setMeta("scanner_version", scannerVersion)
            statCache.removeAll()
            currentUserKeys.removeAll()
        }
        refreshIdentities()
        scanChangedFiles()
        reloadCache()
        lastScanAt = Date()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    private func startTimer() {
        // 安全网：FSEvents 之外每 15s 兜底一次（并补齐可能新增的数据根）
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.ensureWatcher()
            self.scanCycle()
        }
        t.resume()
        timer = t
    }

    private func ensureWatcher() {
        let paths = Paths.sources
            .flatMap { $0.roots.map(\.path) }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard watcher == nil || Set(paths) != Set(watchedPaths) else { return }
        watcher?.stop()
        watchedPaths = paths
        watcher = FSWatcher(paths: paths, queue: queue) { [weak self] in
            self?.scheduleScan(delay: 0.7)
        }
    }

    private func scheduleScan(delay: TimeInterval) {
        pendingScan?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scanCycle()
        }
        pendingScan = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scanCycle() {
        refreshIdentities()
        scanChangedFiles()
        reloadCache()
        lastScanAt = Date()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func rescanAll() {
        queue.async {
            self.store.deleteAllData()
            self.statCache.removeAll()
            self.currentUserKeys.removeAll()
            self.bootstrap()
        }
    }

    // MARK: - Identity tracking

    private struct IdentityInfo {
        var loggedIn: Bool
        var name: String
        var email: String?
        var avatar: String?
        var key: String
        var snapshotAt: Date
    }

    /// 各产品登录态文件结构不同：Qoder 为扁平字段，WorkBuddy 为 account/auth 嵌套
    private func identityInfo(for src: Paths.ProductSource, obj: [String: Any]) -> IdentityInfo {
        switch src.product {
        case .workbuddy:
            let account = obj["account"] as? [String: Any] ?? [:]
            let uid = account["uid"] as? String ?? ""
            let nickname = account["nickname"] as? String ?? ""
            let auth = obj["auth"] as? [String: Any] ?? [:]
            return IdentityInfo(
                loggedIn: ((account["lastLogin"] as? Bool) ?? false) && !uid.isEmpty,
                name: nickname.isEmpty ? "WorkBuddy 用户" : nickname,
                email: nil,
                avatar: nil,
                key: "\(src.product.rawValue):\(uid)",
                snapshotAt: JSONLScanner.parseDate(auth["lastRefreshTime"]) ?? Date()
            )
        case .qoderCN, .qoderINTL:
            let name = obj["name"] as? String ?? "未知用户"
            let email = obj["email"] as? String
            return IdentityInfo(
                loggedIn: (obj["logged_in"] as? Bool) ?? false,
                name: name,
                email: email,
                avatar: obj["avatar_url"] as? String,
                key: "\(src.product.rawValue):\((email ?? name).lowercased())",
                snapshotAt: JSONLScanner.parseDate(obj["snapshot_at"]) ?? Date()
            )
        }
    }

    private func refreshIdentities() {
        for src in Paths.sources {
            guard let data = try? Data(contentsOf: src.statusFile),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            let info = identityInfo(for: src, obj: obj)
            if !info.loggedIn {
                if currentUserKeys[src.product] != nil {
                    store.closeOpenWindows(product: src.product, at: Date())
                    currentUserKeys[src.product] = nil
                }
                continue
            }

            let key = info.key
            let now = Date()

            if currentUserKeys[src.product] == key {
                // 同一用户：低频刷新 lastSeen
                if let last = lastIdentityTouch[src.product], now.timeIntervalSince(last) < 300 { continue }
                lastIdentityTouch[src.product] = now
                store.upsertIdentity(IdentityRecord(
                    userKey: key, name: info.name, email: info.email, avatarURL: info.avatar,
                    product: src.product, firstSeen: now, lastSeen: now))
                continue
            }

            let isFirstSighting = currentUserKeys[src.product] == nil
            let wins = store.windows(for: src.product)
            let alreadyCurrent = wins.last?.userKey == key && wins.last?.end == nil

            if !alreadyCurrent {
                store.closeOpenWindows(product: src.product, at: info.snapshotAt)
                store.openWindow(userKey: key, product: src.product, at: info.snapshotAt)
            }

            let existing = store.identities().first { $0.userKey == key }
            store.upsertIdentity(IdentityRecord(
                userKey: key, name: info.name, email: info.email, avatarURL: info.avatar,
                product: src.product,
                firstSeen: existing?.firstSeen ?? info.snapshotAt,
                lastSeen: now))

            if isFirstSighting {
                // 该产品历史无归属的记录归给唯一账号（仅当确认只有一个账号时）
                if accountProfileCount(product: src.product) <= 1 {
                    _ = store.reattributeEventsWithoutUser(product: src.product, userKey: key)
                }
            }

            currentUserKeys[src.product] = key
            currentUserNames[src.product] = info.name
            lastIdentityTouch[src.product] = now
        }
    }

    private func accountProfileCount(product: QoderProduct) -> Int {
        let dbPath: String
        switch product {
        case .qoderCN:
            dbPath = Paths.home.appendingPathComponent(
                "Library/Application Support/com.qodercn.app.stable/main.sqlite").path
        case .qoderINTL:
            dbPath = Paths.home.appendingPathComponent(
                "Library/Application Support/Qoder/main.sqlite").path
        case .workbuddy:
            // 登录态文件即账号库，accounts 列表当前仅保存单个账号
            return 1
        }
        guard FileManager.default.fileExists(atPath: dbPath) else { return 1 }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 1 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM account_profiles;", -1, &stmt, nil) == SQLITE_OK else { return 1 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Scanning

    /// 服务端不返回真实输入 tokens 时，用上下文占比推算：
    /// 输入 = 占比 × 200K；前缀缓存模型下命中 ≈ 上一轮上下文，新建 ≈ 本轮增量。
    private static func deriveContextTokens(_ e: inout UsageEvent, prevCtx: inout Double?) {
        guard let r = e.ctxRatio else { return }
        let ctx = r * Metrics.contextWindowTokens
        if e.inputTokens == 0 {
            let input = Int(ctx.rounded())
            let prev = Int((prevCtx ?? 0).rounded())
            e.inputTokens = input
            e.cacheRead = min(input, prev)
            e.cacheWrite = max(0, input - prev)
        }
        prevCtx = ctx
    }

    private func scanChangedFiles() {
        var sessionFiles: [(URL, QoderProduct)] = []
        for src in Paths.sources {
            for root in src.roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let url as URL in enumerator {
                    guard url.pathExtension == "jsonl" else { continue }
                    sessionFiles.append((url, src.product))
                }
            }
        }

        var newestActivity: Date?
        for (url, product) in sessionFiles {
            let path = url.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int,
                  let mtimeDate = attrs[.modificationDate] as? Date
            else { continue }
            let mtime = mtimeDate.timeIntervalSince1970

            if let cached = statCache[path], cached.mtime == mtime, cached.size == size {
                if newestActivity == nil || mtimeDate > newestActivity! { newestActivity = mtimeDate }
                continue
            }

            let stored = store.fileState(path: path)
            let startOffset = (stored != nil && stored!.offset <= size) ? stored!.offset : 0
            let prevTs = startOffset > 0 ? stored?.lastTs.map { Date(timeIntervalSince1970: $0) } : nil

            let output: FileScanOutput?
            if product == .workbuddy {
                output = workBuddyScanner.scanFile(url: url, product: product, startOffset: startOffset, prevTs: prevTs)
            } else {
                output = scanner.scanFile(url: url, product: product, startOffset: startOffset, prevTs: prevTs)
            }

            if let output {
                if !output.events.isEmpty {
                    var keyed = output.events
                    var prevCtx: Double? = store.lastCtxRatio(sessionId: keyed[0].sessionId)
                        .map { $0 * Metrics.contextWindowTokens }
                    for i in keyed.indices {
                        keyed[i].userKey = store.resolveUserKey(product: product, ts: keyed[i].ts)
                        Self.deriveContextTokens(&keyed[i], prevCtx: &prevCtx)
                    }
                    _ = store.insertEvents(keyed)
                }
                store.setFileState(path: path, state: FileState(
                    offset: output.endOffset,
                    lastTs: output.lastTs?.timeIntervalSince1970,
                    mtime: output.mtime,
                    size: output.size))
            } else {
                issues.append("无法读取会话文件：\(Fmt.projectName(path))")
            }
            statCache[path] = (mtime, size)
            if newestActivity == nil || mtimeDate > newestActivity! { newestActivity = mtimeDate }
        }
        if let newest = newestActivity {
            if lastFileActivity == nil || newest > lastFileActivity! { lastFileActivity = newest }
        }
    }

    private func reloadCache() {
        let from = Date().addingTimeInterval(-120 * 86_400)
        eventsCache = store.events(from: from)
    }

    // MARK: - Public API

    func snapshot(range: TimeRange, userKey: String?, settings: AppSettings) -> MetricsSnapshot {
        queue.sync {
            Metrics.build(
                events: eventsCache,
                identities: store.identities(),
                selectedUser: userKey,
                range: range,
                settings: settings,
                lastScanAt: lastScanAt,
                lastFileActivity: lastFileActivity,
                issues: issues,
                totalEventCount: store.eventCount()
            )
        }
    }

    func exportEvents(userKey: String?) -> [UsageEvent] {
        queue.sync {
            userKey == nil ? eventsCache : eventsCache.filter { $0.userKey == userKey }
        }
    }

    func currentIssues() -> [String] {
        queue.sync { issues }
    }

    func currentUser(product: QoderProduct) -> (key: String, name: String)? {
        queue.sync {
            guard let k = currentUserKeys[product] else { return nil }
            return (k, currentUserNames[product] ?? "")
        }
    }

    func databasePath() -> String { Paths.databaseURL.path }
}
