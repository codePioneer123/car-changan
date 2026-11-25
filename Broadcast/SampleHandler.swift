import ReplayKit
import CoreImage
import ImageIO

final class SampleHandler: RPBroadcastSampleHandler {
    private let nativeVideo = CarlinkVideo()
    private let server = MirrorServer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastFrame: TimeInterval = -.infinity

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            server.nativeControl = { action, parameters in
                switch action {
                case "pin": return String(cl_pin(parameters ?? ""))
                case "state": return String(cl_state())
                case "stop": cl_stop(); return "0"
                case "start":
                    let fields = (parameters ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count == 4, let port = UInt16(fields[2]) else { return "-1" }
                    return String(cl_start(fields[0], fields[1], port, fields[3]))
                default: return "-1"
                }
            }
            try server.start { [weak self] error in
                DispatchQueue.main.async { self?.finishBroadcastWithError(error) }
            }
        } catch { finishBroadcastWithError(error) }
    }

    override func broadcastPaused() { server.publish(nil) }
    override func broadcastFinished() { server.stop(); nativeVideo.reset(); cl_stop() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.12 else { return }
        lastFrame = now
        autoreleasepool {
            var image = CIImage(cvPixelBuffer: buffer)
            if let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                            attachmentModeOut: nil) as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) {
                image = image.oriented(orientation)
            }
            if cl_state() == 4 {
                server.publish(nil)
                nativeVideo.send(image, context: context, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                return
            }
            let scale = min(1, 960 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            if let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.62]) {
                server.publish(jpeg)
            }
        }
    }
}
