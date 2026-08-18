import XCTest
@testable import FineDisplayKit

final class DisplayModeTests: XCTestCase {
    private func buffer(mode: UInt32, flags: UInt32, w: UInt32, h: UInt32, bpr: UInt32, freq: UInt16, density: Float) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: SkyLight.modeDescriptionBufferSize)
        func put32(_ v: UInt32, at off: Int) { withUnsafeBytes(of: v.littleEndian) { for (i, x) in $0.enumerated() { b[off + i] = x } } }
        put32(mode, at: 0); put32(flags, at: 4); put32(w, at: 8); put32(h, at: 12); put32(8, at: 16); put32(bpr, at: 20)
        withUnsafeBytes(of: freq.littleEndian) { for (i, x) in $0.enumerated() { b[0xBE + i] = x } }
        withUnsafeBytes(of: density.bitPattern.littleEndian) { for (i, x) in $0.enumerated() { b[0xD0 + i] = x } }
        return b
    }

    func testParsesHiddenSupersampledMode() {
        // Real values seen for an Arzopa Z1RC on macOS 15.7: mode 31, flags 0x00200001, 1920x1200, density 2.
        let bytes = buffer(mode: 31, flags: 0x0020_0001, w: 1920, h: 1200, bpr: 15360, freq: 60, density: 2)
        let m = bytes.withUnsafeBytes { DisplayMode(buffer: $0) }
        XCTAssertEqual(m.modeNumber, 31)
        XCTAssertEqual(m.width, 1920)
        XCTAssertEqual(m.height, 1200)
        XCTAssertEqual(m.pixelWidth, 3840)
        XCTAssertEqual(m.pixelHeight, 2400)
        XCTAssertTrue(m.isHiDPI)
        XCTAssertTrue(m.isHidden)
        XCTAssertFalse(m.isListedBySystem)
        XCTAssertFalse(m.isJunk)
    }

    func testSystemListedNativeMode() {
        // As seen in WindowServer's table: native mode carries 0x02000001, no "safe" bit.
        let bytes = buffer(mode: 24, flags: 0x0200_0001, w: 2560, h: 1600, bpr: 10240, freq: 60, density: 1)
        let m = bytes.withUnsafeBytes { DisplayMode(buffer: $0) }
        XCTAssertTrue(m.isListedBySystem)
        XCTAssertTrue(m.isNative)
        XCTAssertFalse(m.isHidden)
    }

    func testBuiltInSupersampledModeIsListedNotHidden() {
        // MacBook Pro built-in: 1800x1169@2x has flags 0x1 and macOS lists it.
        let bytes = buffer(mode: 66, flags: 0x0000_0001, w: 1800, h: 1169, bpr: 14400, freq: 120, density: 2)
        let m = bytes.withUnsafeBytes { DisplayMode(buffer: $0) }
        XCTAssertTrue(m.isListedBySystem)
        XCTAssertFalse(m.isHidden)
        XCTAssertTrue(m.isHiDPI)
    }

    func testDuplicateLowResIsJunk() {
        let bytes = buffer(mode: 54, flags: 0x4000_0000, w: 1920, h: 1200, bpr: 7680, freq: 60, density: 1)
        let m = bytes.withUnsafeBytes { DisplayMode(buffer: $0) }
        XCTAssertTrue(m.isJunk)
    }

    func testDensityFallbackFromBytesPerRow() {
        let bytes = buffer(mode: 1, flags: 1, w: 1024, h: 640, bpr: 8192, freq: 60, density: 0)
        let m = bytes.withUnsafeBytes { DisplayMode(buffer: $0) }
        XCTAssertEqual(m.density, 2)
    }

    func testChoiceMatchingPrefersExactRefresh() {
        let a = DisplayMode(modeNumber: 1, flags: [.valid, .safe], width: 1920, height: 1200, density: 2, refreshRate: 60)
        let b = DisplayMode(modeNumber: 2, flags: [.valid, .safe], width: 1920, height: 1200, density: 2, refreshRate: 120)
        let c = DisplayMode(modeNumber: 3, flags: [.valid, .safe], width: 1920, height: 1200, density: 1, refreshRate: 60)
        let choice = ModeChoice(width: 1920, height: 1200, density: 2, refreshRate: 60)
        XCTAssertEqual(choice.match(in: [a, b, c])?.modeNumber, 1)
        let choice2 = ModeChoice(width: 1920, height: 1200, density: 2, refreshRate: 75)
        XCTAssertEqual(choice2.match(in: [a, b, c])?.modeNumber, 2, "falls back to highest refresh")
    }
}
