import XCTest
@testable import RemyCore

final class GoProWireTests: XCTestCase {
    func testDocumentedSerialAddressMapping() {
        XCTAssertEqual(GoProAddress.wired(serialSuffix: "207"), "172.22.107.51")
        XCTAssertEqual(GoProAddress.wired(serialSuffix: "001"), "172.20.101.51")
        XCTAssertEqual(GoProAddress.wired(serialSuffix: "999"), "172.29.199.51")
        for invalid in ["", "20", "0207", "2a7", "２０７"] { XCTAssertNil(GoProAddress.wired(serialSuffix: invalid)) }
        XCTAssertTrue(GoProAddress.isLocalIPv4("172.22.107.51"))
        for invalid in ["8.8.8.8", "localhost", "127.0.0.1", "10.5.5.999", "10.5.5.9/path"] { XCTAssertFalse(GoProAddress.isLocalIPv4(invalid)) }
    }
    func testFragmentedContentLengthReplyAndTruncation() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"error\":".utf8)
        XCTAssertNil(try GoProHTTP.body(in: partial))
        XCTAssertThrowsError(try GoProHTTP.body(in: partial, connectionClosed: true))
        var complete = partial; complete.append(Data("0}".utf8))
        XCTAssertEqual(try GoProHTTP.body(in: complete), Data("{\"error\":0}".utf8))
    }
    func testChunkedRepliesAndCameraFailures() throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        XCTAssertNil(try GoProHTTP.body(in: Data((head + "b\r\n{\"error\":0}").utf8)))
        XCTAssertEqual(try GoProHTTP.body(in: Data((head + "b\r\n{\"error\":0}\r\n0\r\n\r\n").utf8)), Data("{\"error\":0}".utf8))
        XCTAssertThrowsError(try GoProHTTP.body(in: Data("HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertThrowsError(try GoProHTTP.body(in: Data(repeating: 0, count: GoProHTTP.limit + 1)))
    }
}
