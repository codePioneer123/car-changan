import Foundation

let server = MirrorServer(port: 48752)
try server.start { fatalError("listener failed: \($0)") }
defer { server.stop() }
let base = URL(string: "http://127.0.0.1:48752")!
func get(_ path: String, local: Bool = false) -> (Int, Data) {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.timeoutInterval = 2
    if local { request.setValue("session", forHTTPHeaderField: "X-Changan-Local") }
    let done = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable {
        var status = 0
        var data = Data()
    }
    let result = ResultBox()
    URLSession.shared.dataTask(with: request) { bytes, response, _ in
        result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        result.data = bytes ?? Data()
        done.signal()
    }.resume()
    precondition(done.wait(timeout: .now() + 4) == .success)
    return (result.status, result.data)
}
var token = ""
for _ in 0..<10 {
    let reply = get("local-session", local: true)
    if reply.0 == 200 { token = String(decoding: reply.1, as: UTF8.self); break }
    Thread.sleep(forTimeInterval: 0.1)
}
precondition(token.count == 12 && token.allSatisfy { $0.isHexDigit })
precondition(get("local-session").0 == 404)
precondition(get("wrong/frame").0 == 404)
precondition(get(token + "/").0 == 200)
precondition(get(token + "/frame").0 == 503)
let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
server.publish(bytes)
let frame = get(token + "/frame")
precondition(frame.0 == 200 && frame.1 == bytes)
server.publish(nil)
precondition(get(token + "/frame").0 == 503)
print("Receiver pairing, frame delivery and pause verified.")
