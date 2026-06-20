import CoreMedia
import XCTest

@testable import KVMCore

final class H264ColorOverrideTests: XCTestCase {
    private func makeFormatDescription(extensions: [CFString: Any]) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        let unwrapped = try XCTUnwrap(formatDescription)
        XCTAssertEqual(status, noErr)
        return unwrapped
    }

    private func extensions(of formatDescription: CMVideoFormatDescription) throws -> [CFString: Any] {
        let raw = try XCTUnwrap(CMFormatDescriptionGetExtensions(formatDescription))
        return try XCTUnwrap(raw as? [CFString: Any])
    }

    func testGLKVMOverrideForcesLimitedRangeAndBT709() throws {
        let source = try makeFormatDescription(extensions: [
            kCMFormatDescriptionExtension_FullRangeVideo: kCFBooleanTrue as Any,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        ])

        let corrected = try XCTUnwrap(H264Decoder.applyingColorOverride(.glkvm, to: source))
        let ext = try extensions(of: corrected)

        let fullRange = try XCTUnwrap(ext[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool)
        XCTAssertFalse(fullRange)
        XCTAssertEqual(
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] as! CFString,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        )
        XCTAssertEqual(
            ext[kCMFormatDescriptionExtension_ColorPrimaries] as! CFString,
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        )
        XCTAssertEqual(
            ext[kCMFormatDescriptionExtension_TransferFunction] as! CFString,
            kCMFormatDescriptionTransferFunction_ITU_R_709_2
        )
    }

    func testGLKVMOverridePreservesParameterSetAtoms() throws {
        let atoms: [CFString: Any] = ["avcC" as CFString: Data([0x01, 0x02, 0x03]) as Any]
        let source = try makeFormatDescription(extensions: [
            kCMFormatDescriptionExtension_FullRangeVideo: kCFBooleanTrue as Any,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms as Any,
        ])

        let corrected = try XCTUnwrap(H264Decoder.applyingColorOverride(.glkvm, to: source))
        let ext = try extensions(of: corrected)

        XCTAssertNotNil(ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms])
    }

    func testNilOverrideReturnsSameDescription() throws {
        let source = try makeFormatDescription(extensions: [
            kCMFormatDescriptionExtension_FullRangeVideo: kCFBooleanTrue as Any,
        ])

        let result = H264Decoder.applyingColorOverride(nil, to: source)

        XCTAssertEqual(result, source)
    }
}
