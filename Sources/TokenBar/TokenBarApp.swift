import SwiftUI
import AppKit

/// Menu bar entry point.
///
/// `MenuBarExtra` with `.menuBarExtraStyle(.window)` gives the click-to-open
/// panel. The app runs as an accessory (`LSUIElement`), so it never appears in
/// the Dock or the app switcher.
@main
struct TokenBarApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Diagnostics mode: scan, print a summary, exit. Used by the verification
        // harness to cross-check the Swift numbers against an independent pass.
        if CommandLine.arguments.contains("--verify") {
            Verify.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--test-wal-cache") {
            Verify.testWALSidecarInvalidation()
            exit(0)
        }
        if CommandLine.arguments.contains("--test-resume") {
            Verify.testResume()
            exit(0)
        }
        // Renders the popover to a PNG so the layout can be inspected without a
        // human clicking the menu bar item.
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            let out = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : "/tmp/tokenbar.png"
            Verify.render(path: out)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            let title = model.menuBarTitle
            // Show the chart glyph when there is nothing to report yet, so the
            // item is never an empty click target.
            if let title {
                Text(title)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
