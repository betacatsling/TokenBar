import Foundation
import SQLite3

enum AccountingTests {
    static func run() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tokenbar-ledger-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("ledger: \(name): \(ok ? "PASS" : "FAIL")")
            if !ok { failures.append(name) }
        }
        let path = dir.appendingPathComponent("sessions/a.jsonl").path
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data("first".utf8).write(to: URL(fileURLWithPath: path))
        let url = dir.appendingPathComponent("cache.json")
        let cache = ScanCache(url: url)
        let event = UsageEventRecord(rid: "call-a", model: "m", day: "2026-09-30", tokens: TokenCounts(input: 100))
        _ = cache.events(for: path) { [event] }
        cache.save(knownPaths: [path])
        try! FileManager.default.removeItem(atPath: path)
        cache.save(knownPaths: [])
        check("deleted log stays counted", cache.events(for: path) { [] }.reduce(0) { $0 + $1.tokens.total } == 100)
        let reloaded = ScanCache(url: url)
        check("history survives restart", reloaded.events(for: path) { [] }.first?.tokens.total == 100)
        reloaded.clear()
        reloaded.save(knownPaths: [])
        check("rescan keeps deleted history", ScanCache(url: url).events(for: path) { [] }.first?.tokens.total == 100)
        check("retained roots stay isolated", reloaded.retainedPaths(under: dir.appendingPathComponent("other").path).isEmpty)
        try! Data("different content".utf8).write(to: URL(fileURLWithPath: path))
        var updated = event; updated.tokens.input = 150
        check("restored file replaces its own snapshot", reloaded.events(for: path) { [updated] }.first?.tokens.total == 150)

        let oldCounts = Data(#"{"input":2,"output":3,"cacheRead":4,"cacheWrite":5}"#.utf8)
        check("old token cache decodes", (try? JSONDecoder().decode(TokenCounts.self, from: oldCounts).total) == 14)
        let bill = dir.appendingPathComponent("billing.json")
        let charges = [BillingCharge(id: "subscription", date: "2026-09-30", provider: "ChatGPT", label: "subscription", usd: 200),
                       BillingCharge(id: "refund", date: "2026-09-30", provider: "gateway", label: "refund", usd: -10)]
        try! JSONEncoder().encode(charges).write(to: bill)
        check("actual invoices include refunds", BillingLedger.load(from: bill).usd(in: .all) == 190)
        try! JSONEncoder().encode([charges[0], charges[0]]).write(to: bill)
        let invalid = BillingLedger.load(from: bill)
        check("duplicate invoice rejected", invalid.charges.isEmpty && invalid.issue != nil)

        let wire = Data(#"{"version":1,"host":"test","buckets":[{"cli":"gemini","model":"m","day":"2026-09-30","input":1,"output":2,"cacheRead":3,"cacheWrite":4,"cacheWrite1h":5,"sidechain":false,"provider":"google","reportedCostUSD":6,"costSource":"client-estimate"}]}"#.utf8)
        let decoded = try? RemotePayload.decode(wire)
        check("remote billing metadata survives", decoded?.first?.tokens.total == 15 && decoded?.first?.reportedCostUSD == 6 && decoded?.first?.provider == "google")
        print("ledger: RESULT = \(failures.isEmpty ? "PASS" : "FAIL")")
        if !failures.isEmpty { exit(1) }
    }
}
