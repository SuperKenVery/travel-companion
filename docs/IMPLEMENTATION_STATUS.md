# Implementation status

本文按 [`TASK.md`](../TASK.md) 第 13 节核对正式工程的源码范围。状态描述的是“仓库里有什么”，不是产品验收结论。

## 状态口径

- **源码具备**：正式 workspace 中存在领域逻辑、平台 backend、FFI 或 UI 路径。
- **局部自动化**：存在可在开发机运行的单元/模型测试；不代表设备无线电或后台行为。
- **待真机验收**：必须按第 11/14 节在两台及以上设备采集证据，不能由 mock、编译或单元测试替代。
- **未完成**：仓库尚无足以支持该结论的实现或报告。

M1–M5 当前整体应描述为“正式架构下的实现候选已落盘，验收待完成”，而不是“里程碑已交付”。

## M0：可行性验证

状态：**原型已归档；仓库内没有完整实验结论。**

[`prototypes/ios-validation-lab`](../prototypes/ios-validation-lab) 保存 Debug-only vertical slice，覆盖 BLE、Bonjour/AWDL、后台位置、UWB、`dataAvailable` 与离线来电实验入口。归档 README 记录了 2026-07-14 的 generic iPhoneOS `build-for-testing`，并明确说明没有给出两机/四机实验结论。

因此：

- 可以把它用于复现 API 实验、采集日志和对照历史代码；
- 不能把一次无签名构建写成第 11 节真机验证通过；
- 原型的 Debug TLS identity、PIN 派生密钥、单 cursor 与 JSON 文件存储不是正式设计；
- 正式 Rust-first App 仍需重新建立可复现的真机基线。

## M1：群组、连接与事件同步

状态：**源码具备，局部自动化，待多设备验收。**

正式工程中已有：

- `tc-model`、`tc-crypto`、`tc-group-auth`：稳定 ID、事件模型、签名/加密 primitive 与 PAKE 入群 primitive；
- `tc-store`、`tc-replication`：SQLite 原始事件、sender sequence、签名验证、frontier/sparse gap、relay 与逐目标 delivery 状态；
- `tc-resources`：manifest/chunk 校验、磁盘恢复、重试、取消、原子落盘与 content-addressed object；
- `tc-bluetooth` 与 `tc-peer-transport`：平台无关 command/event、fake backend 和 Apple Core Bluetooth/Network framework backend；
- `tc-core` 与 SwiftUI：创建群、PIN 加入、离群、成员/连接快照和诊断入口。

自动化主要验证领域不变量和 fake backend contract，例如事件去重、签名、精确缺口、relay 不等于目标送达、资源损坏恢复与异步提交。它没有验证：

- 2–4 台 iPhone 在无互联网路由时创建/加入同一正式群组；
- BLE identity 与 Bonjour/AWDL connection 在真实设备上稳定关联；
- 离开范围、进后台、锁屏和重启后的补同步；
- 抓包确认正式 App 关键路径不访问公网；
- 重复、乱序和丢失控制消息在多设备运行中的副作用。

## M2：定位核心

状态：**源码具备，算法有局部自动化，待后台/UWB 真机验收。**

正式工程中已有：

- `tc-location` 及 Apple backend：`CLServiceSession`、`CLBackgroundActivitySession`、`CLLocationUpdate`、缓存样本和按需采样 command/event；
- `tc-ranging` 及 Apple backend：Nearby Interaction session、discovery token、距离/方向独立字段与前后台终止路径；
- `tc-location-logic`：GPS 距离/方位与 UWB 距离/方向的显式来源、stale 和降级逻辑；
- `tc-notifications`：本地通知 command/event 与合并键；
- `tc-core` 与 SwiftUI：旅行开始/结束、位置共享开关、BLE 位置/精确定位请求、确认/拒绝/超时、同行雷达、成员详情和 blocker UI。

仍需真机证明：

- 权限首次请求、撤回与系统设置变更后的状态；
- 前台、后台、锁屏下的位置样本 age、成功率和电量影响；
- BLE 请求命中缓存、best-effort 刷新和 deadline timeout；
- 双方确认后的 UWB token 交换、距离/方向缺失、遮挡/超距和 GPS 回退；
- 任一 App 进入后台后立即结束精确测距；
- 通知权限关闭、请求合并和频率限制的实际用户路径。

## M3：IM

状态：**源码具备，存储/协议有局部自动化，待端到端后台与资源传输验收。**

正式工程中已有：

- `tc-im` 的群聊/私聊值模型与消息 materialization；
- `tc-core` 的消息/manifest 事件发布、`dataAvailable`、wire digest/event/ack/resource-request/chunk 处理和本地通知 command；
- `tc-resources` 的持久 manifest、分块校验、缺块恢复、取消/重试 primitive；
- SwiftUI 的会话列表、文字发送、PhotosPicker、真机相机、AAC 语音录制/试听、图片缩略图、语音播放和资源进度/取消/重试 UI。

尚未由仓库证据证明：

- 群聊与私聊在两台以上真机前台直连、网络分区和重连后的完整行为；
- 锁屏接收方由认证 BLE `dataAvailable` 唤醒，再通过 Bonjour/AWDL 拉取正文；
- 提示合并、cursor 补齐和本地通知摘要在真实后台窗口内完成；
- 图片缩略图优先、原件/长语音断点续传、校验失败、取消与重试的多设备传输；
- delivery UI 与每个目标设备实际持久化确认一致。

## M4：一对一语音通话

状态：**状态机和 Apple/传输代码具备，待两机通话验收。**

正式工程中已有：

- `tc-call` 的 offer/answer/reject/end 状态机、冲突处理和重连状态；
- `tc-call-system` Apple backend 的 CallKit transaction、`AVAudioSession`、音频 engine、route/interruption 事件与轻量 jitter 处理；
- BLE call signal 与 peer transport realtime frame 的 core 路由；
- SwiftUI 的呼叫、接听、拒绝和结束入口。

尚未由正式 App 的真机报告证明：

- 无互联网条件下的双向实时音频；
- 后台/锁屏来电、接听后数据面建立和系统 UI 生命周期；
- 听筒、扬声器、蓝牙耳机与媒体服务重置；
- 双方同时呼叫、短暂断连、丢帧和 jitter buffer 行为；
- 延迟、丢包、音质、能耗与通话结束后的资源释放。

## M5：地点与共享文档

状态：**源码具备，领域规则有局部自动化，待多设备/分区验收。**

正式工程中已有：

- 地点创建、编辑、删除事件和 materialized snapshot；
- 离线优先的地点坐标列表，以及只作为增强层的 MapKit 成员/地点视图；
- `tc-document` 的不可变 revision、内容哈希、短期 lease、确定性 head 和冲突副本保留；
- `Trip.md` 分离的预览/原生编辑 UI、lease 状态、保存、冲突比较和未保存保护。

仍需真机/多副本证明：

- 地点在多设备间创建、编辑、删除和权限规则；
- 没有可用地图瓦片时，雷达、坐标和地点列表仍覆盖全部关键操作；
- 正常连通时只有 lease holder 可编辑；
- 网络分区产生重叠 lease/revision 后，各副本选择同一 head 且不丢冲突内容；
- 所有成员离线重启后仍能查看最后同步 revision。

## 自动化证据的边界

正式 workspace 当前包含 Rust 单元测试，覆盖模型、密码学、PAKE、存储、复制、资源、定位、IM、文档、通话、capability fake backend、core 与 GUI FFI；iOS 测试 target 目前只有 command 编码、资源进度与空快照 round-trip 等模型测试。

标准入口是：

```sh
nix develop --command ./scripts/check.sh
```

本文件不保存一次性“绿灯”声明；应以具体提交对应的命令输出或 CI 产物为准。即使整套检查通过，也只证明 host-side 单元测试和 generic iPhoneOS 装配，不证明第 14 节设备验收。

## M6 与发布边界

M6 状态：**未完成。**

仓库已有权限文案、基础无障碍、错误态和 Debug 诊断 UI，但这些只是 M6 输入。以下工作尚无完整证据：

- 2/4/8 设备矩阵与长时间后台运行；
- 网络分区、磁盘不足、权限变化、无线电关闭和强制退出审计；
- Instruments Energy Log、CPU、网络、内存和 thermal 分析；
- P50/P95 后台成功率、同步延迟、吞吐和通话指标报告；
- 诊断导出、隐私审查、本地化、发布签名、TestFlight/App Store 准备；
- 安全审计和协议兼容/迁移策略。

因此当前版本不得描述为 production-ready、稳定版、M6 完成或已通过 `TASK.md` 第 14 节验收。
