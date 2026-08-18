import AppKit
import Combine
import FineDisplayKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var displays: [Display] = []
    @Published var lastMessage: String = ""
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var refreshWork: DispatchWorkItem?

    init() {
        refresh()
        Enforcer.shared.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        Enforcer.shared.start()
    }

    func refresh() {
        displays = DisplayManager.displays()
    }

    func scheduleRefresh() {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func choice(for display: Display) -> ModeChoice? {
        Preferences.shared.choice(for: display.uuid)
    }

    func select(_ mode: DisplayMode, on display: Display) {
        do {
            try DisplayManager.apply(mode, to: display.id)
            Preferences.shared.save(ModeChoice(mode), for: display)
            lastMessage = "\(display.name): \(mode.label)"
        } catch {
            lastMessage = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Could not switch \(display.name)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        scheduleRefresh()
    }

    func forget(_ display: Display) {
        Preferences.shared.forget(display.uuid)
        lastMessage = "\(display.name): choice forgotten"
        scheduleRefresh()
    }

    func reapplyAll() {
        let report = Enforcer.shared.enforceAll()
        lastMessage = report.joined(separator: " · ")
        scheduleRefresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastMessage = "Login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
