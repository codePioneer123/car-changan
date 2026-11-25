import SwiftUI
import CoreBluetooth

@main
struct ChanganLink: App {
    @StateObject private var link = VehicleLink()
    @State private var showPassword = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("ICCOA Carlink") {
                        NavigationLink("通过车机 Carlink 投屏") { NativeLinkView(port: link.authPort) }
                    }
                    Section("浏览器投屏") {
                        NavigationLink("把 iPhone 屏幕投到车机") { MirrorView() }
                    }
                    Section("Carlink 连接测试") { Text(link.status) }
                    Section {
                        Button("查找车机") { link.scan() }.disabled(link.busy)
                        if link.busy { Button("取消") { link.finish("已取消") } }
                    }
                    if let hotspot = link.hotspot {
                        Section("手动加入热点") {
                            LabeledContent("网络名称", value: hotspot.ssid)
                            Toggle("显示本次热点密码", isOn: $showPassword)
                            if showPassword { Text(hotspot.psk).privacySensitive() }
                            Text("打开系统设置 → 无线局域网，选择上述网络。")
                        }
                    }
                    if !link.history.isEmpty {
                        DisclosureGroup("连接记录") {
                            ForEach(Array(link.history.enumerated()), id: \.offset) { item in Text(item.element) }
                        }
                    }
                    Section("选择车机") {
                        ForEach(link.devices, id: \.identifier) { device in
                            Button(device.name ?? device.identifier.uuidString) { link.connect(device) }
                                .disabled(!link.selectable)
                        }
                    }
                }.navigationTitle("长安车机互联").onChange(of: link.hotspot?.ssid) { _, _ in showPassword = false }
            }
        }
    }
}
