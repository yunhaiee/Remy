import XCTest
@testable import RemyCore

final class TransportStreamTests: XCTestCase {
    private func packet(pid: Int, start: Bool, continuity: Int, payload: [UInt8]) -> Data {
        precondition(payload.count <= 182)
        let adaptationLength = 183 - payload.count
        return Data([0x47, UInt8((pid >> 8) & 0x1f) | (start ? 0x40 : 0), UInt8(pid & 0xff), 0x30 | UInt8(continuity), UInt8(adaptationLength)]
            + Array(repeating: UInt8(0), count: adaptationLength) + payload)
    }
    private var pat: Data { packet(pid: 0, start: true, continuity: 0, payload: [0, 0, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xe1, 0, 0, 0, 0, 0]) }
    private var pmt: Data { packet(pid: 256, start: true, continuity: 0, payload: [0, 2, 0xb0, 18, 0, 1, 0xc1, 0, 0, 0xe1, 1, 0xf0, 0, 0x1b, 0xe1, 1, 0xf0, 0, 0, 0, 0, 0]) }
    private func pes(_ nal: [UInt8], counter: Int) -> Data {
        packet(pid: 257, start: true, continuity: counter, payload: [0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0] + nal)
    }
    func testDemuxAcrossArbitraryDatagramBoundaries() {
        let stream = pat + pmt + pes([0, 0, 0, 1, 0x65, 0x88], counter: 0) + pes([0, 0, 1, 0x41, 0x99], counter: 1)
        var demux = TransportStreamDemuxer(), frames: [Data] = []
        for start in stride(from: 0, to: stream.count, by: 137) { frames += demux.append(stream.subdata(in: start..<min(start + 137, stream.count))) }
        XCTAssertEqual(frames, [Data([0, 0, 0, 1, 0x65, 0x88])])
    }
    func testPacketLossDropsIncompleteFrameInsteadOfEmittingIt() {
        var demux = TransportStreamDemuxer()
        _ = demux.append(pat + pmt + pes([0, 0, 1, 0x65, 0x88], counter: 0))
        let frames = demux.append(pes([0, 0, 1, 0x41, 0x99], counter: 2))
        XCTAssertTrue(frames.isEmpty); XCTAssertEqual(demux.droppedPackets, 1)
    }
    func testAnnexBSplitsBothStartCodeLengthsAndRemovesPadding() {
        XCTAssertEqual(AnnexB.units(Data([0, 0, 0, 1, 0x67, 5, 0, 0, 1, 0x68, 6, 0, 0])), [Data([0x67, 5]), Data([0x68, 6])])
        XCTAssertTrue(AnnexB.units(Data([1, 2, 3])).isEmpty)
    }
    func testMalformedAndOversizedDatagramsAreBounded() {
        var demux = TransportStreamDemuxer()
        XCTAssertTrue(demux.append(Data(repeating: 0xff, count: 1024)).isEmpty)
        XCTAssertTrue(demux.append(Data(repeating: 0, count: 1_000_001)).isEmpty)
    }
}
