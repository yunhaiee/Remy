import XCTest
@testable import RemyCore

final class GoProBLETests: XCTestCase {
    func testWifiAcknowledgementIsCommandSpecificAndDoesNotAcceptFailedStatus() throws {
        XCTAssertEqual(GoProBLEProtocol.enableWiFi, Data([3, 0x17, 1, 1]))
        XCTAssertEqual(try GoProBLEProtocol.wifiEnableAcknowledgement(Data([2, 0x17, 0])), true)
        XCTAssertEqual(try GoProBLEProtocol.wifiEnableAcknowledgement(Data([2, 0x17, 1])), false)
        XCTAssertNil(try GoProBLEProtocol.wifiEnableAcknowledgement(Data([2, 0x3c, 0])))
        XCTAssertThrowsError(try GoProBLEProtocol.wifiEnableAcknowledgement(Data([2, 0x17])))
    }
    func testCredentialDecodingRejectsInvalidOrOversizedValues() {
        XCTAssertEqual(GoProBLEProtocol.credentialText(Data("GoPro-test\0".utf8)), "GoPro-test")
        XCTAssertNil(GoProBLEProtocol.credentialText(Data([255, 254])))
        XCTAssertNil(GoProBLEProtocol.credentialText(Data("bad\nvalue".utf8)))
        XCTAssertNil(GoProBLEProtocol.credentialText(Data(repeating: 65, count: 129)))
    }
}
