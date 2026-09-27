import Foundation

protocol Collector {
    var cli: CLIKind { get }
    /// Paths this collector considers, used for cache pruning.
    func discoverPaths() -> [String]
    func collect(cache: ScanCache) -> [UsageBucket]
}

extension Collector {
    var home: String { NSHomeDirectory() }
}

/// Convenience for reading a nested integer out of a decoded JSON object.
@inline(__always)
func intValue(_ any: Any?) -> Int {
    switch any {
    case let n as NSNumber: return n.intValue
    case let i as Int: return i
    case let d as Double: return Int(d)
    default: return 0
    }
}
