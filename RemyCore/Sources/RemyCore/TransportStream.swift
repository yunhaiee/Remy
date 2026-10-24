import Foundation

/// Bounded, single-program MPEG-TS H.264 demuxer for GoPro preview. No network or codec dependencies.
/// PSI sections must fit a packet (as in the GoPro preview); unknown/fragmented tables are ignored.
public struct TransportStreamDemuxer: Sendable {
    private var pending = [UInt8]()
    private var pmtPID: Int?
    private var videoPID: Int?
    private var video = [UInt8]()
    private var collecting = false
    private var lastContinuity: Int?
    public private(set) var droppedPackets = 0
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        guard data.count <= 1_000_000 else { return [] }
        pending.append(contentsOf: data)
        var output: [Data] = [], cursor = 0
        while pending.count - cursor >= 188 {
            guard pending[cursor] == 0x47 else { cursor += 1; continue }
            if pending.count - cursor >= 376, pending[cursor + 188] != 0x47 { cursor += 1; continue }
            let packet = Array(pending[cursor..<(cursor + 188)])
            cursor += 188
            if let result = consume(packet), !result.isEmpty { output.append(Data(result)) }
        }
        if cursor > 0 { pending.removeFirst(cursor) }
        if pending.count > 376 { pending.removeAll(); droppedPackets += 1 }
        return output
    }

    private mutating func consume(_ p: [UInt8]) -> [UInt8]? {
        let pid = Int(p[1] & 0x1f) << 8 | Int(p[2])
        let start = p[1] & 0x40 != 0
        let control = (p[3] >> 4) & 3
        guard p[1] & 0x80 == 0, p[3] & 0xc0 == 0, control == 1 || control == 3 else { return nil }
        var offset = 4
        if control == 3 { offset += 1 + Int(p[4]) }
        guard offset < 188 else { return nil }
        if pid == 0 || pid == pmtPID {
            guard start else { return nil }
            offset += 1 + Int(p[offset])
            guard offset + 3 <= 188 else { return nil }
            let length = Int(p[offset + 1] & 0x0f) << 8 | Int(p[offset + 2])
            let end = offset + 3 + length - 4 // ignore CRC bytes, but bound every table read
            guard length >= 4, end <= 184, end > offset else { return nil }
            if pid == 0, p[offset] == 0, offset + 8 <= end {
                var index = offset + 8
                while index + 4 <= end {
                    if p[index] != 0 || p[index + 1] != 0 {
                        pmtPID = Int(p[index + 2] & 0x1f) << 8 | Int(p[index + 3]); break
                    }
                    index += 4
                }
            } else if pid == pmtPID, p[offset] == 2, offset + 12 <= end {
                var index = offset + 12 + (Int(p[offset + 10] & 0x0f) << 8 | Int(p[offset + 11]))
                while index + 5 <= end {
                    let elementaryPID = Int(p[index + 1] & 0x1f) << 8 | Int(p[index + 2])
                    if p[index] == 0x1b { videoPID = elementaryPID; break }
                    index += 5 + (Int(p[index + 3] & 0x0f) << 8 | Int(p[index + 4]))
                }
            }
            return nil
        }
        guard pid == videoPID else { return nil }
        let continuity = Int(p[3] & 0x0f)
        if let lastContinuity {
            if continuity == lastContinuity { return nil }
            if continuity != (lastContinuity + 1) % 16 {
                video.removeAll(); collecting = false; droppedPackets += 1
            }
        }
        lastContinuity = continuity
        var completed: [UInt8]?
        if start {
            if collecting { completed = video }
            video.removeAll(keepingCapacity: true); collecting = false
            guard offset + 9 <= 188, p[offset...offset + 2].elementsEqual([0, 0, 1]),
                  (0xe0...0xef).contains(p[offset + 3]) else { return completed }
            offset += 9 + Int(p[offset + 8])
            guard offset <= 188 else { return completed }
            collecting = true
        }
        if collecting {
            video.append(contentsOf: p[offset..<188])
            if video.count > 2_000_000 { video.removeAll(); collecting = false; droppedPackets += 1 }
        }
        return completed
    }
}

public enum AnnexB {
    public static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 4 <= bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            var end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            while end > start.1 && bytes[end - 1] == 0 { end -= 1 }
            return end > start.1 ? Data(bytes[start.1..<end]) : nil
        }
    }
}
