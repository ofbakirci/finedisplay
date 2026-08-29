import AppKit
import FineDisplayKit
import Foundation

let usage = """
finedisplay — unlock the HiDPI modes macOS hides on external displays

USAGE
  finedisplay list [--all]          Show displays and modes (★ = hidden HiDPI mode FineDisplay unlocks)
  finedisplay set <display> <WxH> [--1x|--2x] [--hz N] [--no-save]
                                    Switch a display. <display> is the number from `list`, or a UUID prefix.
                                    Default is --2x (HiDPI). Saves the choice unless --no-save.
  finedisplay apply                 Re-apply all saved choices now
  finedisplay forget <display>      Remove the saved choice for a display
  finedisplay saved                 Show saved choices
  finedisplay brightness [<display>] [<0-100>|+N|-N]
                                    Show or set hardware brightness (DDC/CI on Apple Silicon,
                                    DisplayServices for Apple panels)
  finedisplay --version

EXAMPLES
  finedisplay set 2 1920x1200       # "looks like 1920×1200", rendered at 3840×2400
  finedisplay set 2 2048x1280 --hz 60
  finedisplay brightness 2 40       # external display to 40%
  finedisplay brightness 2 +10
"""

let version = FineDisplayInfo.version

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func findDisplay(_ token: String, in displays: [Display]) -> Display? {
    if let n = Int(token), n >= 1, n <= displays.count { return displays[n - 1] }
    let t = token.uppercased()
    return displays.first { $0.uuid.uppercased().hasPrefix(t) }
}

func parseSize(_ s: String) -> (Int, Int)? {
    let parts = s.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    return (w, h)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

guard SkyLight_isAvailable() else {
    fail("FineDisplay cannot reach WindowServer's mode table on this macOS build.")
}

switch command {
case "--version", "-v", "version":
    print("finedisplay \(version)")

case "list", "ls":
    let showAll = args.contains("--all")
    let displays = DisplayManager.displays()
    for (i, d) in displays.enumerated() {
        let native = d.nativePixelSize
        print("[\(i + 1)] \(d.name)\(d.isBuiltin ? " (built-in)" : "")  uuid \(d.uuid)")
        print("    vendor 0x\(String(d.vendor, radix: 16)) model 0x\(String(d.model, radix: 16))  panel \(native.width)×\(native.height) px")
        if let cur = d.currentMode {
            print("    current: \(cur.label)  (\(cur.detail))")
        }
        let modes = d.presentableModes.filter { showAll || $0.isHiDPI || $0.isListedBySystem }
        for m in modes {
            let mark = m.modeNumber == d.currentModeNumber ? "▶" : " "
            let star = m.isHidden && m.isHiDPI ? "★" : " "
            let sys = m.isListedBySystem ? " " : (m.isHidden ? "h" : "?")
            print("    \(mark) \(star)\(sys) #\(String(format: "%3d", m.modeNumber))  \(m.label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(m.detail)")
        }
        if !d.unlockedModes.isEmpty {
            print("    ★ = HiDPI mode macOS hides; FineDisplay can switch to it")
        }
        print()
    }

case "set":
    guard args.count >= 2, let (w, h) = parseSize(args[1]) else { fail(usage, code: 2) }
    let displays = DisplayManager.displays()
    guard let d = findDisplay(args[0], in: displays) else { fail("No such display: \(args[0])") }
    var density = 2.0
    var hz: Int? = nil
    var save = true
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--1x": density = 1
        case "--2x": density = 2
        case "--no-save": save = false
        case "--hz":
            i += 1
            guard i < args.count, let v = Int(args[i]) else { fail("--hz needs a number") }
            hz = v
        default: fail("Unknown option \(args[i])")
        }
        i += 1
    }
    let candidates = d.modes.filter { $0.isValid && !$0.isJunk && $0.width == w && $0.height == h && $0.density == density }
    guard !candidates.isEmpty else {
        let alt = d.modes.filter { $0.isValid && !$0.isJunk && $0.width == w && $0.height == h }
        if !alt.isEmpty {
            fail("\(w)x\(h) exists only at \(alt.map { "\($0.density == 2 ? "--2x" : "--1x")" }.joined(separator: ", ")) on \(d.name)")
        }
        fail("\(w)x\(h) is not in \(d.name)'s mode table. Run `finedisplay list --all`.")
    }
    let target = hz.flatMap { r in candidates.first { $0.refreshRate == r } } ?? candidates.max { $0.refreshRate < $1.refreshRate }!
    do {
        try DisplayManager.apply(target, to: d.id)
        if save { Preferences.shared.save(ModeChoice(target), for: d) }
        let after = DisplayManager.display(for: d.id)
        print("\(d.name): now \(after.currentMode?.label ?? "?") (\(after.currentMode?.detail ?? ""))\(save ? " — saved" : "")")
    } catch {
        fail("Failed: \(error.localizedDescription)")
    }

case "apply":
    for line in Enforcer.shared.enforceAll() { print(line) }

case "forget":
    guard let token = args.first else { fail(usage, code: 2) }
    let displays = DisplayManager.displays()
    if let d = findDisplay(token, in: displays) {
        Preferences.shared.forget(d.uuid)
        print("Forgot \(d.name)")
    } else if let key = Preferences.shared.choices.keys.first(where: { $0.uppercased().hasPrefix(token.uppercased()) }) {
        Preferences.shared.forget(key)
        print("Forgot \(key)")
    } else {
        fail("No such display: \(token)")
    }

case "saved":
    let names = Preferences.shared.displayNames
    let choices = Preferences.shared.choices
    if choices.isEmpty { print("No saved choices.") }
    for (uuid, c) in choices.sorted(by: { $0.key < $1.key }) {
        print("\(names[uuid] ?? "?")  \(uuid)  →  \(c.label) @ \(c.refreshRate) Hz")
    }

case "brightness", "br":
    let displays = DisplayManager.displays()
    func describe(_ d: Display) -> String {
        switch BrightnessManager.shared.capability(for: d) {
        case .appleNative:
            return BrightnessManager.shared.brightness(for: d).map { "\($0)%" } ?? "?"
        case .ddc:
            return BrightnessManager.shared.brightness(for: d).map { "\($0)% (DDC)" } ?? "? (DDC)"
        case .software:
            let saved = BrightnessManager.shared.brightness(for: d) ?? 100
            return "\(saved)% (software dimming; monitor has no working DDC)"
        case .unsupported:
            return "not controllable"
        }
    }
    if args.isEmpty {
        for (i, d) in displays.enumerated() {
            print("[\(i + 1)] \(d.name): \(describe(d))")
        }
        break
    }
    guard let d = findDisplay(args[0], in: displays) else { fail("No such display: \(args[0])") }
    guard args.count >= 2 else { print("\(d.name): \(describe(d))"); break }
    let arg = args[1]
    var target: Int
    if arg.hasPrefix("+") || arg.hasPrefix("-") {
        guard let delta = Int(arg) else { fail("Not a number: \(arg)") }
        let current = BrightnessManager.shared.brightness(for: d) ?? 50
        target = current + delta
    } else {
        guard let v = Int(arg) else { fail("Not a number: \(arg)") }
        target = v
    }
    target = min(100, max(0, target))
    switch BrightnessManager.shared.capability(for: d) {
    case .unsupported:
        fail("\(d.name): brightness is not controllable")
    case .software:
        // Gamma dimming dies with the process; the menu bar app must own it.
        Preferences.shared.saveBrightness(target, for: d.uuid)
        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: FineDisplayInfo.bundleIdentifier).isEmpty
        if appRunning {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(BrightnessManager.setBrightnessNotification),
                object: "\(d.uuid):\(target)", userInfo: nil, deliverImmediately: true)
            print("\(d.name): set to \(target)% (software dimming, applied by the FineDisplay app)")
        } else {
            print("\(d.name): saved \(target)%, but software dimming needs the FineDisplay app running. Open FineDisplay.app.")
        }
    case .appleNative, .ddc:
        BrightnessManager.shared.setBrightness(target, for: d)
        // DDC writes are queued; give the serial queue a moment before exiting.
        Thread.sleep(forTimeInterval: 0.15)
        if case .ddc = BrightnessManager.shared.capability(for: d) {
            Thread.sleep(forTimeInterval: 0.1)
            let readBack = BrightnessManager.shared.brightness(for: d)
            print("\(d.name): set to \(target)%\(readBack.map { ", monitor reports \($0)%" } ?? "")")
        } else {
            print("\(d.name): set to \(target)%")
        }
    }

case "help", "--help", "-h":
    print(usage)

default:
    fail(usage, code: 2)
}
