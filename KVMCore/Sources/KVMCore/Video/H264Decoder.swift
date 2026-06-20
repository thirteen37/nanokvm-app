@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import VideoToolbox
import Foundation

public enum H264DecoderError: Error, LocalizedError {
    case formatDescription(OSStatus)
    case decompressionSession(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .formatDescription(let status): return "Could not create H.264 format description (\(status))."
        case .decompressionSession(let status): return "Could not create H.264 decoder session (\(status))."
        case .blockBuffer(let status): return "Could not create H.264 block buffer (\(status))."
        case .sampleBuffer(let status): return "Could not create H.264 sample buffer (\(status))."
        case .decode(let status): return "VideoToolbox failed to decode H.264 frame (\(status))."
        }
    }
}

private let invalidParameterStatus = OSStatus(-50)

/// An optional correction applied during H.264 decode to fix mismatched color
/// signaling.
///
/// The GLKVM's PiKVM/uStreamer-style V4L2 encoder emits genuine **studio/limited
/// range** luma (black ≈ 16, white ≈ 235) flagged `video_full_range_flag = 0`.
/// On this display path the limited→full expansion is not applied at render time,
/// so white (235) shows at 92% and black (16) at 6% — milky blacks, dim whites.
///
/// VideoToolbox does not rescale this stream (forcing a full-range output buffer
/// only relabels it), so the fix is to tag the decoded buffer explicitly as
/// limited-range BT.709 (`signaledFullRange = false` plus the matrix/primaries/
/// transfer) and route it through `FullRangeVideoExpander`
/// (`expandToFullRangeForDisplay = true`), which uses Core Image to perform the
/// studio→full expansion in float on the GPU. `nil` (the default, used by
/// NanoKVM) leaves the SPS-derived description and the video-range output
/// untouched.
public struct H264ColorOverride: Sendable {
    /// Stamps `kCMFormatDescriptionExtension_FullRangeVideo` on the format
    /// description, i.e. the input range VideoToolbox assumes when scaling.
    /// `false` = limited/video range. `nil` leaves whatever the SPS signaled.
    public var signaledFullRange: Bool?
    /// Forces `kCMFormatDescriptionExtension_YCbCrMatrix`, e.g. `kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2`.
    public var ycbcrMatrix: CFString?
    /// Forces `kCMFormatDescriptionExtension_ColorPrimaries`, e.g. `kCMFormatDescriptionColorPrimaries_ITU_R_709_2`.
    public var colorPrimaries: CFString?
    /// Forces `kCMFormatDescriptionExtension_TransferFunction`, e.g. `kCMFormatDescriptionTransferFunction_ITU_R_709_2`.
    public var transferFunction: CFString?
    /// When `true`, each decoded frame is routed through `FullRangeVideoExpander`,
    /// which uses Core Image to expand the studio-range YCbCr to full-range RGB for
    /// display. Needed because this display path renders YCbCr as full-range
    /// identity and never applies the studio→full expansion itself.
    public var expandToFullRangeForDisplay: Bool
    /// The studio luma level mapped to true black during expansion. The standard
    /// studio black is 16; raising it (e.g. to 20) crushes the lifted near-black
    /// levels some encoders emit, for blacker blacks. Only used when
    /// `expandToFullRangeForDisplay` is `true`.
    public var studioBlackPoint: Int

    public init(
        signaledFullRange: Bool? = nil,
        ycbcrMatrix: CFString? = nil,
        colorPrimaries: CFString? = nil,
        transferFunction: CFString? = nil,
        expandToFullRangeForDisplay: Bool = false,
        studioBlackPoint: Int = 16
    ) {
        self.signaledFullRange = signaledFullRange
        self.ycbcrMatrix = ycbcrMatrix
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.expandToFullRangeForDisplay = expandToFullRangeForDisplay
        self.studioBlackPoint = studioBlackPoint
    }

    /// Correction for the GLKVM stream: its V4L2/uStreamer encoder emits genuine
    /// studio-range BT.709 luma and chroma with a slightly lifted black floor.
    /// Explicitly tag the decoded buffer limited-range BT.709 so Core Image
    /// expands it correctly, route it through the full-range expander, and crush
    /// the lifted black floor so blacks, whites, and saturation render correctly.
    public static let glkvm = H264ColorOverride(
        signaledFullRange: false,
        ycbcrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        expandToFullRangeForDisplay: true,
        studioBlackPoint: 20
    )
}

enum H264FrameContinuityAction: Equatable {
    case decode
    case decodeThroughDiscontinuity
    case resetAndDecodeKeyframe
}

struct H264FrameContinuityGate {
    private(set) var lastSequenceNumber: UInt64?

    mutating func inspect(_ frame: H264StreamFrame, isKeyFrame: Bool) -> H264FrameContinuityAction {
        let hasDiscontinuity = lastSequenceNumber.map { frame.sequenceNumber != $0 &+ 1 } ?? false
        lastSequenceNumber = frame.sequenceNumber

        guard hasDiscontinuity else {
            return .decode
        }

        if isKeyFrame {
            return .resetAndDecodeKeyframe
        }

        return .decodeThroughDiscontinuity
    }

    mutating func reset() {
        lastSequenceNumber = nil
    }
}

public final class H264Decoder: @unchecked Sendable {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var continuityGate = H264FrameContinuityGate()
    private let colorOverride: H264ColorOverride?
    private let fullRangeExpander: FullRangeVideoExpander?
    private let output: @Sendable (CMSampleBuffer) -> Void

    public init(
        colorOverride: H264ColorOverride? = nil,
        output: @escaping @Sendable (CMSampleBuffer) -> Void
    ) {
        self.colorOverride = colorOverride
        self.fullRangeExpander = colorOverride?.expandToFullRangeForDisplay == true
            ? FullRangeVideoExpander(studioBlackPoint: colorOverride?.studioBlackPoint ?? 16)
            : nil
        self.output = output
    }

    deinit {
        invalidate()
    }

    public func decode(_ frame: H264StreamFrame) throws {
        let units = H264AnnexBParser.parseNALUnits(from: frame.payload)
        guard !units.isEmpty else { return }

        let isKeyFrame = frame.isKeyFrame || units.contains { $0.isIDR }
        switch continuityGate.inspect(frame, isKeyFrame: isKeyFrame) {
        case .decode:
            break
        case .resetAndDecodeKeyframe:
            KVMLog.video.info(
                "H.264 stream discontinuity at appSequence=\(frame.sequenceNumber, privacy: .public); resetting decoder at keyframe"
            )
            resetSession()
        case .decodeThroughDiscontinuity:
            KVMLog.video.info(
                "H.264 stream discontinuity at appSequence=\(frame.sequenceNumber, privacy: .public); decoding through because no keyframe was available"
            )
        }

        var parameterSetsChanged = false
        for unit in units {
            if unit.isSPS, sps != unit.data {
                sps = unit.data
                parameterSetsChanged = true
            } else if unit.isPPS, pps != unit.data {
                pps = unit.data
                parameterSetsChanged = true
            }
        }

        if parameterSetsChanged {
            resetSession()
        }

        if decompressionSession == nil {
            guard isKeyFrame, sps != nil, pps != nil else { return }
            try createSession()
        }

        let sampleUnits = units.filter { !$0.isSPS && !$0.isPPS }
        guard !sampleUnits.isEmpty else { return }

        let sampleBuffer = try makeSampleBuffer(from: sampleUnits, timestampMicros: frame.timestampMicros)
        guard let decompressionSession else { return }

        let context = Unmanaged.passRetained(
            H264FrameDecodeContext(wireArrivalHostTime: frame.wireArrivalHostTime)
        )
        // The output callback always consumes the +1 retain via
        // `takeRetainedValue()`. VT can still surface a non-zero status from
        // `DecodeFrame` after the callback has run (e.g. during stream resync),
        // so we must not release here too — that would double-free. If VT ever
        // returns an error without invoking the callback the context leaks,
        // which is bounded and far safer than a crash.
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: context.toOpaque(),
            infoFlagsOut: nil
        )
        guard status == noErr else { throw H264DecoderError.decode(status) }
    }

    public func invalidate() {
        resetSession()
        sps = nil
        pps = nil
        continuityGate.reset()
    }

    private func resetSession() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    private func createSession() throws {
        guard let sps, let pps else { return }

        var newFormatDescription: CMVideoFormatDescription?
        let formatStatus = try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                guard
                    let spsBase = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    throw H264DecoderError.formatDescription(invalidParameterStatus)
                }

                var parameterSetPointers = [spsBase, ppsBase]
                var parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }
        guard formatStatus == noErr, let newFormatDescription else {
            throw H264DecoderError.formatDescription(formatStatus)
        }

        let sessionFormatDescription = Self.applyingColorOverride(colorOverride, to: newFormatDescription)
            ?? newFormatDescription

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: sessionFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else {
            throw H264DecoderError.decompressionSession(sessionStatus)
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var threadCountValue: Int32 = 1
        if let threadCount = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &threadCountValue) {
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_ThreadCount, value: threadCount)
        }

        formatDescription = sessionFormatDescription
        decompressionSession = newSession
    }

    /// Returns a copy of `formatDescription` with the color attachments named by
    /// `override` overwritten, preserving every other extension (notably the
    /// `SampleDescriptionExtensionAtoms` that hold the avcC SPS/PPS). Returns
    /// `formatDescription` unchanged when `override` is `nil`, and `nil` if the
    /// corrected description could not be rebuilt.
    ///
    /// Pure and side-effect-free so it can be unit-tested without a live
    /// VideoToolbox session.
    static func applyingColorOverride(
        _ override: H264ColorOverride?,
        to formatDescription: CMVideoFormatDescription
    ) -> CMVideoFormatDescription? {
        guard let override else { return formatDescription }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let existing = (CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any]) ?? [:]
        var merged = existing

        if let signaledFullRange = override.signaledFullRange {
            merged[kCMFormatDescriptionExtension_FullRangeVideo] = signaledFullRange as CFBoolean
        }
        if let ycbcrMatrix = override.ycbcrMatrix {
            merged[kCMFormatDescriptionExtension_YCbCrMatrix] = ycbcrMatrix
        }
        if let colorPrimaries = override.colorPrimaries {
            merged[kCMFormatDescriptionExtension_ColorPrimaries] = colorPrimaries
        }
        if let transferFunction = override.transferFunction {
            merged[kCMFormatDescriptionExtension_TransferFunction] = transferFunction
        }

        var corrected: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: dimensions.width,
            height: dimensions.height,
            extensions: merged as CFDictionary,
            formatDescriptionOut: &corrected
        )
        guard status == noErr else { return nil }
        return corrected
    }

    private func makeSampleBuffer(from units: [H264NALUnit], timestampMicros: UInt64) throws -> CMSampleBuffer {
        var sampleData = Data()
        for unit in units {
            var length = UInt32(unit.data.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(unit.data)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw H264DecoderError.blockBuffer(status) }

        status = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard status == noErr else { throw H264DecoderError.blockBuffer(status) }

        guard let formatDescription else { throw H264DecoderError.formatDescription(invalidParameterStatus) }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw H264DecoderError.sampleBuffer(status) }

        return sampleBuffer
    }

    fileprivate func handleDecoded(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        wireArrivalHostTime: CMTime?
    ) {
        guard status == noErr, let imageBuffer else { return }

        // Expand studio-range YCbCr to full-range RGB on the GPU. This reads
        // `imageBuffer` without mutating it — VideoToolbox reuses its output as a
        // reference frame, so editing it in place corrupts later frames. Falls
        // back to the original buffer if expansion is unavailable.
        let displayBuffer = fullRangeExpander?.expand(imageBuffer) ?? imageBuffer

        var imageFormatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: displayBuffer,
            formatDescriptionOut: &imageFormatDescription
        )
        guard formatStatus == noErr, let imageFormatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var decodedSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: displayBuffer,
            formatDescription: imageFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &decodedSampleBuffer
        )
        guard sampleStatus == noErr, let decodedSampleBuffer else { return }

        markDisplayImmediately(decodedSampleBuffer)
        if let wireArrivalHostTime {
            SampleBufferLatencyTag.attachWireArrivalHostTime(wireArrivalHostTime, to: decodedSampleBuffer)
        }
        output(decodedSampleBuffer)
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0,
            let attachment = CFArrayGetValueAtIndex(attachments, 0)
        else { return }

        let attachmentDictionary = unsafeBitCast(attachment, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachmentDictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

private let decompressionOutputCallback: VTDecompressionOutputCallback = { refCon, sourceFrameRefCon, status, _, imageBuffer, presentationTimeStamp, duration in
    var wireArrivalHostTime: CMTime?
    if let sourceFrameRefCon {
        let context = Unmanaged<H264FrameDecodeContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        wireArrivalHostTime = context.wireArrivalHostTime
    }
    guard let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration,
        wireArrivalHostTime: wireArrivalHostTime
    )
}

final class H264FrameDecodeContext {
    let wireArrivalHostTime: CMTime?

    init(wireArrivalHostTime: CMTime?) {
        self.wireArrivalHostTime = wireArrivalHostTime
    }
}
