import Foundation

/// Optional invoices/imported charges, intentionally separate from API-equivalent
/// token estimates. Empty means no bill is known, not that spending was zero.
struct BillingCharge: Codable, Hashable {
    var id: String
    var date: String
    var provider: String
    var label: String
    var usd: Double
}

struct BillingLedger {
    var charges: [BillingCharge] = []
    var issue: String?

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_BILLING_FILE"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenBar/billing.json")
    }

    static func load(from url: URL = Self.url) -> BillingLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return BillingLedger() }
        do {
            let charges = try JSONDecoder().decode([BillingCharge].self, from: Data(contentsOf: url))
            var ids = Set<String>()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            for c in charges {
                guard !c.id.isEmpty, ids.insert(c.id).inserted,
                      !c.provider.isEmpty, !c.label.isEmpty, c.usd.isFinite,
                      let date = formatter.date(from: c.date), formatter.string(from: date) == c.date else {
                    return BillingLedger(issue: "账单文件含重复编号或无效金额、日期，未计入")
                }
            }
            return BillingLedger(charges: charges)
        } catch {
            return BillingLedger(issue: "账单文件无法读取，未计入；请检查 billing.json 格式")
        }
    }

    func charges(in range: TimeRange) -> [BillingCharge] {
        let today = DayFormatter.today()
        return charges.filter { $0.date <= today && range.contains(day: $0.date, today: today) }
    }

    func usd(in range: TimeRange) -> Double { charges(in: range).reduce(0) { $0 + $1.usd } }

    static func createIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: url, options: .atomic)
    }
}
