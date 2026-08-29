import XCTest
@testable import FineDisplayKit

final class DDCTests: XCTestCase {
    func testVendorModelFromEdidUUID() {
        // Real value from an Arzopa Z1RC: vendor 0x1EE4, product 0x2160 stored little-endian.
        let parsed = DDC.vendorModel(fromEdidUUID: "1EE46021-0000-0000-0E24-010380221578")
        XCTAssertEqual(parsed?.vendor, 0x1EE4)
        XCTAssertEqual(parsed?.model, 0x2160)
        XCTAssertNil(DDC.vendorModel(fromEdidUUID: "short"))
        XCTAssertNil(DDC.vendorModel(fromEdidUUID: "GGGG0000-0000-0000-0000-000000000000"))
    }

    func testRequestChecksumMatchesSpec() {
        // Get VCP request for 0x10: 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC.
        XCTAssertEqual(DDC.checksum(seed: 0x6E ^ 0x51, [0x82, 0x01, 0x10][0..<3]), 0xAC)
    }

    func testParsesWellFormedVCPReply() {
        // cur = 40, max = 100 for VCP 0x10.
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x28, 0x00]
        reply[10] = DDC.checksum(seed: 0x50, reply[0..<10])
        let parsed = DDC.parseVCPReply(reply, vcp: 0x10)
        XCTAssertEqual(parsed?.current, 40)
        XCTAssertEqual(parsed?.max, 100)
    }

    func testRejectsNullMessage() {
        // Exactly what a write-only monitor returns: 6E 80 BE repeated to fill the buffer.
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80, 0xBE, 0x6E, 0x80]
        XCTAssertNil(DDC.parseVCPReply(null, vcp: 0x10))
    }

    func testRejectsWrongVCPOrBadChecksum() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x28, 0x00]
        reply[10] = DDC.checksum(seed: 0x50, reply[0..<10])
        XCTAssertNil(DDC.parseVCPReply(reply, vcp: 0x12), "different VCP code")
        reply[10] ^= 0xFF
        XCTAssertNil(DDC.parseVCPReply(reply, vcp: 0x10), "corrupted checksum")
    }
}
