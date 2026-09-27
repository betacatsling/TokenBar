import Foundation

/// Display formatting helpers.
enum Fmt {
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// `1234567` -> `"1.2M"`. Used where space is tight (menu bar, cards).
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", d / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", d / 1_000)
        default:               return "\(n)"
        }
    }

    /// `1234567` -> `"1,234,567"`. Used in detail rows.
    static func grouped(_ n: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Cost, always shown with a leading `≈` by callers since these are estimates.
    static func usd(_ d: Double) -> String {
        if d <= 0 { return "$0" }
        if d < 0.01 { return String(format: "$%.3f", d) }
        if d < 100 { return String(format: "$%.2f", d) }
        // Cents stop carrying information here, and "$377.11" plus the `+`/`~`
        // markers overflows the 56 pt cost column and wraps onto two lines.
        if d < 1_000 { return String(format: "$%.0f", d) }
        return String(format: "$%.1fK", d / 1_000)
    }

    /// `"3 分钟前"`
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<5: return "刚刚"
        case ..<60: return "\(Int(seconds)) 秒前"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86400: return "\(Int(seconds / 3600)) 小时前"
        default: return "\(Int(seconds / 86400)) 天前"
        }
    }

    /// Duration for the diagnostic footer.
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000)
                    : String(format: "%.2f s", seconds)
    }

    /// Share of a total, `0.604` -> `"60%"`. A real but tiny share reads `<1%`
    /// rather than `0%`, which would look like nothing at all.
    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p <= 0 { return "0%" }
        if p < 1 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// `"2026-09-26"` -> `"9/26"`, for chart axis labels.
    static func shortDay(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// `"2026-09-26"` -> `"9月26日 周六"`, or `"今天"` / `"昨天"`.
    static func dayTitle(_ day: String) -> String {
        let recent = DayFormatter.recentDays(2)
        if day == recent.last { return "今天" }
        if day == recent.first { return "昨天" }
        guard let date = dayParser.date(from: day) else { return day }
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日 \(weekdays[((c.weekday ?? 1) - 1) % 7])"
    }
}
