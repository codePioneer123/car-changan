import Foundation
import CoreImage
import VideoToolbox

/// Owned by ReplayKit's serial sample callback. VideoToolbox owns its compression callback.
final class CarlinkVideo {
    private let width = 1280, height = 720
    private var session: VTCompressionSession?
    private let color = CGColorSpaceCreateDeviceRGB()
    private let black = CIImage(color: .black)
    private var nextFrame = 0

    func reset() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        nextFrame = 0
    }

    func send(_ image: CIImage, context: CIContext, time: CMTime) {
        if session == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            let created = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
                outputCallback: { _, _, result, _, buffer in
                    guard result == noErr, let buffer, CMSampleBufferDataIsReady(buffer),
                          let desc = CMSampleBufferGetFormatDescription(buffer),
                          let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]]
                    let key = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
                    if key {
                        guard let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                              let config = atoms["avcC"] as? Data,
                              config.withUnsafeBytes({ cl_format($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) == 0 else { return }
                    }
                    let length = CMBlockBufferGetDataLength(block)
                    guard (1...4*1024*1024).contains(length) else { return }
                    var data = Data(count: length)
                    let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0,
                        dataLength: length, destination: $0.baseAddress!) }
                    guard copied == noErr else { return }
                    let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(buffer), timescale: 1_000_000, method: .default).value
                    data.withUnsafeBytes { cl_frame($0.bindMemory(to: UInt8.self).baseAddress, $0.count, pts, key) }
                }, refcon: nil, compressionSessionOut: &session)
            guard created == noErr, let session else { return }
            let props: [String: Any] = [kVTCompressionPropertyKey_RealTime as String: true,
                kVTCompressionPropertyKey_AllowFrameReordering as String: false,
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
                kVTCompressionPropertyKey_AverageBitRate as String: 2_000_000,
                kVTCompressionPropertyKey_MaxKeyFrameInterval as String: 12]
            VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
            VTCompressionSessionPrepareToEncodeFrames(session)
        }
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let factor = min(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let centered = scaled.transformed(by: CGAffineTransform(translationX: rect.midX-scaled.extent.midX,
                                                                y: rect.midY-scaled.extent.midY))
        context.render(centered.composited(over: black.cropped(to: rect)), to: output, bounds: rect, colorSpace: color)
        let force = nextFrame % 12 == 0
        nextFrame += 1
        let options = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: force] as CFDictionary
        VTCompressionSessionEncodeFrame(session, imageBuffer: output, presentationTimeStamp: time,
            duration: .invalid, frameProperties: options, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    deinit { reset() }
}
