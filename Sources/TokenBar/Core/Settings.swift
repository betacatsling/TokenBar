import Foundation
import Combine

/// User preferences, persisted to `UserDefaults` on every mutation.
final class Settings: ObservableObject {
    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let showCountInMenuBar = "showCountInMenuBar"
        static let includeSidechain = "includeSidechain"
        static let remoteEnabled = "remoteEnabled"
        static let remoteHost = "remoteHost"
        static let remoteTTL = "remoteTTL"
        static let defaultRange = "defaultRange"
    }

    private let defaults: UserDefaults

    /// How often the menu bar number refreshes in the background.
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// Show the today-token figure next to the icon, or icon only.
    @Published var showCountInMenuBar: Bool {
        didSet { defaults.set(showCountInMenuBar, forKey: Key.showCountInMenuBar) }
    }

    /// Include Claude Code subagent (sidechain) traffic in totals.
    @Published var includeSidechain: Bool {
        didSet { defaults.set(includeSidechain, forKey: Key.includeSidechain) }
    }

    /// Query server1 over SSH.
    @Published var remoteEnabled: Bool {
        didSet { defaults.set(remoteEnabled, forKey: Key.remoteEnabled) }
    }

    @Published var remoteHost: String {
        didSet { defaults.set(remoteHost, forKey: Key.remoteHost) }
    }

    /// Seconds before a remote result is considered stale.
    @Published var remoteTTL: TimeInterval {
        didSet { defaults.set(remoteTTL, forKey: Key.remoteTTL) }
    }

    @Published var defaultRange: TimeRange {
        didSet { defaults.set(defaultRange.rawValue, forKey: Key.defaultRange) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register defaults so first launch behaves sensibly without any writes.
        defaults.register(defaults: [
            Key.refreshInterval: 60.0,
            Key.showCountInMenuBar: true,
            Key.includeSidechain: false,
            Key.remoteEnabled: true,
            Key.remoteHost: "server1",
            Key.remoteTTL: 600.0,
            Key.defaultRange: TimeRange.today.rawValue,
        ])

        refreshInterval = defaults.double(forKey: Key.refreshInterval)
        showCountInMenuBar = defaults.bool(forKey: Key.showCountInMenuBar)
        includeSidechain = defaults.bool(forKey: Key.includeSidechain)
        remoteEnabled = defaults.bool(forKey: Key.remoteEnabled)
        remoteHost = defaults.string(forKey: Key.remoteHost) ?? "server1"
        remoteTTL = defaults.double(forKey: Key.remoteTTL)
        defaultRange = TimeRange(rawValue: defaults.string(forKey: Key.defaultRange) ?? "") ?? .today
    }

    /// Preferences backed by a throwaway suite.
    ///
    /// Used by the `--render` / `--verify` harnesses. Those take flags like
    /// `--host` to exercise failure paths, and writing those through to the real
    /// store would silently repoint the user's actual app at a dead host.
    static func scratch(suiteName: String = "local.tokenbar.harness") -> Settings {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return Settings(defaults: defaults)
    }
}
