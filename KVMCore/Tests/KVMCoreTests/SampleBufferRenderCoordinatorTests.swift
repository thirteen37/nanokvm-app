import XCTest
import CoreMedia
import CoreVideo
@testable import KVMCore

final class SampleBufferRenderCoordinatorTests: XCTestCase {
    /// Inspectable stand-in for the real `AVSampleBufferDisplayLayer`-backed
    /// display, so we can assert exactly which frames each channel received.
    private final class FakeDisplay: SampleBufferDisplaying {
        private(set) var enqueuedPTS: [CMTime] = []
        private(set) var flushCount = 0

        func enqueue(_ sampleBuffer: CMSampleBuffer, renderMode: SampleBufferRenderMode) {
            enqueuedPTS.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        func flush() {
            flushCount += 1
        }
    }

    func test_attachMinimapDoesNotDetachMainDisplay_andSingleEnqueueReachesBoth() throws {
        let coordinator = SampleBufferRenderCoordinator(renderMode: .sampleBuffer)
        let main = FakeDisplay()
        let minimap = FakeDisplay()

        coordinator.attach(display: main)
        coordinator.attachMinimap(display: minimap)

        let frame = try makeSampleBuffer(pts: CMTime(value: 1, timescale: 60))
        coordinator.enqueue(frame)

        XCTAssertEqual(main.enqueuedPTS.count, 1, "main display must still be attached after attaching a minimap")
        XCTAssertEqual(minimap.enqueuedPTS.count, 1, "minimap must receive the same enqueued frame")
        XCTAssertEqual(main.enqueuedPTS.first, minimap.enqueuedPTS.first)
    }

    func test_freshMinimapIsSeededWithLastAcceptedFrame() throws {
        let coordinator = SampleBufferRenderCoordinator(renderMode: .sampleBuffer)
        let main = FakeDisplay()
        coordinator.attach(display: main)

        let pts = CMTime(value: 7, timescale: 60)
        coordinator.enqueue(try makeSampleBuffer(pts: pts))

        // Attaching after a frame has been accepted should seed the minimap
        // immediately (flush, then enqueue the retained last frame) so a static
        // host screen is visible without waiting for the next frame.
        let minimap = FakeDisplay()
        coordinator.attachMinimap(display: minimap)

        XCTAssertEqual(minimap.flushCount, 1, "minimap should be flushed on attach")
        XCTAssertEqual(minimap.enqueuedPTS, [pts], "minimap should be seeded with the last accepted frame")
    }

    func test_flushClearsSeedSoLaterMinimapIsNotSeeded() throws {
        let coordinator = SampleBufferRenderCoordinator(renderMode: .sampleBuffer)
        let main = FakeDisplay()
        coordinator.attach(display: main)

        coordinator.enqueue(try makeSampleBuffer(pts: CMTime(value: 1, timescale: 60)))
        coordinator.flush()

        XCTAssertEqual(main.flushCount, 2, "main display flushed on attach and on flush()")

        let minimap = FakeDisplay()
        coordinator.attachMinimap(display: minimap)

        XCTAssertEqual(minimap.flushCount, 1, "minimap still flushed on attach")
        XCTAssertTrue(minimap.enqueuedPTS.isEmpty, "flush cleared the seed, so a later minimap gets no seed frame")
    }

    func test_detachedMinimapNoLongerReceivesFrames() throws {
        let coordinator = SampleBufferRenderCoordinator(renderMode: .sampleBuffer)
        let main = FakeDisplay()
        let minimap = FakeDisplay()
        coordinator.attach(display: main)
        coordinator.attachMinimap(display: minimap)

        coordinator.enqueue(try makeSampleBuffer(pts: CMTime(value: 1, timescale: 60)))
        coordinator.detachMinimap(display: minimap)
        coordinator.enqueue(try makeSampleBuffer(pts: CMTime(value: 2, timescale: 60)))

        XCTAssertEqual(minimap.enqueuedPTS.count, 1, "minimap stops receiving frames after detach")
        XCTAssertEqual(main.enqueuedPTS.count, 2, "main keeps receiving frames")
    }

    func test_nonMonotonicFrameReachesNeitherDisplay() throws {
        let coordinator = SampleBufferRenderCoordinator(renderMode: .sampleBuffer)
        let main = FakeDisplay()
        let minimap = FakeDisplay()
        coordinator.attach(display: main)
        coordinator.attachMinimap(display: minimap)

        coordinator.enqueue(try makeSampleBuffer(pts: CMTime(value: 5, timescale: 60)))
        // Earlier PTS: filtered out by the monotonic gate for both channels.
        coordinator.enqueue(try makeSampleBuffer(pts: CMTime(value: 3, timescale: 60)))

        XCTAssertEqual(main.enqueuedPTS.count, 1)
        XCTAssertEqual(minimap.enqueuedPTS.count, 1)
    }

    // MARK: - Helpers

    private func makeSampleBuffer(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
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
