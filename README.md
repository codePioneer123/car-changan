# 长安车机互联

iPhone 客户端原型，面向第四代 CS75 PLUS。已实现 CoreBluetooth 发现、用户选车、GATT 通知订阅、热点模式请求和临时 Wi-Fi 配置。尚未接入 PIN 认证、CarPlay 音视频和反向触控，当前版本只用于连接测试。

使用 XcodeGen 生成工程（`xcodegen generate`），在 Xcode 中选择自己的 Team 并启用 Hotspot Configuration，然后运行到 iPhone。模拟器只能验证编译。实车测试时，在车辆停稳后进入 ICCOA Carlink，在手机端点击查找车机，选择对应设备并按 iOS 提示加入热点。界面显示的热点结果仅指系统配置请求。

协议字段参考 [OpenXPlay-Stream](https://github.com/OpenXPlay/OpenXPlay-Stream/tree/5bedbd0713d6262c6f58cdbb75e31c2aaca2b598/rust/oxp-clink)。目前尝试热点模式（1002），请求中的 MAC 为本地生成的临时标识。该车型是否接受此模式与标识有待实车验证。热点密码仅在内存中用于系统的临时连接请求。
