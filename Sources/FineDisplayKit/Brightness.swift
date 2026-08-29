import CoreGraphics
import Foundation
import IOKit

/// Brightness control for displays.
///
/// Three backends, tried in order:
///  - Apple displays (built-in panel, Studio Display, …): private DisplayServices framework.
///  - External displays whose DDC/CI answers reads: DDC over the DCP AV service on
///    Apple Silicon (IOAVServiceWriteI2C / IOAVServiceReadI2C, VCP code 0x10).
///  - Everything else: software dimming — the display's gamma table is scaled down,
///    the same fallback BetterDisplay and Lunar use. Monitors that return the DDC null
///    message for every read (several Arzopa panels, see ddcutil issue #307) land here.
///
/// Software dimming lives in WindowServer but is tied to the setting process: it resets
/// when that process exits, on reconnect, and on mode changes. The menu bar app owns it
/// and re-applies it; the CLI delegates to the app via a distributed notification.
public final class BrightnessManager {
    public static let shared = BrightnessManager()

    /// Distributed notification the CLI posts; object is "displayUUID:percent".
    public static let setBrightnessNotification = "co.nousworks.finedisplay.setBrightness"

    public enum Capability {
        /// DisplayServices (Apple panel). Reads and writes work.
        case appleNative
        /// DDC/CI, verified by a successful read.
        case ddc
        /// Gamma-table scaling. Works everywhere, dims the image instead of the backlight.
        case software
        case unsupported
    }

    private struct Entry {
        var displayID: CGDirectDisplayID
        var capability: Capability
        var avService: CFTypeRef?
    }

    private var entries: [String: Entry] = [:]
    private let stateLock = NSLock()
    private let ddcQueue = DispatchQueue(label: "co.nousworks.finedisplay.ddc")
    private var pendingPercent: [String: Int] = [:]
    private var lastWrite: [String: Date] = [:]

    private init() {}

    // MARK: Public API

    public func capability(for display: Display) -> Capability {
        entry(for: display).capability
    }

    /// Current brightness 0–100, or nil when nothing can be read or recalled.
    public func brightness(for display: Display) -> Int? {
        let e = entry(for: display)
        switch e.capability {
        case .appleNative:
            guard let get = DisplayServicesBridge.getBrightness else { return nil }
            var v: Float = 0
            guard get(display.id, &v) == 0 else { return nil }
            return Int((v * 100).rounded())
        case .ddc:
            if let svc = e.avService, let r = DDC.read(service: svc, vcp: DDC.vcpBrightness) {
                return r.max > 0 ? Int((Double(r.current) / Double(r.max) * 100).rounded()) : r.current
            }
            return Preferences.shared.savedBrightness(for: display.uuid)
        case .software:
            return Preferences.shared.savedBrightness(for: display.uuid) ?? 100
        case .unsupported:
            return nil
        }
    }

    /// Sets brightness (0–100). DDC writes run on a serial queue and are throttled,
    /// so a dragging slider can call this at will.
    public func setBrightness(_ percent: Int, for display: Display) {
        let p = min(100, max(0, percent))
        let e = entry(for: display)
        switch e.capability {
        case .appleNative:
            guard let set = DisplayServicesBridge.setBrightness else { return }
            _ = set(display.id, Float(p) / 100)
            DisplayServicesBridge.brightnessChanged?(display.id, Double(p) / 100)
        case .ddc:
            guard let svc = e.avService else { return }
            let uuid = display.uuid
            stateLock.lock()
            pendingPercent[uuid] = p
            stateLock.unlock()
            ddcQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let target = self.pendingPercent[uuid]
                let last = self.lastWrite[uuid] ?? .distantPast
                // Coalesce a burst of slider events: skip unless this block carries the
                // newest value or enough time passed for a live intermediate update.
                let due = target == p || Date().timeIntervalSince(last) > 0.08
                if due { self.lastWrite[uuid] = Date() }
                self.stateLock.unlock()
                guard due, let value = target else { return }
                _ = DDC.write(service: svc, vcp: DDC.vcpBrightness, value: UInt16(value))
            }
            Preferences.shared.saveBrightness(p, for: display.uuid)
        case .software:
            SoftwareDimmer.apply(percent: p, to: display.id)
            Preferences.shared.saveBrightness(p, for: display.uuid)
        case .unsupported:
            break
        }
    }

    /// Re-applies saved software dimming. Call after launch, wake, reconnect, and mode
    /// changes — WindowServer resets the gamma table on all of those. Only meaningful
    /// inside a long-lived process (the menu bar app).
    public func reapplySoftwareDimming() {
        for display in DisplayManager.displays() {
            guard case .software = capability(for: display),
                  let saved = Preferences.shared.savedBrightness(for: display.uuid),
                  saved < 100 else { continue }
            SoftwareDimmer.apply(percent: saved, to: display.id)
        }
    }

    /// Drops cached services for displays that are gone; call when the display list changes.
    public func prune(current displays: [Display]) {
        let alive = Set(displays.map(\.uuid))
        stateLock.lock()
        entries = entries.filter { alive.contains($0.key) }
        stateLock.unlock()
    }

    // MARK: Capability probing

    private func entry(for display: Display) -> Entry {
        stateLock.lock()
        if let e = entries[display.uuid], e.displayID == display.id {
            stateLock.unlock()
            return e
        }
        stateLock.unlock()
        let e = probe(display)
        stateLock.lock()
        entries[display.uuid] = e
        stateLock.unlock()
        return e
    }

    private func probe(_ display: Display) -> Entry {
        if let can = DisplayServicesBridge.canChangeBrightness, can(display.id),
           display.isBuiltin || isAppleDisplay(display) {
            return Entry(displayID: display.id, capability: .appleNative, avService: nil)
        }
        if display.isBuiltin {
            return Entry(displayID: display.id, capability: .unsupported, avService: nil)
        }
        // DDC only counts when the monitor answers a read; monitors that null every
        // read (or have no AV service at all, e.g. on Intel) get software dimming.
        if let svc = DDC.avService(for: display), DDC.read(service: svc, vcp: DDC.vcpBrightness) != nil {
            return Entry(displayID: display.id, capability: .ddc, avService: svc)
        }
        return Entry(displayID: display.id, capability: .software, avService: nil)
    }

    private func isAppleDisplay(_ display: Display) -> Bool {
        display.vendor == 0x610 // Apple's EDID vendor id
    }
}

// MARK: - Software dimming (gamma scaling)

/// Scales the display's gamma table — the same fallback BetterDisplay and Lunar use for
/// monitors without working DDC. Dims the rendered image, not the backlight.
public enum SoftwareDimmer {
    /// 0% maps to this output scale instead of full black, so the screen stays readable.
    static let floor: Double = 0.08

    /// The ColorSync ramp as it was before we first touched a display, per display.
    /// Scaling this (instead of a synthetic linear ramp) keeps calibration profiles intact.
    private static var originals: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]
    private static let lock = NSLock()

    public static func apply(percent: Int, to id: CGDirectDisplayID) {
        guard let ramp = originalRamp(for: id) else { return }
        let p = Double(min(100, max(0, percent))) / 100
        let scale = CGGammaValue(floor + (1 - floor) * p)
        var r = ramp.r.map { $0 * scale }
        var g = ramp.g.map { $0 * scale }
        var b = ramp.b.map { $0 * scale }
        CGSetDisplayTransferByTable(id, UInt32(r.count), &r, &g, &b)
    }

    private static func originalRamp(for id: CGDirectDisplayID) -> (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = originals[id] { return cached }
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 0 else { return nil }
        let ramp = (r: Array(r.prefix(Int(count))), g: Array(g.prefix(Int(count))), b: Array(b.prefix(Int(count))))
        originals[id] = ramp
        return ramp
    }
}

// MARK: - DisplayServices (Apple panels)

enum DisplayServicesBridge {
    typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void
    typealias RegisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback?) -> Int32

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static let canChangeBrightness = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
    static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    static let setBrightness = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    static let brightnessChanged = symbol("DisplayServicesBrightnessChanged", as: ChangedFn.self)
    static let registerForBrightnessChange = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)
}

// MARK: - DDC/CI over the DCP AV service (Apple Silicon)

enum DDC {
    static let vcpBrightness: UInt8 = 0x10

    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // The IOAVService entry points live in IOKit itself; RTLD_DEFAULT finds them
        // because IOKit is linked. dlopen is the fallback for leaner link setups.
        if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(p, to: type) }
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static let createWithService = symbol("IOAVServiceCreateWithService", as: CreateFn.self)
    static let readI2C = symbol("IOAVServiceReadI2C", as: I2CFn.self)
    static let writeI2C = symbol("IOAVServiceWriteI2C", as: I2CFn.self)

    /// One external DCP AV service and what we know about the panel behind it.
    struct ExternalService {
        let service: CFTypeRef
        let vendor: UInt32?
        let model: UInt32?
    }

    /// Enumerates external DCPAVServiceProxy nodes. Vendor/model come from the
    /// "EDID UUID" property of the AppleCLCD2 / IOMobileFramebufferShim sibling that
    /// precedes each proxy in registry order; its first eight hex digits encode
    /// vendor (big-endian) and product (little-endian).
    static func externalServices() -> [ExternalService] {
        guard let create = createWithService else { return [] }
        var out: [ExternalService] = []
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var lastEdidUUID: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuf)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                lastEdidUUID = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                let ids = lastEdidUUID.flatMap(vendorModel(fromEdidUUID:))
                out.append(ExternalService(service: svc, vendor: ids?.vendor, model: ids?.model))
                lastEdidUUID = nil
            }
        }
        return out
    }

    /// "1EE46021-…" → vendor 0x1EE4, model 0x2160 (product bytes are little-endian).
    static func vendorModel(fromEdidUUID uuid: String) -> (vendor: UInt32, model: UInt32)? {
        let hex = uuid.prefix(8)
        guard hex.count == 8,
              let vendor = UInt32(hex.prefix(4), radix: 16),
              let modelLE = UInt32(hex.suffix(4), radix: 16) else { return nil }
        return (vendor, ((modelLE & 0xFF) << 8) | (modelLE >> 8))
    }

    /// Finds the AV service that belongs to `display`, matching by EDID vendor/model
    /// and falling back to enumeration order for unmatched leftovers.
    static func avService(for display: Display) -> CFTypeRef? {
        let services = externalServices()
        guard !services.isEmpty else { return nil }
        if let hit = services.first(where: { $0.vendor == display.vendor && $0.model == display.model }) {
            return hit.service
        }
        let externals = DisplayManager.displays().filter { !$0.isBuiltin }
        if services.count == 1 && externals.count == 1 { return services[0].service }
        if let i = externals.firstIndex(where: { $0.uuid == display.uuid }), i < services.count {
            return services[i].service
        }
        return nil
    }

    // MARK: Wire protocol

    static func checksum(seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Set VCP Feature. The monitor does not acknowledge; success means the I2C write went through.
    static func write(service: CFTypeRef, vcp: UInt8, value: UInt16) -> Bool {
        guard let writeI2C else { return false }
        var pkt: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        pkt[5] = checksum(seed: 0x6E ^ 0x51, pkt[0..<5])
        for attempt in 0..<3 {
            if attempt > 0 { usleep(10_000) }
            let ok = pkt.withUnsafeMutableBytes { writeI2C(service, 0x37, 0x51, $0.baseAddress!, 6) } == KERN_SUCCESS
            if ok { return true }
        }
        return false
    }

    /// Get VCP Feature. Returns nil for monitors that only send the DDC null message.
    static func read(service: CFTypeRef, vcp: UInt8) -> (current: Int, max: Int)? {
        guard let writeI2C, let readI2C else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { usleep(40_000) }
            var req: [UInt8] = [0x82, 0x01, vcp, 0]
            req[3] = checksum(seed: 0x6E ^ 0x51, req[0..<3])
            guard req.withUnsafeMutableBytes({ writeI2C(service, 0x37, 0x51, $0.baseAddress!, 4) }) == KERN_SUCCESS else { continue }
            usleep(20_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard reply.withUnsafeMutableBytes({ readI2C(service, 0x37, 0x51, $0.baseAddress!, 11) }) == KERN_SUCCESS else { continue }
            if let parsed = parseVCPReply(reply, vcp: vcp) { return parsed }
        }
        return nil
    }

    /// Reply layout: [src 0x6E, len|0x80, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk].
    static func parseVCPReply(_ reply: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        guard reply.count >= 11,
              reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp,
              checksum(seed: 0x50, reply[0..<10]) == reply[10] else { return nil }
        return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
    }
}
