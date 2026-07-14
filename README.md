# Travel Companion — 第 11 节真机技术验证

这是 `TASK.md` 第 11 节的 Debug-only vertical slice。它不是主 App UI，也不宣称已经得到两机/四机实验结论；它提供可安装到 iOS 26 真机、执行实验并导出原始数据与 P50/P95 汇总的代码。

## 当前技术路线

- Core Bluetooth 同时承担附近发现和应用层入群。创建者生成 6 位 PIN；加入者只输入一次。PIN 经 HKDF 派生群组密钥，BLE `groupHello` 经 AES-GCM 认证后确认成员，设备仅持久化派生凭据。
- 每台已入群设备自动发布并浏览两个 Bonjour 服务：`_tc-validate._tcp` 与 `_tc-voice._udp`。listener、browser 和 connection 都设置 `includePeerToPeer`/`peerToPeerIncluded = true`，允许 Network framework 选择 AWDL。
- 每对设备按稳定 device ID 只由一侧主动拨号，另一侧接受连接；服务再次出现或连接失败时自动重连，无需系统 Wi‑Fi Aware 配对或逐对选择 peer。
- bulk 数据通道使用 iOS 26 `NetworkConnection` + `Coder` over TLS；首包必须通过群组密钥 HMAC，之后才承载 ping、文字、cursor anti-entropy、UWB token 和带 SHA-256 校验的 64 KiB 分块文件。
- realtime 语音通道使用 Bonjour UDP + `Coder` 和 `.interactiveVoice`，每个音频包都验证群组 HMAC 后才播放。
- BLE 控制消息具备版本、UUID、发送者、序号、TTL、AES-GCM、分片/重组、ACK、去重、state restoration 与系统自动重连。
- `dataAvailable` → Bonjour 数据连接 cursor 拉取 → 本地事件去重/持久化 → 本地通知；失败时生成通用通知。
- 其余 vertical slice 包括三种后台定位策略、UWB 精确定位、CallKit 离线来电、JSON Lines 日志与能耗采样。

## 工程要求

- Xcode 26、iOS Deployment Target 26.0、Swift 6 strict concurrency。
- 仅 iPhone 真机；UWB 能力以运行时检查为准。
- 至少两台设备完成端到端实验；多连接上限验证建议四台设备。
- 所有设备安装同一团队、同一 bundle ID 签名的 Debug 构建。

工程由 `project.yml` 生成，devShell 包含 `xcodegen`、`libimobiledevice` 和 `openssl`：

```sh
nix develop
xcodegen generate
open TravelCompanion.xcodeproj
```

不再需要 Wi‑Fi Aware entitlement。`Info.plist` 已声明本地网络用途、`NSBonjourServices`、蓝牙用途与 central/peripheral 后台模式。

## 首次入群与自动连接

1. 所有 iPhone 打开 App，在“总览”点“开始全部验证”，授予蓝牙和本地网络权限。
2. A 机在“连接”页点“创建群组并生成 PIN”，把 6 位 PIN 告知同行者。
3. B、C 等设备各自输入一次 PIN 并点“加入群组”。附近 BLE 链路收到并成功解密 `groupHello` 后，“PIN 已认证成员”会更新。
4. 入群后无需再操作：每台设备会自动发布/浏览 Bonjour，等待数据连接变为 ready。
5. App 重启会读取派生群组凭据并恢复 BLE 与 Bonjour。退出群组会删除本机凭据并停止群组网络任务。

为了验证无基础设施场景，建议关闭蜂窝数据、离开已知 Wi‑Fi，但保留 Wi‑Fi 与蓝牙开关开启。`pathAudit` 会记录可用 interface、`awdlObserved`、`usesWiFi` 和 `peerToPeerIncluded`。`peerToPeerIncluded=true` 代表允许 P2P；是否实际选择 `awdl0` 由系统决定，应以真机 path audit 为准。

## 11.1 Bonjour / AWDL 实验

1. 连续点击“测小消息 RTT”至少 30 次，导出 `smallMessage/roundTrip` 的 P50/P95。
2. 发送 5 MiB 分块文件，确认接收端出现 `receiveComplete`，发送端出现 `acknowledged` 与 `bytesPerSecond`。
3. 让一台设备离开范围再回来，确认 Bonjour 服务重现后数据/语音连接自动恢复；分块资源通过缺块清单续传。
4. 分别用 2 台、4 台记录 BLE 认证成员、Bonjour 发现成员、连接数、重连与 path audit。
5. 通话时检查 `voicePathAudit`；普通同步与实时语音的能耗分开采集。

## 11.2 BLE 后台实验

1. 确认 Central、Peripheral 均为 `poweredOn`，双方出现 GATT ready/subscribed 和 `groupPairing/authenticated`。
2. 分别在前台、后台、锁屏状态发送位置、精确定位、`dataAvailable` 和 `callOffer`。
3. 运行 30 分钟重复请求，导出成功率与 ACK/响应 P50/P95。
4. 验证重复 hint 去重、hint 丢失后的主动 anti-entropy，以及系统回收后的 state restoration。
5. 用户从 App Switcher 强制退出应单独记录为“不保证唤醒”。

## 11.3–11.5 其他实验

- 后台定位：三种策略使用相同行走路线和请求序列，比较响应率、sample age、精度、P50/P95 与能耗。
- UWB：双方确认后通过 Bonjour/TLS 数据面交换 discovery token；任一端进后台即回退 GPS。
- 离线来电：BLE 发送 offer/answer/end，接听后通过 Bonjour peer-to-peer UDP 发送音频；验证锁屏、音频路由和短暂断连。

## 自动检查

```sh
xcodebuild \
  -project TravelCompanion.xcodeproj \
  -scheme TravelCompanion \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

2026-07-14 已用 iPhoneOS 26.5 SDK 通过 App 与测试 bundle 的 `build-for-testing`。单元测试覆盖 PIN 派生、AES-GCM 控制帧、篡改检测、事件去重、资源完整性与百分位统计；无线电行为仍必须在至少两台真机上验证。

## 安全边界

当前 6 位 PIN 方案用于验证“每人入群一次”的交互和群组隔离，不足以抵抗离线穷举。正式产品应采用 PAKE 或带邀请者公钥、随机群组密钥、尝试次数限制与密钥轮换的入群协议。

Debug TLS identity 和证书 pin 只验证 TLS/Coder framing，不代表正式成员身份。发布实现必须使用每群/每成员凭据，并把派生群组密钥从 `UserDefaults` 迁移到 Keychain。
