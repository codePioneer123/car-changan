import Foundation
import CoreImage
import CoreMedia
import VideoToolbox

// Capture the same AVCC config and samples the extension passes to its native transport.
let lock = NSLock()
let received = DispatchSemaphore(value: 0)
nonisolated(unsafe) var gotFormat = false
func cl_format(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let pointer, count >= 7, pointer[0] == 1, pointer[4] & 3 == 3 else { return -1 }
    lock.lock()
    gotFormat = true
    lock.unlock()
    return 0
}
func cl_frame(_ pointer: UnsafePointer<UInt8>?, _ count: Int, _ pts: Int64, _ key: Bool) {
    guard let pointer, key, count > 4, pts >= 0 else { return }
    var offset = 0
    var idr = false
    while offset + 4 <= count {
        let length = (0..<4).reduce(0) { ($0 << 8) | Int(pointer[offset+$1]) }
        offset += 4
        guard length > 0, length <= count-offset else { return }
        idr = idr || (pointer[offset] & 0x1f == 5)
        offset += length
    }
    lock.lock()
    let valid = gotFormat && idr && offset == count
    lock.unlock()
    if valid { received.signal() }
}
let encoder = CarlinkVideo()
let context = CIContext(options: [.useSoftwareRenderer: true])
let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
for tick in 0..<60 {
    encoder.send(image, context: context, time: CMTime(value: Int64(tick), timescale: 12))
    if received.wait(timeout: .now()+0.08) == .success {
        print("Captured H.264 decoder configuration plus a length-prefixed IDR")
        exit(0)
    }
}
fatalError("VideoToolbox did not deliver a usable H.264 key frame")
