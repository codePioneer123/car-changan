import SwiftUI
import Network

/// Device-local IPC with the running ReplayKit extension.
private final class CommandRequest {
    private let connection = NWConnection(host: "127.0.0.1", port: 48751, using: .tcp)
    private var completion: ((String?) -> Void)?
    private var buffer = Data()
    private func finish(_ value: String?) {
        let callback = completion
        completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback?(value)
    }
    func send(_ command: String, parameters: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        let request = Data("POST /native/\(command) HTTP/1.1\r\nHost: localhost\r\nX-Changan-Local: session\r\nX-Changan-Parameters: \(parameters)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { self.finish(nil) } else { self.read() }
                })
            case .failed, .waiting: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now()+4) { [weak self] in self?.finish(nil) }
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, end, error in
            self.buffer.append(data ?? Data())
            guard self.buffer.count < 4096, error == nil else { self.finish(nil); return }
            if end {
                let parts = String(decoding: self.buffer, as: UTF8.self).components(separatedBy: "\r\n\r\n")
                self.finish(parts.count == 2 && parts[0].hasPrefix("HTTP/1.1 200") ? parts[1] : nil)
            } else { self.read() }
        }
    }
}

struct NativeLinkView: View {
    let port: UInt16
    @State private var peer = ""
    @State private var pin = ""
    @State private var state: Int?
    @State private var feedback = ""
    @State private var processing = false

    private var caption: String {
        switch state {
        case 0: return "直播已启动，等待连接车机"
        case 1: return "正在连接车机认证端口"
        case 2: return "正在验证配对"
        case 3: return "正在协商画面"
        case 4: return "Carlink 已进入播放阶段"
        case 5: return "车机会话已结束"
        case 6: return "请输入车机显示的六位配对码"
        case -2: return "配对码无效或等待已超时"
        case -3: return "车机证书协商失败"
        case nil: return "请先启动长安投屏直播"
        default: return "车机会话失败，请核对热点、车机 IP 和互联页面"
        }
    }

    private func update() async {
        let value: String? = await withCheckedContinuation { result in
            CommandRequest().send("state", parameters: "") { result.resume(returning: $0) }
        }
        if !Task.isCancelled { state = value.flatMap(Int.init) }
    }

    private func action(_ command: String, parameters: String = "") {
        processing = true
        CommandRequest().send(command, parameters: parameters) { result in
            processing = false
            feedback = result == "0" ? "" : "请求未完成，请确认系统直播仍在运行。"
            if command == "pin" { pin = "" }
        }
    }

    var body: some View {
        Form {
            Section("连接车机热点") {
                Text("在车机打开 ICCOA Carlink，在 App 首页查找车机并取得热点信息，然后让 iPhone 加入该热点。")
                TextField("车机 IP（通常为热点的路由器地址）", text: $peer)
                    .keyboardType(.decimalPad).autocorrectionDisabled()
                Text("可在 iPhone 设置 → 无线局域网 → 当前车机热点 ⓘ 查看路由器地址。")
            }
            Section("启动长安投屏直播") {
                BroadcastButton().frame(width: 52, height: 52)
                Text(caption)
                if state == 0 {
                    Button("开始 Carlink 连接") {
                        guard let local = wifiIPv4() else { feedback = "请先加入车机热点"; return }
                        guard IPv4Address(peer) != nil, peer != local else { feedback = "请输入有效的车机 IPv4 地址"; return }
                        action("start", parameters: "\(local),\(peer),\(port),")
                    }.disabled(processing)
                } else if state != nil {
                    if state == 6 {
                        SecureField("车机配对码", text: $pin).keyboardType(.numberPad)
                        Button("确认配对") { action("pin", parameters: pin) }
                            .disabled(processing || pin.utf8.count != 6 || !pin.utf8.allSatisfy { (48...57).contains($0) })
                    }
                    Button("断开 Carlink") { action("stop") }.disabled(processing)
                }
                if !feedback.isEmpty { Text(feedback) }
                Text("结束屏幕共享请停止系统直播。")
            }
        }.navigationTitle("Carlink 投屏")
        .task {
            while !Task.isCancelled {
                await update()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
