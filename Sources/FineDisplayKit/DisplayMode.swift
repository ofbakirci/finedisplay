import CoreGraphics
import Foundation

/// One entry of WindowServer's mode table for a display.
public struct DisplayMode: Hashable, Identifiable, Codable {
    /// IOKit-style mode flags (kDisplayMode*Flag). Only a few bits matter to us.
    public struct Flags: OptionSet, Hashable, Codable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let valid = Flags(rawValue: 0x0000_0001)
        public static let safe = Flags(rawValue: 0x0000_0002)
        public static let `default` = Flags(rawValue: 0x0000_0004)
        public static let alwaysShow = Flags(rawValue: 0x0000_0008)
        public static let neverShow = Flags(rawValue: 0x0000_0080)
        public static let validForMirroring = Flags(rawValue: 0x0020_0000)
        public static let validForHiRes = Flags(rawValue: 0x0080_0000)
        public static let native = Flags(rawValue: 0x0200_0000)
        /// Set on the duplicate low-resolution entries WindowServer keeps at the tail of the table.
        public static let duplicateLowRes = Flags(rawValue: 0x4000_0000)
    }

    public let modeNumber: Int32
    public let flags: Flags
    /// Logical ("looks like") size in points.
    public let width: Int
    public let height: Int
    /// Backing scale. 2 means HiDPI.
    public let density: Double
    public let refreshRate: Int
    public let depth: Int

    public var id: Int32 { modeNumber }

    public var pixelWidth: Int { Int((Double(width) * density).rounded()) }
    public var pixelHeight: Int { Int((Double(height) * density).rounded()) }

    public var isHiDPI: Bool { density >= 2 }
    public var isValid: Bool { flags.contains(.valid) }
    public var isNative: Bool { flags.contains(.native) }
    /// Duplicate/invalid entries WindowServer keeps at the tail of the table.
    public var isJunk: Bool { flags.contains(.duplicateLowRes) || !isValid }
    /// WindowServer built this mode but only advertises it for mirroring
    /// (kDisplayModeValidForMirroringFlag). This is the supersampled HiDPI family
    /// macOS hides on sub-4K external displays; the public API never returns it.
    public var isHidden: Bool { !isJunk && flags.contains(.validForMirroring) }
    /// macOS lists this mode itself (System Settings > Displays).
    public var isListedBySystem: Bool { !isJunk && !isHidden }

    public var label: String {
        let base = "\(width) × \(height)"
        return isHiDPI ? "\(base)  HiDPI" : base
    }

    public var detail: String {
        "\(pixelWidth)×\(pixelHeight) px @ \(refreshRate) Hz"
    }

    /// Reads a mode from the raw description buffer WindowServer fills in.
    /// Layout (validated on macOS 12–15): mode @0, flags @4, width @8, height @12,
    /// depth @16, bytesPerRow @20, freq(u16) @0xBE, density(float) @0xD0.
    init(buffer: UnsafeRawBufferPointer) {
        func u32(_ off: Int) -> UInt32 { buffer.load(fromByteOffset: off, as: UInt32.self) }
        modeNumber = Int32(bitPattern: u32(0))
        flags = Flags(rawValue: u32(4))
        width = Int(u32(8))
        height = Int(u32(12))
        depth = Int(u32(16))
        refreshRate = Int(buffer.load(fromByteOffset: 0xBE, as: UInt16.self))
        var d = Double(buffer.load(fromByteOffset: 0xD0, as: Float.self))
        if !(d.isFinite && d > 0) {
            // Fall back to bytesPerRow / (width * 4) when density is missing.
            let bpr = Double(u32(20))
            d = width > 0 ? max(1, (bpr / (Double(width) * 4)).rounded()) : 1
        }
        density = d
    }

    public init(modeNumber: Int32, flags: Flags, width: Int, height: Int, density: Double, refreshRate: Int, depth: Int = 8) {
        self.modeNumber = modeNumber
        self.flags = flags
        self.width = width
        self.height = height
        self.density = density
        self.refreshRate = refreshRate
        self.depth = depth
    }
}

/// What the user asked for on a display. Stored instead of a mode number because
/// numbers can shift between connections.
public struct ModeChoice: Hashable, Codable {
    public var width: Int
    public var height: Int
    public var density: Double
    public var refreshRate: Int

    public init(width: Int, height: Int, density: Double, refreshRate: Int) {
        self.width = width
        self.height = height
        self.density = density
        self.refreshRate = refreshRate
    }

    public init(_ mode: DisplayMode) {
        self.init(width: mode.width, height: mode.height, density: mode.density, refreshRate: mode.refreshRate)
    }

    public var label: String {
        let base = "\(width) × \(height)"
        return density >= 2 ? "\(base) HiDPI" : base
    }

    /// Picks the table entry that matches this choice. Refresh rate is a soft preference.
    public func match(in modes: [DisplayMode]) -> DisplayMode? {
        let same = modes.filter { $0.isValid && !$0.isJunk && $0.width == width && $0.height == height && $0.density == density }
        if let exact = same.first(where: { $0.refreshRate == refreshRate }) { return exact }
        return same.max(by: { $0.refreshRate < $1.refreshRate })
    }
}
