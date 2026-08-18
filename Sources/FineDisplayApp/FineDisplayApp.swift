import AppKit
import FineDisplayKit
import SwiftUI

@main
struct FineDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .help("FineDisplay")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !SkyLight_isAvailable() {
            let alert = NSAlert()
            alert.messageText = "FineDisplay cannot run on this macOS build"
            alert.informativeText = "The WindowServer functions it relies on did not resolve. Check nousworks.co/finedisplay for an update."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // Refreshed by AppState on every display reconfiguration and after each switch.
        let displays = state.displays
        Group {
            if displays.isEmpty {
                Text("No displays found")
            }
            ForEach(displays) { display in
                DisplaySection(display: display)
            }
            Divider()
            Button("Re-apply Saved Modes") { state.reapplyAll() }
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            Divider()
            Button("About FineDisplay…") { NSWorkspace.shared.open(FineDisplayInfo.website) }
            Button("Quit FineDisplay") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

struct DisplaySection: View {
    @EnvironmentObject private var state: AppState
    let display: Display

    var body: some View {
        let hidpi = display.presentableModes.filter { $0.isHiDPI }
        let lowres = display.presentableModes.filter { !$0.isHiDPI && $0.isListedBySystem }
        let saved = state.choice(for: display)
        let native = display.nativePixelSize

        Section {
            Text(header)
            if !hidpi.isEmpty {
                ForEach(hidpi) { mode in
                    modeButton(mode)
                }
            } else {
                Text("No HiDPI modes in this display's table").foregroundStyle(.secondary)
            }
            if !lowres.isEmpty {
                Menu("Low Resolution") {
                    ForEach(lowres) { mode in modeButton(mode) }
                }
            }
            if saved != nil {
                Button("Forget saved choice") { state.forget(display) }
            }
            if native.width > 0 {
                Text("Panel \(native.width)×\(native.height)  ·  \(display.unlockedModes.count) unlocked")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var header: String {
        display.isBuiltin ? "\(display.name) (built-in)" : display.name
    }

    @ViewBuilder
    private func modeButton(_ mode: DisplayMode) -> some View {
        let isCurrent = mode.modeNumber == display.currentModeNumber
        Button {
            state.select(mode, on: display)
        } label: {
            HStack {
                if isCurrent { Image(systemName: "checkmark") }
                Text(mode.label)
                Text("  \(mode.pixelWidth)×\(mode.pixelHeight)").foregroundStyle(.secondary)
                if mode.isHidden && mode.isHiDPI {
                    Text("  ★").foregroundStyle(.orange)
                }
            }
        }
    }
}
