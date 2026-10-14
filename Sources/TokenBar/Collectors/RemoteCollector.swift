import Foundation

/// Status of the last remote fetch, surfaced in the UI.
enum RemoteStatus: Equatable {
    case idle
    case fetching
    case ok(Date)
    case offline(String)

    var isOffline: Bool { if case .offline = self { return true }; return false }
}

/// Gathers server1 usage over SSH.
///
/// server1 holds ~530 MB of Claude transcripts plus thousands of Codex rollouts,
/// so pulling raw logs would be slow and wasteful. Instead a self-contained
/// Python script is piped to the remote interpreter over stdin and only the
/// aggregated buckets (a few KB of JSON) come back.
///
/// The user's `~/.ssh/config` already defines server1 with `ControlMaster auto`
/// and `ControlPersist 10m`, so repeated invocations reuse one TCP connection.
/// Results are additionally cached in memory for `ttl` seconds.
final class RemoteCollector {
    static let origin: Origin = .server1

    /// Guarded by `lock` — read from the scan thread, written from the settings UI.
    private var _host: String
    private var _ttl: TimeInterval

    private var cachedBuckets: [UsageBucket] = []
    private var lastFetch: Date?
    private var _status: RemoteStatus = .idle
    private let lock = NSLock()
    private var _diagnostics: [String] = []
    private var savedDate: Date?

    /// The host as currently configured.
    var host: String { lock.lock(); defer { lock.unlock() }; return _host }
    var ttl: TimeInterval { lock.lock(); defer { lock.unlock() }; return _ttl }

    /// Written on the scan thread, read on the main thread when the snapshot is
    /// rebuilt, so it is guarded like the rest of the mutable state here.
    var status: RemoteStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var diagnostics: [String] { lock.lock(); defer { lock.unlock() }; return _diagnostics }

    init(host: String = "server1", ttl: TimeInterval = 600) {
        self._host = host
        self._ttl = ttl
        restoreSnapshot(host: host)
    }

    /// Apply changed settings. Discards the cached timestamp so the next fetch
    /// actually contacts the (possibly new) host, while keeping the last known
    /// buckets so the UI never blanks out during the transition.
    func reconfigure(host: String, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if _host != host {
            _host = host
            lastFetch = nil
            cachedBuckets = []
            _diagnostics = []
            savedDate = nil
            restoreSnapshot(host: host)
        }
        _ttl = ttl
    }

    /// Cached buckets regardless of age — used to keep showing stale data when
    /// the server is unreachable.
    var lastKnownBuckets: [UsageBucket] {
        lock.lock(); defer { lock.unlock() }
        return cachedBuckets
    }

    var lastKnownDate: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastFetch ?? savedDate
    }

    /// Returns fresh buckets, or the previous ones if the TTL has not elapsed or
    /// the connection fails. Never throws — failure is a display state, not an
    /// error the UI should have to handle.
    @discardableResult
    func fetchIfNeeded(force: Bool = false) -> [UsageBucket] {
        lock.lock()
        // Read the underlying fields, not the `ttl` accessor — that would take the
        // same non-recursive lock again and deadlock.
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < _ttl {
            let cached = cachedBuckets
            lock.unlock()
            return cached
        }
        lock.unlock()

        lock.lock()
        _status = .fetching
        let scanHost = _host
        lock.unlock()

        let result = runRemote(host: scanHost)

        lock.lock()
        defer { lock.unlock() }
        guard _host == scanHost else { return cachedBuckets }
        switch result {
        case .success(let buckets):
            cachedBuckets = mergeBuckets(buckets)
            lastFetch = Date()
            savedDate = lastFetch
            _status = .ok(Date())
            return cachedBuckets
        case .failure(let error):
            _status = .offline(error.localizedDescription)
            return cachedBuckets
        }
    }

    private enum FetchError: LocalizedError {
        case scriptMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing: return "远端采集脚本缺失"
            case .failed(let msg): return msg
            }
        }
    }

    private func runRemote(host: String) -> Result<[UsageBucket], Error> {
        guard let script = RemoteCollector.scriptURL,
              let scriptData = try? Data(contentsOf: script) else {
            return .failure(FetchError.scriptMissing)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // BatchMode prevents an interactive password prompt from hanging the UI.
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            host,
            "env TZ=\(TimeZone.current.identifier) python3 -"
        ]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(FetchError.failed("无法启动 ssh：\(error.localizedDescription)"))
        }

        // Write the script, then close stdin so the remote interpreter runs it.
        stdin.fileHandleForWriting.write(scriptData)
        try? stdin.fileHandleForWriting.close()

        // Read before waiting to avoid a full pipe buffer deadlocking the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(FetchError.failed(msg.isEmpty ? "ssh 退出码 \(process.terminationStatus)" : msg))
        }

        do {
            let buckets = try RemotePayload.decode(outData)
            let envelope = try JSONDecoder().decode(RemotePayload.Envelope.self, from: outData)
            lock.lock()
            if _host == host { _diagnostics = envelope.diagnostics ?? [] }
            lock.unlock()
            persistSnapshot(outData, host: host)
            return .success(buckets)
        } catch {
            return .failure(FetchError.failed("远端返回无法解析：\(error.localizedDescription)"))
        }
    }

    private static func snapshotURL(host: String) -> URL {
        let name = Data(host.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return ScanCache.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("remote-\(name).json")
    }

    private func persistSnapshot(_ data: Data, host: String) {
        let url = Self.snapshotURL(host: host)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func restoreSnapshot(host: String) {
        let url = Self.snapshotURL(host: host)
        guard let data = try? Data(contentsOf: url), let buckets = try? RemotePayload.decode(data) else { return }
        cachedBuckets = buckets
        _diagnostics = (try? JSONDecoder().decode(RemotePayload.Envelope.self, from: data).diagnostics) ?? []
        lastFetch = nil // An offline snapshot must never bypass the first fetch.
        savedDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        _status = .offline("已加载上次保存的汇总，等待刷新")
    }

    /// Locate the bundled script. See `BundledResource` for why this avoids
    /// `Bundle.module` — which would hang the app on launch.
    static var scriptURL: URL? {
        BundledResource.url(named: "remote_collect", ext: "py", devAnchor: #filePath)
    }
}

/// Wire format between `remote_collect.py` and the app.
///
/// Buckets are exchanged as flat arrays rather than objects to keep the payload
/// small; `RemotePayload.decode` rebuilds `UsageBucket` values.
enum RemotePayload {
    struct Envelope: Codable {
        var version: Int
        var host: String
        var buckets: [Row]
        var diagnostics: [String]?
    }

    struct Row: Codable {
        var cli: String
        var model: String
        var day: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var sidechain: Bool
        var cacheWrite1h: Int?
        var provider: String?
        var reportedCostUSD: Double?
        var costSource: String?
        var pricingTier: String?
        var serviceTier: String?
        var speed: String?
        var inferenceGeo: String?
    }

    enum DecodeError: LocalizedError {
        case badEnvelope(String)
        var errorDescription: String? {
            switch self { case .badEnvelope(let s): return s }
        }
    }

    static func decode(_ data: Data) throws -> [UsageBucket] {
        guard !data.isEmpty else { throw DecodeError.badEnvelope("空响应") }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.buckets.compactMap { row -> UsageBucket? in
            guard let cli = CLIKind(rawValue: row.cli) else { return nil }
            return UsageBucket(
                origin: .server1, cli: cli, model: row.model, day: row.day,
                tokens: TokenCounts(input: row.input, output: row.output,
                                    cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                                    cacheWrite1h: row.cacheWrite1h ?? 0),
                isSidechain: row.sidechain,
                provider: row.provider, reportedCostUSD: row.reportedCostUSD,
                costSource: row.costSource, pricingTier: row.pricingTier,
                serviceTier: row.serviceTier, speed: row.speed, inferenceGeo: row.inferenceGeo
            )
        }
    }
}
