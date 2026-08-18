import Foundation

/// Saved mode choices, keyed by display UUID. Shared by the app and the CLI.
public final class Preferences {
    public static let suiteName = "co.nousworks.finedisplay.prefs"
    public static let shared = Preferences()

    private let defaults: UserDefaults
    private let choicesKey = "choices"
    private let namesKey = "displayNames"

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

    public func forget(_ uuid: String) {
        var c = choices
        c.removeValue(forKey: uuid)
        choices = c
        var n = displayNames
        n.removeValue(forKey: uuid)
        displayNames = n
    }
}
