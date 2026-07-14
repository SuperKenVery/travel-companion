# Travel Companion — 第 11 节真机技术验证

这是 `TASK.md` 第 11 节的 Debug-only vertical slice。它不是产品 UI，也不宣称已经在当前仓库中得到两机/四机实验结论；它提供可以安装到 iOS 26 真机、执行实验并导出原始数据与 P50/P95 汇总的代码。

## 已实现的验证链路

- Wi‑Fi Aware App-to-App 系统配对、paired device 观察，以及彼此独立的“允许配对 / 启动发布 / 查找连接”三段流程、多连接与重连日志。
- bulk 数据通道：新版 `NetworkConnection` + `Coder` over `TLS`，用于 ping、文字事件、cursor anti-entropy 和带 SHA-256 校验的 64 KiB 分块文件。Debug vertical slice 使用固定测试 identity 并固定验证测试证书，避免裸 `TLS()` listener 因缺少 server identity 而无法握手。
- realtime 语音通道：Wi‑Fi Aware UDP + `Coder`，使用 `.realtime` 和 `.interactiveVoice`，接通后发送真实麦克风 PCM16 数据。
- BLE central/peripheral 双角色、固定 service/characteristic UUID、后台模式、state restoration、订阅通知和 GATT 写入。
- BLE 控制消息具备版本、UUID、发送者、序号、TTL、AES-GCM、分片/重组、ACK、去重和 30 分钟重复请求基准任务。
- `dataAvailable` → Wi‑Fi Aware cursor 拉取 → 本地事件去重/持久化 → 本地通知；失败时生成通用通知。
- 三种定位策略：仅 BLE 按需、`CLBackgroundActivitySession` 自适应更新、混合方案；记录响应状态、样本年龄、水平精度和延迟。
- UWB discovery token 经已配对数据面交换；每个 peer 单独 `NISession`；前后台切换、超距、暂停、过期、忽略和频率限制均有状态与日志。
- BLE `callOffer` → CallKit 本地来电 → answer → realtime Wi‑Fi Aware 音频；CallKit 失败时记录可复现边界。
- JSON Lines 持久化日志、每分钟电量/热状态采样、P50/P95/成功率汇总和 JSON 导出。

## 工程要求

- Xcode 26（当前已用 Xcode 26.6、iPhoneOS SDK 26.5 编译）。
- iOS Deployment Target 26.0，Swift 6 strict concurrency。
- 仅 iPhone 真机。Wi‑Fi Aware 和 UWB 能力以运行时检查为准。
- 至少两台设备才能完成端到端实验；11.1 的多连接上限需要四台设备。
- 所有设备安装同一团队、同一 bundle ID 签名的 Debug 构建。

工程由 [project.yml](project.yml) 生成。仓库的 devShell 已包含 `xcodegen`、`libimobiledevice` 和 `openssl`：

```sh
nix develop
xcodegen generate
open TravelCompanion.xcodeproj
```

在 Xcode 中为 `TravelCompanion` target 选择开发团队并确认 Wi‑Fi Aware capability 对应的 provisioning profile 已包含 `Publish` 与 `Subscribe`。如需改 bundle ID，请在 `project.yml` 修改 `PRODUCT_BUNDLE_IDENTIFIER` 后重新生成工程，不要只改生成的 `.xcodeproj`。

## 两台设备的首次连接

1. 两台 iPhone 都打开 App，点“开始全部验证”，按需授予蓝牙、本地通知和定位权限。
2. A 机在“连接”页执行第 1 步“打开系统配对授权”，保持系统配对界面可见。
3. B 机执行第 3 步“打开系统设备查找”，选择 A，并在两端完成系统确认。只有主动连接的 B 机会选择 peer。
4. A 机完成配对后关闭系统界面，执行第 2 步“启动数据与语音服务”；A 不需要选择 peer，服务对已配对设备发布。
5. B 的系统查找拿到 A 的 endpoint 后会建立数据连接，并只针对同一 peer 查找语音服务。等待“数据连接”显示 `ready` 且计数变为 1。
6. 日志中 `pathAudit` 必须成功；失败或缺少 Wi‑Fi Aware path 时不能把本次结果计为通过。

配对是系统永久配对，但发布和查找是本次实验会话的显式操作。App 重启后，发布端重新执行第 2 步，主动连接端重新执行第 3 步；界面会分别显示数据发布、语音发布、设备查找和数据路径状态。

建议在配对完成后关闭蜂窝数据并离开已知 Wi‑Fi，保留 Wi‑Fi 与蓝牙开关开启，证明链路不依赖互联网或共同接入点。

## 11.1 Wi‑Fi Aware 实验

在“连接”页执行：

1. 连续点击“测小消息 RTT”，至少采集 30 次；导出 `smallMessage/roundTrip` 的 P50/P95。
2. 发送 5 MiB 分块文件；确认接收端出现 `receiveComplete`，发送端出现 `acknowledged` 与 `bytesPerSecond`。
3. 文件传输中让一台设备离开范围再回来，重新发送 manifest 后会根据已落盘 chunk 返回缺块清单。
4. 2 台、4 台分别记录 `pairedDevices`、`dataConnection`、重连与 path audit。
5. 通话时另行检查 `voicePathAudit`；bulk 与 realtime 的能耗应分开采集。

TLS/Coder 与分块资源使用同一数据协议；语音单独使用 realtime UDP，避免让普通同步长期占用 realtime 模式。

## 11.2 BLE 后台实验

1. 确认 Central、Peripheral 均为 `poweredOn`，双方出现 GATT ready/subscribed。
2. 分别在前台、后台、锁屏状态从另一台设备发送位置、精确定位、`dataAvailable` 和 `callOffer`。
3. 在发送端选择“开始 30 分钟重复请求”，然后锁定接收端屏幕；结束后导出成功率与 ACK/响应 P50/P95。
4. 连续发送多条“文字 + BLE dataAvailable”，确认重复 hint 被去重、内容只插入一次。
5. 模拟 hint 丢失时，在接收端点击“主动 anti-entropy 拉取”，确认仍补齐事件。
6. 让系统回收 App 后重新靠近；检查 `stateRestoration`、启动原因和补同步记录。
7. 用户从 App Switcher 强制退出后，必须单独记为“不保证唤醒”，不能与系统终止混为一谈。

## 11.3 后台定位对比

每种策略都使用相同行走路线、时段、设备摆放和 BLE 请求序列：

1. 选择策略并点“开始”。
2. 运行路线与请求序列；2 小时实验期间不要清日志。
3. 记录 `requestResponse`、`sample`、service/background diagnostics、每分钟 battery/thermal 数据。
4. 结束并导出，再清日志后进行下一策略。
5. 比较响应率、sample age、horizontal accuracy、P50/P95 和电量变化。实验未推翻基线时采用 hybrid。

App 内电量采样只提供粗粒度对比；正式能耗结论必须同时用 Instruments Energy Log 采集，并在导出文件旁记录 trace 名称。

## 11.4 UWB 实验

1. 查看者点“经 BLE 请求精确位置”。
2. 被查看者在后台时应出现本地通知；从通知进入 App 后，在“UWB”页确认请求。
3. 点“提供精确位置”；两端经 Wi‑Fi Aware 交换 discovery token，并启动各自 `NISession`。
4. 记录距离、方向、近距离、超距、遮挡、横竖屏和 session suspension/resume。
5. 任一端进入后台后，UI 必须清除 UWB 值并显示 GPS fallback。
6. 分别验证通知拒绝、忽略、过期、60 秒频率限制和暂停共享。
7. 四台设备并发确认请求，依据 `activeSessionCount` 与 invalidation 记录冻结调度上限，不按机型猜测。

## 11.5 离线来电实验

1. 接收端置于前台、后台和锁屏，发送端点“向已连接成员发起离线来电”。
2. 确认 CallKit 来电呈现延迟；接听后确认 `voiceConnection` ready 和 `audioSession/activated`。
3. 双向说话，检查 `voicePacket` 成功率和延迟；测试听筒、扬声器、蓝牙耳机与中断。
4. CallKit 不能呈现时，导出的 `incomingCall/report` 会包含错误与 `missedCallOnNextLaunch` fallback，产品不得引入互联网推送补救。
5. App Review 合规性仍需在 M4 前用最终产品用途、权限文案和审核材料验证；代码不能替代审核结论。

## 日志与结果

“日志”页显示每个实验名的尝试数、成功率、P50/P95、总字节数和最近事件。点“导出 JSON”后使用系统分享面板导出；也可通过 Finder 的文件共享读取 `Documents/Diagnostics`。

日志会包含坐标和设备实验 ID，只能作为开发数据妥善保存，不应直接上传公共 issue。

## 自动检查

```sh
xcodebuild \
  -project TravelCompanion.xcodeproj \
  -scheme TravelCompanion \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/travel-companion-derived \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

单元测试覆盖 AES-GCM 控制帧的分片/乱序重组与篡改检测、事件去重、资源分块完整性以及百分位统计。因为首版明确不支持 Simulator，测试执行应选连接的 iOS 26 真机；上面的命令可在没有签名配置时先验证 App 与测试 bundle 均能编译。

## 当前环境验证边界

本次实现已通过 iPhoneOS 26.5 的 App build 和 test bundle `build-for-testing`。当前机器虽然能看到一台已配对 iPhone 13 和有效 Apple Development 证书，但 Xcode 账户 token 缺失，`com.ken.TravelCompanionValidation` 也没有 provisioning profile，因此无法从命令行安装/执行。重新登录 Xcode 开发者账户并为 bundle ID 创建包含 Wi‑Fi Aware entitlement 的 profile 后，即可继续真机运行。

## 安全说明

BLE vertical slice 使用代码内固定的 Debug 实验密钥，以验证加密、认证失败、分片、TTL 和去重链路。它不是正式群组密钥管理，不能进入发布构建；产品实现必须替换为第 6.1 节定义的本机身份、配对握手和每群密钥。诊断 UI 在 Release 构建中不可见。

Wi‑Fi Aware 数据通道的 TLS identity 同样仅用于 Debug 真机验证：固定私钥只在 `DEBUG` 条件下编译，证书 pin 用于验证 TLS/Coder framing，而不是正式成员身份。产品实现必须在入群握手后为每个群组/成员建立独立凭据。
