import AppKit
import FineDisplayKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: MenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SkyLight_isAvailable() else {
            let alert = NSAlert()
            alert.messageText = "FineDisplay cannot run on this macOS build"
            alert.informativeText = "The WindowServer functions it relies on did not resolve. Check nousworks.co/finedisplay for an update."
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
            // Nothing to redraw while closed; the menu rebuilds on open.
            _ = self
        }
        Enforcer.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Enforcer.shared.stop()
    }
}
