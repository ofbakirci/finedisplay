import AppKit
import FineDisplayKit
import ServiceManagement

/// Builds the status-bar menu from live WindowServer data every time it opens.
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    /// Payload for mode items.
    private final class ModeRef: NSObject {
        let displayID: CGDirectDisplayID
        let mode: DisplayMode
        init(_ d: CGDirectDisplayID, _ m: DisplayMode) { displayID = d; mode = m }
    }

    /// Slider that knows which display it dims.
    private final class BrightnessSlider: NSSlider {
        var display: Display?
    }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { rebuild() }
    }

    // MARK: Building

    func rebuild() {
        menu.removeAllItems()
        let displays = DisplayManager.displays()
        BrightnessManager.shared.prune(current: displays)
        let externals = displays.filter { !$0.isBuiltin }
        let builtins = displays.filter { $0.isBuiltin }

        if displays.isEmpty {
            menu.addItem(disabled("No displays found"))
        }
        if externals.isEmpty && !builtins.isEmpty {
            menu.addItem(disabled("No external display connected"))
        }
        // External displays inline — that is what FineDisplay is for.
        for display in externals {
            addSection(for: display, into: menu)
            menu.addItem(.separator())
        }
        // Built-in displays tucked into a submenu; macOS already lists their modes.
        for display in builtins {
            let sub = NSMenu(title: display.name)
            sub.autoenablesItems = false
            addSection(for: display, into: sub)
            let item = NSMenuItem(title: "\(display.name) (built-in)", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        if !builtins.isEmpty { menu.addItem(.separator()) }

        let reapply = NSMenuItem(title: "Re-apply Saved Modes", action: #selector(reapplyAll), keyEquivalent: "")
        reapply.target = self
        menu.addItem(reapply)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About FineDisplay \(FineDisplayInfo.version)…", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit FineDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addSection(for display: Display, into menu: NSMenu) {
        let header = disabled(display.name)
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(header)

        let hidpi = display.presentableModes.filter { $0.isHiDPI }
        let lowres = display.presentableModes.filter { !$0.isHiDPI && $0.isListedBySystem }

        if hidpi.isEmpty {
            menu.addItem(disabled("   No HiDPI modes in this display's table"))
        }
        for mode in hidpi {
            menu.addItem(modeItem(mode, display: display))
        }
        if !lowres.isEmpty {
            let sub = NSMenu(title: "Low Resolution")
            sub.autoenablesItems = false
            for mode in lowres { sub.addItem(modeItem(mode, display: display)) }
            let subItem = NSMenuItem(title: "Low Resolution", action: nil, keyEquivalent: "")
            subItem.submenu = sub
            menu.addItem(subItem)
        }
        if let item = brightnessItem(for: display) {
            menu.addItem(item)
        }
        if let saved = Preferences.shared.choice(for: display.uuid) {
            let forget = NSMenuItem(title: "Forget Saved Choice (\(saved.label))", action: #selector(forgetChoice(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = display.uuid
            menu.addItem(forget)
        }
        let native = display.nativePixelSize
        if native.width > 0 {
            let info = disabled("Panel \(native.width)×\(native.height) px · \(display.unlockedModes.count) unlocked by FineDisplay")
            info.attributedTitle = NSAttributedString(string: info.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            menu.addItem(info)
        }
    }

    private func modeItem(_ mode: DisplayMode, display: Display) -> NSMenuItem {
        let item = NSMenuItem(title: mode.label, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ModeRef(display.id, mode)
        item.state = mode.modeNumber == display.currentModeNumber ? .on : .off

        let title = NSMutableAttributedString(string: "\(mode.width) × \(mode.height)", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ])
        if mode.isHiDPI {
            title.append(NSAttributedString(string: "  HiDPI", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        title.append(NSAttributedString(string: "   \(mode.pixelWidth)×\(mode.pixelHeight)", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if mode.isHidden && mode.isHiDPI {
            title.append(NSAttributedString(string: "  ★", attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.systemOrange,
            ]))
        }
        item.attributedTitle = title
        item.toolTip = mode.isHidden
            ? "macOS generated this mode and hides it. FineDisplay can switch to it."
            : "Listed by macOS."
        return item
    }

    /// A slider row, or nil when the display's brightness cannot be controlled.
    private func brightnessItem(for display: Display) -> NSMenuItem? {
        let capability = BrightnessManager.shared.capability(for: display)
        if case .unsupported = capability { return nil }
        let percent = BrightnessManager.shared.brightness(for: display) ?? 50

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        container.autoresizingMask = [.width]

        // Fixed left edge; the slider stretches; the bright icon rides the right edge.
        let dim = NSImageView(frame: NSRect(x: 22, y: 6, width: 14, height: 14))
        dim.image = NSImage(systemSymbolName: "sun.min", accessibilityDescription: "Dim")
        dim.contentTintColor = .secondaryLabelColor

        let bright = NSImageView(frame: NSRect(x: 210, y: 5, width: 16, height: 16))
        bright.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Bright")
        bright.contentTintColor = .secondaryLabelColor
        bright.autoresizingMask = [.minXMargin]

        let slider = BrightnessSlider(frame: NSRect(x: 42, y: 3, width: 162, height: 20))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = Double(percent)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(brightnessChanged(_:))
        slider.display = display
        slider.autoresizingMask = [.width]

        container.addSubview(dim)
        container.addSubview(slider)
        container.addSubview(bright)

        let item = NSMenuItem(title: "Brightness: \(percent)%", action: nil, keyEquivalent: "")
        item.view = container
        switch capability {
        case .software:
            item.toolTip = "This monitor does not answer DDC/CI, so FineDisplay dims the image in software (like BetterDisplay's software dimming)."
        default:
            item.toolTip = "Hardware brightness"
        }
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ModeRef else { return }
        let display = DisplayManager.display(for: ref.displayID)
        do {
            try DisplayManager.apply(ref.mode, to: ref.displayID)
            Preferences.shared.save(ModeChoice(ref.mode), for: display)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not switch \(display.name)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let slider = sender as? BrightnessSlider, let display = slider.display else { return }
        BrightnessManager.shared.setBrightness(Int(slider.doubleValue.rounded()), for: display)
        slider.enclosingMenuItem?.title = "Brightness: \(Int(slider.doubleValue.rounded()))%"
    }

    @objc private func forgetChoice(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        Preferences.shared.forget(uuid)
    }

    @objc private func reapplyAll() {
        let report = Enforcer.shared.enforceAll()
        let alert = NSAlert()
        alert.messageText = "Saved modes re-applied"
        alert.informativeText = report.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openAbout() {
        NSWorkspace.shared.open(FineDisplayInfo.website)
    }

    // MARK: Debug dump

    func dump() -> String {
        rebuild()
        var out: [String] = []
        func walk(_ m: NSMenu, indent: String) {
            for item in m.items {
                if item.isSeparatorItem { out.append(indent + "────"); continue }
                var line = indent
                line += item.state == .on ? "✓ " : "  "
                line += item.title
                if !item.isEnabled { line += "  (disabled)" }
                out.append(line)
                if let sub = item.submenu { walk(sub, indent: indent + "    ") }
            }
        }
        walk(menu, indent: "")
        return out.joined(separator: "\n")
    }
}
