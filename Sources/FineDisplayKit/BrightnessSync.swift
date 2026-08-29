import CoreGraphics
import Foundation

/// Makes external displays follow the built-in panel's brightness — per display,
/// opt-in. Event-driven: DisplayServices posts "DisplayServicesBrightness" with the
/// new 0–1 value whenever the built-in brightness changes (keys, ambient sensor,
/// Control Center alike). Verified on macOS 15.
///
/// Only the menu bar app calls `start()`; the CLI just flips the preference and
/// notifies the app (gamma dimming has to live in a long-running process anyway).
public final class BrightnessSync {
    public static let shared = BrightnessSync()
    private var registeredIDs = Set<CGDirectDisplayID>()
    private init() {}

    /// Registers for built-in brightness changes. Idempotent and safe to call again —
    /// necessary, in fact: a clamshell launch has no built-in display online, so the
    /// app re-calls this whenever the display list changes and registration happens
    /// once the lid opens (or the panel comes back with a new ID).
    public func start() {
        guard let register = DisplayServicesBridge.registerForBrightnessChange else { return }
        for display in DisplayManager.displays() where display.isBuiltin && !registeredIDs.contains(display.id) {
            if register(display.id, display.id, brightnessChangedCallback) == 0 {
                registeredIDs.insert(display.id)
            }
        }
    }

    /// Pushes the built-in panel's current brightness to every synced external now.
    /// Used when sync is switched on and after wake/reconnect.
    public func applyNow() {
        guard let get = DisplayServicesBridge.getBrightness else { return }
        let displays = DisplayManager.displays()
        guard let builtin = displays.first(where: { $0.isBuiltin }) else { return }
        var v: Float = 0
        guard get(builtin.id, &v) == 0 else { return }
        apply(fraction: Double(v), displays: displays)
    }

    func apply(fraction: Double, displays: [Display]? = nil) {
        let percent = Int((fraction * 100).rounded())
        for d in (displays ?? DisplayManager.displays()) where !d.isBuiltin {
            guard Preferences.shared.syncEnabled(for: d.uuid) else { continue }
            BrightnessManager.shared.setBrightness(percent, for: d)
        }
    }
}

private let brightnessChangedCallback: CFNotificationCallback = { _, _, _, _, userInfo in
    guard let value = (userInfo as NSDictionary?)?["value"] as? Double else { return }
    DispatchQueue.main.async { BrightnessSync.shared.apply(fraction: value) }
}
