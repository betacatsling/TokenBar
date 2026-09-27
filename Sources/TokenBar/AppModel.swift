import Foundation
import Combine
import SwiftUI

/// Owns the scan loop and publishes the snapshot the popover renders.
///
/// Scanning touches a multi-gigabyte log tree, so it always runs off the main
/// thread; only the resulting value type crosses back.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published var range: TimeRange

    let settings: Settings
    private let aggregator: Aggregator
    private var timer: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var localBuckets: [UsageBucket] = []
    private var remoteBuckets: [UsageBucket] = []
    private var hasScanned = false
    private var lastScanInputs: ScanInputs?

    /// - Parameter autoScan: start the background scan loop immediately. The
    ///   `--render` harness passes `false` because it drives `scanBlocking`
    ///   itself; leaving auto-scan on made the initial detached scan and the
    ///   harness's synchronous scan run concurrently over one `ScanCache`.
    init(settings: Settings = Settings(), autoScan: Bool = true) {
        self.settings = settings
        self.range = settings.defaultRange
        // Honor the configured host/TTL rather than the defaults baked into the type.
        self.aggregator = Aggregator(
            remote: RemoteCollector(host: settings.remoteHost, ttl: settings.remoteTTL)
        )
        startTimer()
        observeSettings()
        if autoScan {
            refresh(forceRemote: false)
        }
    }

    /// Push host/TTL changes into the collector, and rescan when the user flips a
    /// toggle that changes what gets counted. Without this the settings UI would
    /// appear to work but only take effect on the next launch.
    ///
    /// Deliberately filtered: `setRange` also writes through to settings, and
    /// rescanning on every range click would trigger a needless SSH round trip.
    private func observeSettings() {
        settingsObserver = settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let scanRelevant = ScanInputs(
                    host: self.settings.remoteHost,
                    ttl: self.settings.remoteTTL,
                    remoteEnabled: self.settings.remoteEnabled,
                    includeSidechain: self.settings.includeSidechain
                )
                guard scanRelevant != self.lastScanInputs else { return }
                self.lastScanInputs = scanRelevant
                self.aggregator.remote.reconfigure(host: self.settings.remoteHost,
                                                   ttl: self.settings.remoteTTL)
                self.refresh(forceRemote: true)
            }
    }

    /// Settings that change what a scan produces.
    private struct ScanInputs: Equatable {
        var host: String
        var ttl: TimeInterval
        var remoteEnabled: Bool
        var includeSidechain: Bool
    }

    private func startTimer() {
        timer = Timer.publish(every: max(15, settings.refreshInterval), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh(forceRemote: false)
            }
    }

    /// Rescan. `forceRemote` bypasses the server-side TTL cache.
    func refresh(forceRemote: Bool = true) {
        guard !isScanning else { return }
        isScanning = true

        let includeSidechain = settings.includeSidechain
        let remoteEnabled = settings.remoteEnabled
        let aggregator = self.aggregator

        Task.detached(priority: .utility) { [weak self] in
            let (buckets, duration) = aggregator.scanLocal(includeSidechain: includeSidechain)
            // Bind to a `let` before hopping actors: a captured `var` would be
            // flagged as concurrent mutation under the Swift 6 language mode.
            let remote = remoteEnabled
                ? aggregator.scanRemoteIfNeeded(force: forceRemote)
                : []

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.localBuckets = buckets
                self.remoteBuckets = remote
                self.rebuild(duration: duration)
                self.isScanning = false
            }
        }
    }

    private func rebuild(duration: TimeInterval) {
        snapshot = aggregator.snapshot(
            range: range,
            includeSidechain: settings.includeSidechain,
            localBuckets: localBuckets,
            remoteBuckets: remoteBuckets,
            duration: duration
        )
    }

    func setRange(_ newRange: TimeRange) {
        range = newRange
        settings.defaultRange = newRange
        // Re-aggregate from the buckets already in hand; no rescan needed.
        rebuild(duration: snapshot.scanDuration)
    }

    func clearCacheAndRescan() {
        aggregator.clearCache()
        refresh(forceRemote: true)
    }

    /// Text for the menu bar button.
    var menuBarTitle: String? {
        guard settings.showCountInMenuBar else { return nil }
        let today = DayFormatter.today()
        let total = snapshot.buckets
            .filter { $0.day == today }
            .reduce(0) { $0 + $1.tokens.total }
        guard total > 0 else { return nil }
        return Fmt.compact(total)
    }

    /// Synchronous one-shot scan used by the `--render` harness. Never used in
    /// the running app, where scanning stays off the main thread.
    func scanBlocking(includeRemote: Bool = true) {
        let (buckets, duration) = aggregator.scanLocal(includeSidechain: settings.includeSidechain)
        localBuckets = buckets
        if includeRemote && settings.remoteEnabled {
            remoteBuckets = aggregator.scanRemoteIfNeeded(force: true)
        }
        rebuild(duration: duration)
    }
}
