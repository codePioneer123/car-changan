# 长安车机互联

为第四代 CS75 PLUS 开发的 iPhone 实验客户端。实车兼容性待验证。

## 浏览器投屏

手机与车机连接同一个可信 Wi-Fi（手机也可加入车机热点）。在 App 中进入“把 iPhone 屏幕投到车机”，用系统录制按钮启动长安投屏，再把页面显示的完整地址输入车机浏览器。每次直播地址均更新。系统 ReplayKit 确认后共享屏幕，可切换其他 App。受保护画面可能无法录制。地址使用局域网 HTTP，仅在可信网络使用，用完在系统录屏菜单停止。

本版本使用低帧率 JPEG 传输画面，尚无音频、反向触控或原生 CarPlay 桌面。车机必须能打开自定义网址并访问手机所在网络。只有 ICCOA Carlink 入口的车机仍需实现后续会话协议。

## ICCOA Carlink 连接测试

车机打开 ICCOA Carlink 后，在手机查找并选择车机。App 通过蓝牙请求热点模式（1002），显示连接阶段。Personal 构建显示车机返回的 SSID，可按需查看密码并在 iOS 系统设置中加入；Release 构建还会请求系统自动加入。热点参数仅保留在本次会话的内存中。点取消或重新查找可清除。连接记录不含热点凭据。

## 安装与构建

GitHub Actions 提供 Personal 和 Release 两个未签名 IPA。免费账户先选 Personal；签名工具需保留并签署主应用和内嵌的 Broadcast Upload Extension，否则系统直播列表不会出现长安投屏。iOS 17 起。使用 XcodeGen 运行 `xcodegen generate`；自行开发签名时为主应用和扩展设置同一团队并配置匹配的 Bundle ID。Personal 无需 Hotspot Configuration 或 App Groups。

协议字段参考 [OpenXPlay-Stream](https://github.com/OpenXPlay/OpenXPlay-Stream/tree/5bedbd0713d6262c6f58cdbb75e31c2aaca2b598/rust/oxp-clink)。投屏与 HTTP 接收程序独立实现。
