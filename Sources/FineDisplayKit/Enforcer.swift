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
            self?.scheduleAll(after: 4)
        }
        // Also cover the "app launched with displays already attached" case.
        scheduleAll(after: 1)
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
        guard let choice = Preferences.shared.choice(for: display.uuid) else {
            return "\(display.name): no saved choice"
        }
        do {
            if let applied = try DisplayManager.apply(choice: choice, to: displayID) {
                log.info("\(display.name, privacy: .public): applied \(applied.label, privacy: .public)")
                return "\(display.name): applied \(applied.label)"
            }
            return "\(display.name): already \(choice.label)"
        } catch {
            log.error("\(display.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return "\(display.name): \(error.localizedDescription)"
        }
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
        DispatchQueue.main.async { enforcer.schedule(displayID: display, after: 2.5) }
    } else if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
        // nothing to do; the choice stays saved for the next connection
    } else if flags.contains(.beginConfigurationFlag) {
        // ignore
    } else {
        // Mode/origin changes: refresh UI only.
        DispatchQueue.main.async { enforcer.onChange?() }
    }
}
