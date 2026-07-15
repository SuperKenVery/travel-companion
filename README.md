# Travel Companion

Travel Companion 是一个面向 iOS 26、UWB iPhone 的离线同行实验性 App。产品目标是让群组、定位、聊天、语音通话、地点标注和 `Trip.md` 通过附近设备间的 BLE 控制面与 Bonjour/AWDL 数据面工作，而不依赖互联网账户、云同步、APNs 或公网服务。

> 当前状态：仓库已经按 [`TASK.md`](TASK.md) 第 12 节建立 Rust-first polyglot 正式工程，并落下覆盖 M1–M5 的领域逻辑、Apple backend、GUI FFI 和 SwiftUI 界面。这里的“已实现”只表示代码路径存在并有相应的自动化检查；它不表示第 14 节真机验收已经通过。正式 App 仍需要两台及以上真机完成 BLE、AWDL、后台定位、UWB、后台提醒和离线通话验证，也尚未完成 M6 发布准备。

## 从这里开始

仓库工具链只通过 `flake.nix`/`flake.lock` 提供。除主机 Xcode 与 iPhoneOS SDK 外，不应另行使用全局 Rust、XcodeGen、SQLite 或真机工具作为项目工作流。

```sh
nix develop
./scripts/check.sh
```

也可以从 shell 外执行同一检查；命令会明确进入 devShell：

```sh
nix develop --command ./scripts/check.sh
```

`scripts/check.sh` 依次运行 Rust 格式、Clippy、workspace tests、XcodeGen，以及无签名的 generic iPhoneOS `build-for-testing`。它是构建门禁，不会替代真机无线电、锁屏、音频路由或能耗实验。

完整环境说明见 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)。

## 架构概览

```text
SwiftUI feature views
        |
        v
TravelCore.swift
        |
        | public UniFFI object + listener
        v
app-ffi  --->  travel-core
                    |
                    +--> domain/store/replication/resource crates
                    |
                    +--> module UniFFI foreign traits
                                      |
                           typed operation/event calls
                                      |
                                      v
                    AppleCapabilityRuntime (actor adapters)
                                      |
          +---------------------------+---------------------------+
          v             v             v             v             v
       Bluetooth   Peer transport   Location       UWB      Notifications/
       Swift pkg     Swift pkg      Swift pkg    Swift pkg   CallKit/Keychain
```

- `crates/` 放置平台无关的模型、密码学、入群、协议、SQLite 事件日志、复制、资源、定位逻辑、IM、文档、通话与顶层核心。
- `modules/*/` 是纵向自包含的 polyglot capability module：同一目录含 Rust 语义 API、fake backend、Swift Package 与 Apple framework 实现。
- `bindings/app-ffi/` 是 GUI 可见的唯一 Rust UniFFI 门面，并聚合各 module 的私有 foreign-trait binding。SwiftUI 不直接依赖内部 crate。
- `app-ios/TravelCompanion/` 只负责 SwiftUI、App 生命周期、权限文案，以及把 UniFFI callback 有序送到相应 Apple backend actor。
- `project.yml`、`scripts/` 和 `xtask/` 负责可重复装配；生成的 Xcode 工程与构建产物不作为源码提交。

更精确的依赖方向、FFI 层次与数据流见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 当前实现范围

| 阶段 | 正式工程中已有的代码 | 尚不能宣称完成的部分 |
| --- | --- | --- |
| M0 | Debug-only 技术验证工程已归档到 `prototypes/ios-validation-lab/` | 归档中没有两机/四机实验结论；正式架构仍需重新做真机基线 |
| M1 | 身份/PAKE、群组、BLE/peer transport、事件存储、复制与资源基础设施 | 2–4 台真机入群、断线补同步、无公网审计 |
| M2 | 旅行会话、Core Location、UWB、通知、精确定位流程和同行雷达 | 锁屏/后台成功率、GPS/UWB 降级、权限与能耗真机验证 |
| M3 | 群聊/私聊、文字与媒体 UI、资源存储/分块、提示和同步处理代码 | 后台 `dataAvailable` 端到端、媒体中断续传与多设备到达状态 |
| M4 | 通话状态机、BLE 信令、CallKit/音频 backend 与实时传输代码 | 无互联网双机通话、锁屏来电、路由/中断/重连测试 |
| M5 | 地点事件与离线列表、MapKit 可选增强、`Trip.md` revision/lease/conflict UI | 多设备同步、无底图验收、网络分区冲突保全验证 |

详细证据和边界见 [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)。M6 的 2/4/8 设备、长时间后台、Energy Log、磁盘/权限故障、诊断导出、本地化和发布检查尚未完成。

## M0 原型归档

[`prototypes/ios-validation-lab`](prototypes/ios-validation-lab) 是第 11 节实验 harness，不是正式 App，也不是正式核心的事实源。归档 README 记录了一次 generic iPhoneOS `build-for-testing`，但明确没有给出至少两台设备的实验结果。

原型中的 Debug TLS identity、PIN 直接派生密钥、单 cursor 与 JSON 文件存储只用于探索 Apple API；这些设计不得复制回正式实现。正式工程使用独立的领域/复制/存储层与 Keychain capability contract。

## 平台与验收边界

- 目标是 iPhoneOS 26.0；项目不提供 Simulator、iPad、Mac Catalyst、iOS 25 或 Multipeer Connectivity fallback。
- MapKit 底图只是增强层。离线承诺针对坐标、同行雷达、地点列表和同步，不承诺下载 Apple 离线地图包。
- 系统强制退出、无线电关闭、权限撤回或不给予后台执行时间时，不承诺即时位置、消息提醒或来电。
- 单元测试和无签名构建不能证明 AWDL 实际被选择、BLE 能在锁屏唤醒、UWB 正确降级或 CallKit 音频端到端可用。
- 当前仓库不是 M6 完成品，不应作为可发布、稳定或已通过第 14 节验收的版本描述。

## 目录

```text
crates/                     Rust 领域与基础设施
modules/*/               Rust capability + Apple Swift Package
bindings/app-ffi/        面向 GUI 的公共 UniFFI 门面与生成 binding
app-ios/TravelCompanion/    SwiftUI App 与薄装配层
app-ios/TravelCompanionTests/
prototypes/ios-validation-lab/
docs/
scripts/
xtask/
```
