import Foundation
import SQLite3

/// Completeness is separate from price coverage. A model can be priced while
/// entire tools or deleted histories remain outside the observed ledger.
struct CoverageReport {
    var issues: [String] = []
    var retainedLogs: Int = 0
    var missingCodexLogs: Int = 0

    static func inspect(cache: ScanCache) -> CoverageReport {
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let codex = env["CODEX_HOME"] ?? home + "/.codex"
        let claude = env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        let pi = env["PI_CODING_AGENT_DIR"] ?? home + "/.pi/agent"
        let gemini = env["GEMINI_CLI_HOME"] ?? home + "/.gemini"
        let xdg = env["XDG_DATA_HOME"] ?? home + "/.local/share"
        let roots = [codex + "/sessions", codex + "/archived_sessions", claude + "/projects",
                     pi + "/sessions", gemini + "/tmp", xdg + "/opencode", xdg + "/devin/cli"]
        var report = CoverageReport(retainedLogs: cache.missingPathCount(under: roots))
        report.missingCodexLogs = missingRollouts(in: codex + "/state_5.sqlite")
        if report.missingCodexLogs > 0 {
            report.issues.append("Codex 有 \(report.missingCodexLogs) 个历史会话缺少日志，历史总量不完整")
        }
        if report.retainedLogs > 0 {
            report.issues.append("已保留 \(report.retainedLogs) 份消失日志的已采集用量")
        }
        var unsupported: [String] = []
        if FileManager.default.fileExists(atPath: home + "/.cursor/projects") { unsupported.append("Cursor") }
        if FileManager.default.fileExists(atPath: gemini + "/antigravity-cli/conversations") { unsupported.append("Antigravity") }
        if !unsupported.isEmpty { report.issues.append(unsupported.joined(separator: "、") + " 的账单用量尚未接入") }
        return report
    }

    static func missingRollouts(in path: String) -> Int {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        var db: OpaquePointer?
        // File URL handles literal #, %, and ? in the home path correctly.
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var missing = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0) else { continue }
            if !FileManager.default.fileExists(atPath: String(cString: p)) { missing += 1 }
        }
        return missing
    }
}
