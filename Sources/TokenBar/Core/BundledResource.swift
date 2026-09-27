import Foundation

/// Locates resources staged into the `.app`, without going through
/// `Bundle.module`.
///
/// ## Why not `Bundle.module`
///
/// SwiftPM generates that accessor to look for `TokenBar_TokenBar.bundle`
/// *beside* `Bundle.main.bundleURL` — a flat layout — and if that misses it
/// falls back to a **hardcoded absolute path into the `.build` directory of the
/// machine that compiled it**:
///
/// ```swift
/// let mainPath  = Bundle.main.bundleURL.appendingPathComponent("TokenBar_TokenBar.bundle").path
/// let buildPath = "/Users/…/tokens/.build/arm64-apple-macosx/release/TokenBar_TokenBar.bundle"
/// guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { fatalError(…) }
/// ```
///
/// A macOS `.app` keeps resources in `Contents/Resources/`, so `mainPath` never
/// matches and every lookup takes the fallback. That path here is under
/// `~/Desktop`, which is TCC-protected: launched through LaunchServices the read
/// blocks on a consent prompt, and an `LSUIElement` accessory app has no window
/// for that prompt to attach to, so it never resolves.
///
/// Measured, same binary and same bundle:
///
///   * `open /Applications/TokenBar.app` → 0% CPU, 35 MB RSS, still in
///     `__open_nocancel` under `Bundle.module` after **10 minutes**. The menu bar
///     item never appears and no scan ever starts, because this runs inside
///     `AppModel.init`.
///   * exec'ing `…/Contents/MacOS/TokenBar` directly (no LaunchServices, no TCC)
///     → scans normally, 1.2 GB RSS.
///
/// The old build hangs identically when installed to the same path, so this is a
/// long-standing packaging bug rather than a regression — it was invisible while
/// the app was only ever launched straight out of `dist/`.
///
/// This helper probes the real `.app` layout first and only consults the source
/// tree afterwards, so nothing depends on a build directory existing at runtime.
enum BundledResource {
    /// The resource bundle `build_app.sh` stages into the `.app`.
    private static let bundleName = "TokenBar_TokenBar.bundle"

    /// Resolve `name.ext`, or nil if no layout provides it.
    ///
    /// - Parameter devAnchor: `#filePath` of the caller, used to find the source
    ///   tree when running via `swift run`. Passed in rather than hardcoded so
    ///   the fallback is relative to the calling file, not to this one.
    static func url(named name: String, ext: String, devAnchor: String) -> URL? {
        let base = Bundle.main.bundleURL
        let resources = base.appendingPathComponent("Contents/Resources")

        for bundleURL in [resources.appendingPathComponent(bundleName),
                          base.appendingPathComponent(bundleName)] {
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }

        // Loose in Contents/Resources/, for resources staged without a bundle.
        let loose = resources.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: loose.path) { return loose }

        // Development: the source tree next to the calling file.
        let dev = URL(fileURLWithPath: devAnchor)
            .deletingLastPathComponent()   // the caller's directory
            .deletingLastPathComponent()   // Sources/TokenBar
            .appendingPathComponent("Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}
