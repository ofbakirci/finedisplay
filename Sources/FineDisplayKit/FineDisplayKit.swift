import Foundation

/// True when the private WindowServer entry points resolved on this macOS build.
public func SkyLight_isAvailable() -> Bool { SkyLight.isAvailable }

public enum FineDisplayInfo {
    public static let version = "1.2.0"
    public static let website = URL(string: "https://finedisplay.nousworks.co/")!
    public static let bundleIdentifier = "co.nousworks.finedisplay"
    /// Posted by the CLI after changing shared preferences so the running app reacts.
    public static let prefsChangedNotification = "co.nousworks.finedisplay.prefsChanged"

    /// True when `candidate` is a strictly newer semantic version than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
