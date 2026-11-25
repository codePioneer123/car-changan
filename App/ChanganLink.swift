import SwiftUI
import CoreBluetooth

@main
struct ChanganLink: App {
    @StateObject private var link = VehicleLink()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("连接状态") { Text(link.status) }
                    Section {
                        Button("查找车机") { link.scan() }.disabled(link.busy)
                        if link.busy { Button("取消") { link.finish("已取消") } }
                    }
                    Section("选择车机") {
                        ForEach(link.devices, id: \.identifier) { device in
                            Button(device.name ?? device.identifier.uuidString) { link.connect(device) }
                                .disabled(!link.selectable)
                        }
                    }
                }.navigationTitle("长安车机互联")
            }
        }
    }
}
