import AppKit
import FineDisplayKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: MenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SkyLight_isAvailable() else {
            let alert = NSAlert()
            alert.messageText = "FineDisplay cannot run on this macOS build"
            alert.informativeText = "The WindowServer functions it relies on did not resolve. Check finedisplay.nousworks.co for an update."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        menuController = MenuController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.toolTip = "FineDisplay"
        statusItem.menu = menuController.menu

        Enforcer.shared.onChange = { [weak self] in
            // Nothing to redraw while closed; the menu rebuilds on open. But gamma-based
            // software dimming is reset by WindowServer on reconnect/wake/mode changes,
            // and onChange fires after exactly those — put it back.
            _ = self
            BrightnessManager.shared.reapplySoftwareDimming()
        }
        Enforcer.shared.start()

        // The CLI cannot own software dimming (gamma dies with the process), so it asks
        // the app to do it. Object format: "displayUUID:percent".
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(BrightnessManager.setBrightnessNotification), object: nil, queue: .main
        ) { note in
            guard let s = note.object as? String else { return }
            let parts = s.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let percent = Int(parts[1]) else { return }
            let uuid = String(parts[0])
            guard let display = DisplayManager.displays().first(where: { $0.uuid == uuid }) else { return }
            BrightnessManager.shared.setBrightness(percent, for: display)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Enforcer.shared.stop()
    }
}
