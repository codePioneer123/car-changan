import Foundation
import CoreBluetooth
import NetworkExtension
import Combine

final class VehicleLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var devices: [CBPeripheral] = []
    @Published private(set) var status = "请先打开车机上的 ICCOA Carlink"
    @Published private(set) var busy = false
    @Published private(set) var selectable = false
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private let service = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789100")
    private let tx = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789101")
    private let rx = CBUUID(string: "2abcc850-9935-4f8a-ba84-123456789102")
    private var peer: CBPeripheral?
    private var writer: CBCharacteristic?
    private var packet = Data()
    private var timer: Timer?
    private var waitingForRadio = false
    private var joining = false
    private var generation = UUID()

    func finish(_ message: String) {
        generation = UUID()
        timer?.invalidate()
        waitingForRadio = false
        joining = false
        central.stopScan()
        if let old = peer {
            old.delegate = nil
            central.cancelPeripheralConnection(old)
        }
        peer = nil
        writer = nil
        packet.removeAll()
        busy = false
        selectable = false
        status = message
    }

    func scan() {
        finish("正在检查蓝牙")
        devices.removeAll()
        waitingForRadio = true
        busy = true
        centralManagerDidUpdateState(central)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard waitingForRadio else { return }
            waitingForRadio = false
            selectable = true
            status = "正在查找车机"
            central.scanForPeripherals(withServices: [CBUUID(string: "FCFB")])
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.central.stopScan()
                self.busy = false
                self.status = self.devices.isEmpty ? "未发现 Carlink 广播，请检查车机互联页面" : "请选择车机"
            }
        case .unknown, .resetting: break
        default: finish("蓝牙不可用，请检查系统蓝牙及 App 权限")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard selectable, !devices.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        devices.append(peripheral)
    }

    func connect(_ device: CBPeripheral) {
        guard selectable else { return }
        finish("正在连接车机")
        busy = true
        peer = device
        device.delegate = self
        central.connect(device)
        timer = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            self?.finish("连接超时，请重新查找车机")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === peer { finish("蓝牙连接失败") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === peer && !joining { finish("车机已断开蓝牙") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral === peer { peripheral.discoverServices([service]) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil, let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            finish("车机未提供预期的 Carlink 服务")
            return
        }
        peripheral.discoverCharacteristics([tx, rx], for: found)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === peer else { return }
        let list = service.characteristics ?? []
        guard error == nil, let out = list.first(where: { $0.uuid == tx && $0.properties.contains(.write) }),
              let input = list.first(where: { $0.uuid == rx }),
              !input.properties.intersection([.notify, .indicate]).isEmpty else {
            finish("车机未提供可用的互联通道")
            return
        }
        writer = out
        peripheral.setNotifyValue(true, for: input)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer, characteristic.uuid == rx else { return }
        guard error == nil, characteristic.isNotifying, let writer else { finish("无法订阅车机回复"); return }
        // A locally administered session identifier, never the platform's hardware MAC.
        let mac = ([UInt8(2)] + (0..<5).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined(separator: ":")
        let request: [String: Any] = ["id": UUID().uuidString, "name": "iPhone", "model": "iPhone",
                                      "band": 0, "mac": mac, "type": 1002]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            finish("车机无法接收连接请求")
            return
        }
        status = "等待车机提供热点"
        peripheral.writeValue(data, for: writer, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === peer && error != nil && !joining { finish("车机拒绝连接请求") }
    }

    private struct Reply: Decodable { let ssid: String; let psk: String; let type: Int }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer, characteristic.uuid == rx, !joining else { return }
        guard error == nil, let fragment = characteristic.value, !fragment.isEmpty,
              packet.count + fragment.count <= 4096 else { finish("车机回复异常"); return }
        packet.append(fragment)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: packet) else { return }
        guard reply.type == 1002 else { finish("车机要求另一种 Wi-Fi 连接模式"); return }
        guard (1...32).contains(reply.ssid.utf8.count), (8...63).contains(reply.psk.utf8.count) else {
            finish("车机热点参数不受支持")
            return
        }
        joining = true
        packet.removeAll()
        timer?.invalidate()
        let attempt = generation
        let config = NEHotspotConfiguration(ssid: reply.ssid, passphrase: reply.psk, isWEP: false)
        config.joinOnce = true
        status = "请确认系统的 Wi-Fi 加入提示"
        NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == attempt else { return }
                if let e = error as NSError?, !(e.domain == NEHotspotConfigurationErrorDomain &&
                    e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                    self.finish("加入车机热点失败（系统错误码 " + String(e.code) + "）")
                } else {
                    self.finish("系统已接受热点配置，投屏会话尚未建立")
                }
            }
        }
    }
}
