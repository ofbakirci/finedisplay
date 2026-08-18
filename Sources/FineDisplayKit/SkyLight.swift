import CoreGraphics
import Foundation

/// Runtime bridge to the private SkyLight (WindowServer client) functions we need.
/// Symbols are resolved with dlsym so the app still launches if Apple renames one;
/// callers get `nil` and can degrade gracefully.
enum SkyLight {
    typealias GetNumberOfDisplayModesFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    typealias GetDisplayModeDescriptionOfLengthFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError
    typealias GetCurrentDisplayModeFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    typealias ConfigureDisplayModeFn = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static let getNumberOfDisplayModes = symbol("CGSGetNumberOfDisplayModes", as: GetNumberOfDisplayModesFn.self)
    static let getDisplayModeDescriptionOfLength = symbol("CGSGetDisplayModeDescriptionOfLength", as: GetDisplayModeDescriptionOfLengthFn.self)
    static let getCurrentDisplayMode = symbol("CGSGetCurrentDisplayMode", as: GetCurrentDisplayModeFn.self)
    static let configureDisplayMode = symbol("CGSConfigureDisplayMode", as: ConfigureDisplayModeFn.self)

    /// True when every symbol we depend on resolved.
    static var isAvailable: Bool {
        getNumberOfDisplayModes != nil
            && getDisplayModeDescriptionOfLength != nil
            && getCurrentDisplayMode != nil
            && configureDisplayMode != nil
    }

    /// Size of the mode description struct WindowServer fills in (same value displayplacer uses).
    static let modeDescriptionLength: Int32 = 0xD4
    static let modeDescriptionBufferSize = 0xDC
}
