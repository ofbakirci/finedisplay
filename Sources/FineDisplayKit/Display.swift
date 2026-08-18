import AppKit
import CoreGraphics
import Foundation

public enum FineDisplayError: LocalizedError {
    case skyLightUnavailable
    case displayNotFound
    case modeNotFound
    case configuration(CGError, String)

    public var errorDescription: String? {
        switch self {
        case .skyLightUnavailable:
            return "This macOS build does not expose the WindowServer functions FineDisplay needs."
        case .displayNotFound:
            return "Display not found."
        case .modeNotFound:
            return "No matching mode in the display's mode table."
        case let .configuration(code, step):
            return "Display configuration failed at \(step) (CGError \(code.rawValue))."
        }
    }
}

/// A connected display plus its full WindowServer mode table.
public struct Display: Identifiable, Hashable {
    public let id: CGDirectDisplayID
    public let uuid: String
    public let name: String
    public let isBuiltin: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let modes: [DisplayMode]
    public let currentModeNumber: Int32?

    public var currentMode: DisplayMode? {
        guard let n = currentModeNumber else { return nil }
        return modes.first { $0.modeNumber == n }
    }

    /// Physical panel size in pixels: the mode WindowServer flags as native, or else the
    /// largest 1× mode macOS lists.
    public var nativePixelSize: (width: Int, height: Int) {
        if let native = modes.first(where: { $0.isNative && !$0.isJunk }) {
            return (native.pixelWidth, native.pixelHeight)
        }
        let listed = modes.filter { $0.isListedBySystem && !$0.isHiDPI }
        let w = listed.map(\.pixelWidth).max() ?? 0
        let h = listed.map(\.pixelHeight).max() ?? 0
        return (w, h)
    }

    /// Modes worth showing to a person: valid, not junk, deduplicated by (w, h, density),
    /// keeping the highest refresh rate per group. Sorted big to small, HiDPI first.
    public var presentableModes: [DisplayMode] {
        var best: [String: DisplayMode] = [:]
        for m in modes where m.isValid && !m.isJunk {
            let key = "\(m.width)x\(m.height)@\(m.density)"
            if let existing = best[key] {
                if m.refreshRate > existing.refreshRate { best[key] = m }
            } else {
                best[key] = m
            }
        }
        return best.values.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.width != b.width { return a.width > b.width }
            return a.height > b.height
        }
    }

    /// The HiDPI modes macOS hides — the ones FineDisplay unlocks.
    public var unlockedModes: [DisplayMode] {
        presentableModes.filter { $0.isHiDPI && $0.isHidden }
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(uuid) }
    public static func == (a: Display, b: Display) -> Bool { a.uuid == b.uuid && a.currentModeNumber == b.currentModeNumber }
}

public enum DisplayManager {
    /// All online displays with their mode tables.
    public static func displays() -> [Display] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { display(for: $0) }
    }

    public static func display(for id: CGDirectDisplayID) -> Display {
        Display(
            id: id,
            uuid: uuidString(for: id),
            name: name(for: id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            modes: modes(for: id),
            currentModeNumber: currentModeNumber(for: id)
        )
    }

    public static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, cf) as String
    }

    public static func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    /// Full mode table straight from WindowServer, including entries the public API hides.
    public static func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
        guard let count = SkyLight.getNumberOfDisplayModes,
              let describe = SkyLight.getDisplayModeDescriptionOfLength else { return [] }
        var n: Int32 = 0
        guard count(id, &n) == .success, n > 0 else { return [] }
        var result: [DisplayMode] = []
        result.reserveCapacity(Int(n))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: SkyLight.modeDescriptionBufferSize, alignment: 16)
        defer { buf.deallocate() }
        for i in 0..<n {
            buf.initializeMemory(as: UInt8.self, repeating: 0, count: SkyLight.modeDescriptionBufferSize)
            guard describe(id, i, buf, SkyLight.modeDescriptionLength) == .success else { continue }
            result.append(DisplayMode(buffer: UnsafeRawBufferPointer(start: buf, count: SkyLight.modeDescriptionBufferSize)))
        }
        return result
    }

    public static func currentModeNumber(for id: CGDirectDisplayID) -> Int32? {
        guard let f = SkyLight.getCurrentDisplayMode else { return nil }
        var n: Int32 = -1
        return f(id, &n) == .success ? n : nil
    }

    /// Switches `display` to `mode`. `permanent` asks WindowServer to remember it in its own prefs.
    public static func apply(_ mode: DisplayMode, to id: CGDirectDisplayID, permanent: Bool = true) throws {
        guard let configure = SkyLight.configureDisplayMode else { throw FineDisplayError.skyLightUnavailable }
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config else { throw FineDisplayError.configuration(err, "begin") }
        err = configure(config, id, mode.modeNumber)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw FineDisplayError.configuration(err, "configure")
        }
        err = CGCompleteDisplayConfiguration(config, permanent ? .permanently : .forSession)
        guard err == .success else { throw FineDisplayError.configuration(err, "complete") }
    }

    /// Applies a saved choice if the display is not already in that mode. Returns the mode applied, or nil if nothing changed.
    @discardableResult
    public static func apply(choice: ModeChoice, to id: CGDirectDisplayID) throws -> DisplayMode? {
        let table = modes(for: id)
        guard let target = choice.match(in: table) else { throw FineDisplayError.modeNotFound }
        if let cur = currentModeNumber(for: id), cur == target.modeNumber { return nil }
        try apply(target, to: id)
        return target
    }
}
