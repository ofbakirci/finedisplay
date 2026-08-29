import AppKit
import CoreGraphics
import Foundation
import os

/// Re-applies saved choices when a display (re)connects or the Mac wakes.
/// WindowServer sometimes restores a hidden mode on its own; when it does not, we do.
public final class Enforcer {
    public static let shared = Enforcer()

    private let log = Logger(subsystem: Preferences.suiteName, category: "enforcer")
    private var pending: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var snapshotPending: DispatchWorkItem?
    /// Origin changes before this moment are connection turbulence (replug, wake,
    /// macOS restoring a guess), not the user rearranging — don't snapshot them.
    private var settleUntil = Date.distantPast
    /// Called after every enforcement pass (for UI refresh).
    public var onChange: (() -> Void)?

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.log.info("wake: scheduling enforcement for all displays")
            self?.holdSnapshots(for: 15)
            self?.scheduleAll(after: 4)
        }
        // Also cover the "app launched with displays already attached" case.
        scheduleAll(after: 1)
        // Seed the arrangement snapshot from the current state — through the guarded
        // path, so a connect event during startup (login-item + dock) suppresses it
        // and the previous session's saved arrangement survives to be enforced.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scheduleOriginSnapshot() }
    }

    public func stop() {
        guard started else { return }
        started = false
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Applies every saved choice now. Returns a short report per display.
    @discardableResult
    public func enforceAll() -> [String] {
        var report: [String] = []
        for d in DisplayManager.displays() {
            report.append(enforce(displayID: d.id))
        }
        onChange?()
        return report
    }

    @discardableResult
    public func enforce(displayID: CGDirectDisplayID) -> String {
        let display = DisplayManager.display(for: displayID)
        var result: String
        do {
            if let choice = Preferences.shared.choice(for: display.uuid) {
                if let applied = try DisplayManager.apply(choice: choice, to: displayID) {
                    log.info("\(display.name, privacy: .public): applied \(applied.label, privacy: .public)")
                    result = "\(display.name): applied \(applied.label)"
                } else {
                    result = "\(display.name): already \(choice.label)"
                }
            } else {
                result = "\(display.name): no saved choice"
            }
        } catch {
            log.error("\(display.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            result = "\(display.name): \(error.localizedDescription)"
        }
        // Arrangement after mode: the mode switch changes logical sizes, and macOS may
        // have displaced *other* displays in the same event, so restore all of them.
        if let moved = enforceOrigins() { result += " (\(moved))" }
        return result
    }

    // MARK: Display arrangement

    /// Where every online display sits right now, merged over what is already saved
    /// (disconnected displays keep their last known position).
    private func currentOrigins() -> [String: [Int]] {
        var origins = Preferences.shared.displayOrigins
        for d in DisplayManager.displays() {
            let b = CGDisplayBounds(d.id)
            origins[d.uuid] = [Int(b.origin.x), Int(b.origin.y)]
        }
        return origins
    }

    /// Puts every online display back at its saved desktop position, in one
    /// transaction — macOS displaces neighbours too, not just the replugged display.
    /// Returns a note when something moved.
    private func enforceOrigins() -> String? {
        let displays = DisplayManager.displays()
        guard displays.count > 1 else { return nil }
        let saved = Preferences.shared.displayOrigins
        var moves: [(Display, Int32, Int32)] = []
        for d in displays {
            guard let s = saved[d.uuid], s.count == 2,
                  let x = Int32(exactly: s[0]), let y = Int32(exactly: s[1]) else { continue }
            let current = CGDisplayBounds(d.id).origin
            if Int(current.x) != s[0] || Int(current.y) != s[1] { moves.append((d, x, y)) }
        }
        guard !moves.isEmpty else { return nil }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return nil }
        for (d, x, y) in moves { CGConfigureDisplayOrigin(config, d.id, x, y) }
        let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            log.error("arrangement restore refused by WindowServer (CGError \(completeErr.rawValue, privacy: .public))")
            return nil
        }
        let notes = moves.map { d, x, y -> String in
            // CG may normalize the requested position; report where it actually landed.
            let b = CGDisplayBounds(d.id)
            return "\(d.name) → (\(Int(b.origin.x)), \(Int(b.origin.y)))"
        }
        let note = "arrangement restored: \(notes.joined(separator: ", "))"
        log.info("\(note, privacy: .public)")
        return note
    }

    fileprivate func holdSnapshots(for seconds: Double) {
        settleUntil = max(settleUntil, Date().addingTimeInterval(seconds))
    }

    /// Debounced, turbulence-proof arrangement snapshot. The decision AND the data both
    /// come from the event moment: an event inside the settle window is turbulence and
    /// is dropped; a legitimate event's origins are captured immediately, so a lid close
    /// or unplug during the debounce cannot corrupt or discard what the user just did.
    fileprivate func scheduleOriginSnapshot() {
        guard Date() > settleUntil, DisplayManager.displays().count > 1 else { return }
        let captured = currentOrigins()
        snapshotPending?.cancel()
        let item = DispatchWorkItem {
            Preferences.shared.displayOrigins = captured
        }
        snapshotPending = item
        // Debounced so a drag in System Settings' arrangement view settles first;
        // every further event replaces the capture with the newer positions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    fileprivate func schedule(displayID: CGDirectDisplayID, after seconds: Double) {
        pending[displayID]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[displayID] = nil
            _ = self.enforce(displayID: displayID)
            self.onChange?()
        }
        pending[displayID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func scheduleAll(after seconds: Double) {
        for d in DisplayManager.displays() { schedule(displayID: d.id, after: seconds) }
    }
}

private func reconfigurationCallback(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let enforcer = Unmanaged<Enforcer>.fromOpaque(userInfo).takeUnretainedValue()
    // Only react to connection-type events. A plain mode change is the user's business.
    if flags.contains(.addFlag) || flags.contains(.enabledFlag) {
        DispatchQueue.main.async {
            enforcer.holdSnapshots(for: 15)
            enforcer.schedule(displayID: display, after: 2.5)
        }
    } else if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
        // The choice stays saved for the next connection. Remaining displays may get
        // shuffled by macOS right now — don't record that as the user's arrangement.
        DispatchQueue.main.async { enforcer.holdSnapshots(for: 15) }
    } else if flags.contains(.beginConfigurationFlag) {
        // ignore
    } else {
        // Mode/origin changes outside a connection window are the user's doing:
        // remember the arrangement, then refresh UI.
        DispatchQueue.main.async {
            enforcer.scheduleOriginSnapshot()
            enforcer.onChange?()
        }
    }
}
