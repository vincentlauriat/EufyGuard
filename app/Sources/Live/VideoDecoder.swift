import Foundation
import CoreMedia

/// Parses a raw H.264 / H.265 Annex-B elementary stream (as relayed by the
/// bridge from the Eufy P2P stream) into CMSampleBuffers ready for
/// AVSampleBufferDisplayLayer. Decoding itself is done in hardware by the layer.
final class NALUStreamDecoder {
    enum Codec { case h264, h265 }

    var codec: Codec = .h264 {
        didSet { if codec != oldValue { reset() } }
    }
    var onSample: ((CMSampleBuffer) -> Void)?

    private var buffer = Data()
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var formatDescription: CMVideoFormatDescription?

    func reset() {
        buffer.removeAll()
        sps = nil; pps = nil; vps = nil
        formatDescription = nil
    }

    func append(_ data: Data) {
        buffer.append(data)
        parseBuffer()
        // Safety valve: never let a corrupt stream grow the buffer unbounded.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    // MARK: - Annex-B parsing

    private func parseBuffer() {
        let bytes = [UInt8](buffer)
        // Positions of start codes: (index of first 0x00, payload start index)
        var startCodes: [(pos: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    startCodes.append((i, i + 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    startCodes.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        guard startCodes.count >= 2 else { return }

        for k in 0..<(startCodes.count - 1) {
            let payloadStart = startCodes[k].payload
            let payloadEnd = startCodes[k + 1].pos
            if payloadEnd > payloadStart {
                handleNAL(Data(bytes[payloadStart..<payloadEnd]))
            }
        }
        // Keep the (possibly incomplete) last NAL for the next append.
        buffer = Data(bytes[startCodes[startCodes.count - 1].pos...])
    }

    private func handleNAL(_ nal: Data) {
        guard let first = nal.first else { return }
        switch codec {
        case .h264:
            switch first & 0x1F {
            case 7: sps = nal; formatDescription = nil
            case 8: pps = nal; formatDescription = nil
            case 1, 5: emitFrame(nal)
            default: break
            }
        case .h265:
            switch (first >> 1) & 0x3F {
            case 32: vps = nal; formatDescription = nil
            case 33: sps = nal; formatDescription = nil
            case 34: pps = nal; formatDescription = nil
            case 0...31: emitFrame(nal) // VCL NAL units
            default: break
            }
        }
    }

    // MARK: - Sample buffer construction

    private func emitFrame(_ nal: Data) {
        guard let format = ensureFormatDescription(),
              let sample = makeSampleBuffer(nal: nal, format: format) else { return }
        onSample?(sample)
    }

    private func ensureFormatDescription() -> CMVideoFormatDescription? {
        if let formatDescription { return formatDescription }
        switch codec {
        case .h264:
            guard let sps, let pps else { return nil }
            formatDescription = Self.makeFormat(parameterSets: [sps, pps], hevc: false)
        case .h265:
            guard let vps, let sps, let pps else { return nil }
            formatDescription = Self.makeFormat(parameterSets: [vps, sps, pps], hevc: true)
        }
        return formatDescription
    }

    private static func makeFormat(parameterSets: [Data], hevc: Bool) -> CMVideoFormatDescription? {
        let sets = parameterSets.map { [UInt8]($0) }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        // Keep the arrays alive while creating the description.
        return sets.withUnsafeBufferPointer { _ -> CMVideoFormatDescription? in
            for set in sets {
                set.withUnsafeBufferPointer { ptr in
                    pointers.append(ptr.baseAddress!)
                    sizes.append(set.count)
                }
            }
            var format: CMVideoFormatDescription?
            let status: OSStatus
            if hevc {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            } else {
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
            return status == noErr ? format : nil
        }
    }

    private func makeSampleBuffer(nal: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // Convert Annex-B NAL to AVCC/HVCC framing: 4-byte big-endian length prefix.
        var payload = Data(capacity: nal.count + 4)
        var bigLength = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &bigLength) { payload.append(contentsOf: $0) }
        payload.append(nal)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        let copyStatus = payload.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sampleBuffer = sample else { return nil }

        // Live stream: display frames as soon as they are decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
