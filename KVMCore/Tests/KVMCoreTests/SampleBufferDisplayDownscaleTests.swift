import XCTest
import CoreMedia
import CoreVideo
import QuartzCore
@testable import KVMCore

/// Exercises the `.directLatestFrame` CPU path (VNC / Apple Screen Sharing).
/// Tests run on the main thread, so `enqueue` sets `layer.contents` synchronously.
@MainActor
final class SampleBufferDisplayDownscaleTests: XCTestCase {
    func test_directFrameDownscalesToCapPreservingAspect() throws {
        let display = SampleBufferDisplay()
        display.directFrameMaxDimension = 100

        let frame = try makeSampleBuffer(width: 400, height: 200, pts: CMTime(value: 1, timescale: 60))
        display.enqueue(frame, renderMode: .directLatestFrame)

        let image = try XCTUnwrap(display.layer.contents as! CGImage?)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
    }

    func test_directFrameWithoutCapKeepsFullResolution() throws {
        let display = SampleBufferDisplay()
        // directFrameMaxDimension defaults to nil.

        let frame = try makeSampleBuffer(width: 320, height: 180, pts: CMTime(value: 1, timescale: 60))
        display.enqueue(frame, renderMode: .directLatestFrame)

        let image = try XCTUnwrap(display.layer.contents as! CGImage?)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
    }

    func test_directFrameSmallerThanCapIsNotUpscaled() throws {
        let display = SampleBufferDisplay()
        display.directFrameMaxDimension = 1000

        let frame = try makeSampleBuffer(width: 80, height: 40, pts: CMTime(value: 1, timescale: 60))
        display.enqueue(frame, renderMode: .directLatestFrame)

        let image = try XCTUnwrap(display.layer.contents as! CGImage?)
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 40)
    }

    // MARK: - Helpers

    private func makeSampleBuffer(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        XCTAssertEqual(pbStatus, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(fmtStatus, noErr)
        let format = try XCTUnwrap(formatDescription)

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
