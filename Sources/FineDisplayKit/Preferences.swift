import Foundation

/// Saved mode choices, keyed by display UUID. Shared by the app and the CLI.
public final class Preferences {
    public static let suiteName = "co.nousworks.finedisplay.prefs"
    public static let shared = Preferences()

    private let defaults: UserDefaults
    private let choicesKey = "choices"
    private let namesKey = "displayNames"
    private let brightnessKey = "brightness"
    private let syncKey = "brightnessSync"
    private let originsKey = "displayOrigins"

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Preferences.suiteName) ?? .standard
    }

    public var choices: [String: ModeChoice] {
        get {
            guard let data = defaults.data(forKey: choicesKey),
                  let dict = try? JSONDecoder().decode([String: ModeChoice].self, from: data) else { return [:] }
            return dict
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: choicesKey)
        }
    }

    /// Human names for saved displays, so the CLI/app can show them even when disconnected.
    public var displayNames: [String: String] {
        get { defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: namesKey) }
    }

    public func choice(for uuid: String) -> ModeChoice? { choices[uuid] }

    public func save(_ choice: ModeChoice, for display: Display) {
        var c = choices
        c[display.uuid] = choice
        choices = c
        var n = displayNames
        n[display.uuid] = display.name
        displayNames = n
    }

    /// Last brightness set over DDC, keyed by display UUID. Seeds the slider for
    /// monitors that accept DDC writes but never answer reads.
    public func savedBrightness(for uuid: String) -> Int? {
        (defaults.dictionary(forKey: brightnessKey) as? [String: Int])?[uuid]
    }

    public func saveBrightness(_ percent: Int, for uuid: String) {
        var d = defaults.dictionary(forKey: brightnessKey) as? [String: Int] ?? [:]
        d[uuid] = percent
        defaults.set(d, forKey: brightnessKey)
    }

    /// Whether the display follows the built-in panel's brightness.
    public func syncEnabled(for uuid: String) -> Bool {
        (defaults.dictionary(forKey: syncKey) as? [String: Bool])?[uuid] ?? false
    }

    public func setSyncEnabled(_ on: Bool, for uuid: String) {
        var d = defaults.dictionary(forKey: syncKey) as? [String: Bool] ?? [:]
        d[uuid] = on
        defaults.set(d, forKey: syncKey)
    }

    /// Last known desktop position per display, as [x, y]. macOS occasionally forgets
    /// the arrangement after sleep or replug; the Enforcer puts it back.
    public var displayOrigins: [String: [Int]] {
        get { defaults.dictionary(forKey: originsKey) as? [String: [Int]] ?? [:] }
        set { defaults.set(newValue, forKey: originsKey) }
    }

    public func forget(_ uuid: String) {
        var c = choices
        c.removeValue(forKey: uuid)
        choices = c
        var n = displayNames
        n.removeValue(forKey: uuid)
        displayNames = n
        var b = defaults.dictionary(forKey: brightnessKey) as? [String: Int] ?? [:]
        b.removeValue(forKey: uuid)
        defaults.set(b, forKey: brightnessKey)
        var s = defaults.dictionary(forKey: syncKey) as? [String: Bool] ?? [:]
        s.removeValue(forKey: uuid)
        defaults.set(s, forKey: syncKey)
        var o = displayOrigins
        o.removeValue(forKey: uuid)
        displayOrigins = o
    }
}
