import AppKit
import FineDisplayKit

// FineDisplay menu bar app. AppKit on purpose: NSMenu rebuilds on every open
// (menuNeedsUpdate), and the menu tree can be dumped for testing (`--dump-menu`).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if CommandLine.arguments.contains("--dump-menu") {
    // Headless check: build the menu once, print it, exit.
    let controller = MenuController()
    print(controller.dump())
    exit(0)
}

app.setActivationPolicy(.accessory)
app.run()
