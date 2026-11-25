import Foundation
import Network

// Listener and all mutable connection state live on this serial queue.
final class MirrorServer {
    private let queue = DispatchQueue(label: "changan.screen.http")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var frame: Data?
    private var key = ""
    var nativeControl: ((String, String?) -> String)?
    let port: UInt16

    init(port: UInt16 = 48751) { self.port = port }

    func start(onFailure: @escaping (Error) -> Void) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        queue.sync {
            self.key = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            self.listener = listener
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state { onFailure(error) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func publish(_ data: Data?) { queue.sync { frame = data } }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values { client.cancel() }
            clients.removeAll()
            frame = nil
            key = ""
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, clients.count < 12 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.close(id) }
        read(id, buffer: Data())
    }

    private func close(_ id: UUID) { clients.removeValue(forKey: id)?.cancel() }

    private func read(_ id: UUID, buffer: Data) {
        guard let connection = clients[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self, self.clients[id] != nil else { return }
            var request = buffer
            request.append(bytes ?? Data())
            guard error == nil, request.count <= 8192 else { self.close(id); return }
            if let end = request.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: request[..<end.lowerBound], encoding: .utf8) {
                self.respond(id, header: header)
            } else if complete { self.close(id) }
            else { self.read(id, buffer: request) }
        }
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let ip): return ip.rawValue == Data([127,0,0,1])
        case .ipv6(let ip): return ip.rawValue == Data(Array(repeating: UInt8(0), count: 10) + [255,255,127,0,0,1]) || ip == .loopback
        default: return false
        }
    }

    private func respond(_ id: UUID, header: String) {
        guard let connection = clients[id] else { return }
        let line = header.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard line.count == 3, (line[0] == "GET" || line[0] == "POST") else { close(id); return }
        let path = String(line[1])
        var body = Data()
        var type = "text/plain"
        var status = "404 Not Found"
        if path.hasPrefix("/native/"), line[0] == "POST",
           case let .hostPort(host, _) = connection.endpoint, Self.isLoopback(host),
           header.components(separatedBy: "\r\n").contains("X-Changan-Local: session"), let nativeControl {
            let prefix = "X-Changan-Parameters: "
            let parameters = header.components(separatedBy: "\r\n").first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            body = Data(nativeControl(String(path.dropFirst(8)), parameters).utf8)
            status = "200 OK"
        } else if line[0] != "GET" { status = "405 Method Not Allowed" }
        else if path == "/local-session",
           case let .hostPort(host, _) = connection.endpoint,
           Self.isLoopback(host),
           header.components(separatedBy: "\r\n").dropFirst().contains(where: {
               $0.lowercased() == "x-changan-local: session"
           }) {
            body = Data(key.utf8)
            status = "200 OK"
        } else if path == "/\(key)/" {
            body = Data(Self.viewer.utf8)
            type = "text/html; charset=utf-8"
            status = "200 OK"
        } else if path == "/\(key)/frame" {
            if let frame { body = frame; type = "image/jpeg"; status = "200 OK" }
            else { status = "503 Service Unavailable" }
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private static let viewer = """
    <!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>长安投屏</title><style>body{margin:0;background:#111;color:white;font:18px sans-serif}img{width:100vw;height:100vh;object-fit:contain}p{position:absolute;inset:1em auto auto 1em}</style>
    <img id="screen" alt=""><p id="state">正在接收手机画面…</p><script>
    const screenImage=document.getElementById('screen'),state=document.getElementById('state');
    let current='';
    async function update(){
      try{
        const response=await fetch('frame',{cache:'no-store'});
        if(!response.ok)throw Error();
        const next=URL.createObjectURL(await response.blob());
        screenImage.src=next;
        if(current)URL.revokeObjectURL(current);
        current=next;state.textContent='';
      }catch(e){screenImage.removeAttribute('src');state.textContent='等待画面，请确认 iPhone 仍在直播';}
      setTimeout(update,120);
    }
    update();</script></html>
    """
}
