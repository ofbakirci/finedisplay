import Foundation

/// True when the private WindowServer entry points resolved on this macOS build.
public func SkyLight_isAvailable() -> Bool { SkyLight.isAvailable }

public enum FineDisplayInfo {
    public static let version = "1.1.1"
    public static let website = URL(string: "https://finedisplay.nousworks.co/")!
    public static let bundleIdentifier = "co.nousworks.finedisplay"
}
