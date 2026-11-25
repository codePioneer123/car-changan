import SwiftUI
import ReplayKit
import Network
import Darwin

private struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        picker.showsMicrophoneButton = false
        if let directory = Bundle.main.builtInPlugInsURL,
           let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           let url = urls.first(where: { $0.pathExtension == "appex" }) {
            picker.preferredExtension = Bundle(url: url)?.bundleIdentifier
        }
        return picker
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

private func wifiIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(first) }
    var entry: UnsafeMutablePointer<ifaddrs>? = first
    while let current = entry {
        let info = current.pointee
        entry = info.ifa_next
        guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              String(cString: info.ifa_name) == "en0" else { continue }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count),
                       nil, 0, NI_NUMERICHOST) == 0 { return String(cString: name) }
    }
    return nil
}

private final class SessionAddress: ObservableObject {
    @Published var address: String?
    private var probe: NWConnection?

    func refresh() {
        stop()
        guard let ip = wifiIPv4() else { address = nil; return }
        let c = NWConnection(host: "127.0.0.1", port: 48751, using: .tcp)
        probe = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.probe === c else { return }
            switch state {
            case .ready:
                let request = Data("GET /local-session HTTP/1.1\r\nHost: localhost\r\nX-Changan-Local: session\r\nConnection: close\r\n\r\n".utf8)
                c.send(content: request, completion: .contentProcessed { error in
                    guard error == nil else { return }
                    c.receive(minimumIncompleteLength: 2048, maximumLength: 2048) { data, _, _, _ in
                        guard self.probe === c else { return }
                        let parts = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n\r\n")
                        if parts.count == 2, parts[0].hasPrefix("HTTP/1.1 200 "), parts[1].count == 12,
                           parts[1].allSatisfy({ $0.isHexDigit }) {
                            self.address = "http://\(ip):48751/\(parts[1])/"
                        } else { self.address = nil }
                        self.stop()
                    }
                })
            case .waiting, .failed: self.address = nil; self.stop()
            default: break
            }
        }
        c.start(queue: .main)
    }

    func stop() {
        probe?.stateUpdateHandler = nil
        probe?.cancel()
        probe = nil
    }
}

struct MirrorView: View {
    @StateObject private var session = SessionAddress()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section("连接到同一 Wi-Fi") {
                Text("让手机和车机加入同一个可信 Wi-Fi，或让手机加入车机热点。车机需支持打开网页。")
            }
            Section("启动屏幕直播") {
                HStack {
                    BroadcastButton().frame(width: 52, height: 52)
                    Text("轻点录制按钮，选择长安投屏并开始直播。")
                }
                Text("直播时车机可看到手机屏幕。可在系统录屏菜单中停止共享。")
            }
            Section("车机浏览器地址") {
                if let address = session.address {
                    Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("输入完整地址。持有此地址的同网设备可查看本次直播。")
                } else {
                    Text("等待直播开始。若地址未出现，请检查手机是否已连接 Wi-Fi。")
                }
            }
        }
        .navigationTitle("浏览器投屏")
        .task(id: phase) {
            guard phase == .active else { session.stop(); return }
            while !Task.isCancelled {
                session.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { session.stop() }
    }
}
