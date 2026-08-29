import AppKit
import FineDisplayKit
import ServiceManagement

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

if CommandLine.arguments.contains("--check-updates") {
    // Headless check for testing: print the comparison result, exit.
    let sema = DispatchSemaphore(value: 0)
    UpdateChecker.shared.fetchLatest { latest in
        if let latest {
            let newer = FineDisplayInfo.isNewer(latest.version, than: FineDisplayInfo.version)
            print("current \(FineDisplayInfo.version), latest \(latest.version) → \(newer ? "update available" : "up to date") (\(latest.page))")
        } else {
            print("fetch failed")
        }
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 15)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--login-item"), i + 1 < CommandLine.arguments.count {
    // Scriptable launch-at-login toggle: FineDisplay --login-item on|off
    setLoginItem(enable: CommandLine.arguments[i + 1] == "on")
    exit(0)
}

app.setActivationPolicy(.accessory)
app.run()


func setLoginItem(enable: Bool) {
    do {
        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
    } catch {
        FileHandle.standardError.write("login item: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
