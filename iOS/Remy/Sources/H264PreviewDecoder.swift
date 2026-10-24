import Foundation
import VideoToolbox
import RemyCore

/// Native decoder for the H.264 elementary stream carried by GoPro preview MPEG-TS.
final class H264PreviewDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var needsKeyframe = true
    private var frameIndex: Int64 = 0

    deinit { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) } }

    func decode(_ annexB: Data) {
        let units = AnnexB.units(annexB)
        var changed = false
        for unit in units {
            guard let first = unit.first else { continue }
            if first & 0x1f == 7, unit != sps { sps = unit; changed = true }
            if first & 0x1f == 8, unit != pps { pps = unit; changed = true }
        }
        if changed { rebuildSession() }
        guard let session, let format else { return }
        let picture = units.filter { unit in
            guard let byte = unit.first else { return false }
            return [1, 5, 6, 9].contains(Int(byte & 0x1f))
        }
        let keyframe = picture.contains { ($0.first ?? 0) & 0x1f == 5 }
        guard picture.contains(where: { [1, 5].contains(Int(($0.first ?? 0) & 0x1f)) }), !needsKeyframe || keyframe else { return }
        var avcc = Data()
        for nal in picture {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copied = avcc.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return }
        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30), decodeTimeStamp: .invalid)
        frameIndex += 1
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        var info = VTDecodeInfoFlags()
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [], frameRefcon: nil, infoFlagsOut: &info)
        if result == noErr { needsKeyframe = false }
        else { needsKeyframe = true; onError?("H.264 decode status \(result). Waiting for a keyframe.") }
    }

    func lostPacket() { needsKeyframe = true }

    private func rebuildSession() {
        guard let sps, let pps else { return }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; needsKeyframe = true
        let result = sps.withUnsafeBytes { sp in pps.withUnsafeBytes { pp in
            let pointers = [sp.bindMemory(to: UInt8.self).baseAddress!, pp.bindMemory(to: UInt8.self).baseAddress!]
            let lengths = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: lengths,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } }
        guard result == noErr, let format else { onError?("Invalid H.264 parameter sets: \(result)"); return }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard let ref else { return }
            let decoder = Unmanaged<H264PreviewDecoder>.fromOpaque(ref).takeUnretainedValue()
            if status == noErr, let image { decoder.onFrame?(image) }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        if status == noErr, let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        else { onError?("Could not create the local video decoder: \(status)") }
    }
}
