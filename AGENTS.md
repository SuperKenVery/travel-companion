# Travel Companion 代理指南

本文件只提供仓库导航和修改护栏，不重复项目文档。开始工作前按任务范围阅读对应事实源：

- `TASK.md`：产品范围、技术路线、里程碑与验收标准。
- `docs/ARCHITECTURE.md`：实际架构、依赖方向、FFI、数据流与领域不变量。
- `docs/IMPLEMENTATION_STATUS.md`：当前已实现内容及尚待真机验收的边界。
- `docs/DEVELOPMENT.md`：Nix 环境、构建、测试、Xcode 与真机工作流。
- `README.md`：仓库入口和当前状态摘要。

如文档与代码不一致，先核对实际实现，再同步修正文档；不要在 `AGENTS.md` 中建立另一份架构或进度事实源。

## 修改导航

- `crates/`：平台无关的领域模型、协议、安全、存储、复制、资源、定位、IM、文档、通话与顶层 `tc-core` 协调逻辑。
- `modules/tc-*/`：纵向自包含的 capability；Rust command/event contract、fake backend、Swift Package 和 Apple framework backend 放在同一模块内。
- `bindings/tc-app-ffi/`：SwiftUI 可见的唯一 Rust 公共 ABI，以及内部 command/snapshot 到 GUI schema 的适配。
- `app-ios/TravelCompanion/Core/`：Swift FFI 门面、普通值模型和 Apple capability 路由。
- `app-ios/TravelCompanion/Features/`：只通过 `TravelCore` 发送 command、观察 snapshot 的 SwiftUI 页面。
- `app-ios/TravelCompanion/Design/`：共享视觉组件；`App/`：生命周期、权限声明与系统入口。
- `project.yml`：正式 Xcode 工程的事实源；不要手改生成的 `.xcodeproj`。
- `scripts/`、`xtask/`：标准构建与检查入口。
- `prototypes/ios-validation-lab/`：M0 Debug-only 实验归档，不是正式 App 或设计事实源；不要把其中的临时安全与持久化方案复制回正式实现。

跨边界 schema 变更必须成组核对：`tc-core`、`tc-app-ffi`、`CoreModels.swift`、`TravelCore.swift` 及相关测试。Apple capability 变更必须同时核对 Rust contract、fake backend、Apple backend 和 `AppleCapabilityRuntime` 路由。

## 架构护栏

- 保持依赖方向：SwiftUI → `TravelCore` → `tc-app-ffi` → `tc-core` → 领域 crate/capability contract → Apple backend。SwiftUI 不直接操作无线电、socket 或数据库，`tc-core` 不依赖 Apple 类型。
- `AppleCapabilityRuntime` 只是 command/event 薄路由；业务规则放在 `tc-core` 或对应领域 crate，不要建立集中实现全部 Apple API 的巨型 adapter。
- Apple framework 对象留在各 backend 的 actor/queue 上，不跨 FFI；异步结果通过带 request ID 的 event 返回，Rust panic 不得越过 FFI。
- BLE 只承载认证后的小型控制消息；事件正文、资源和实时音频走 Bonjour/Network framework peer-to-peer 数据面。不得引入公网关键路径、APNs、云服务或 `MultipeerConnectivity` fallback。
- 可同步业务修改先作为不可变事件签名并落盘，再复制；原始事件日志是事实源，UI snapshot 不是。relay 持有副本不等于目标已送达。
- GPS、UWB 和通话状态保持隔离。UWB 方向缺失时必须明确回退到 GPS 方位，不能保留旧箭头；进入后台必须结束 UWB。
- `Trip.md` lease 不是强一致锁；分区产生的冲突 revision 必须保留。
- 首版只支持 iOS 26、带 UWB 的 iPhone 真机。不要增加旧系统、Simulator、iPad、Mac Catalyst、Android 或第二套传输栈。

## 验证与修改纪律

工具链由 Nix flake 管理。标准全量检查：

```sh
nix develop --command ./scripts/check.sh
```

先运行受影响 crate/module 的定向测试；涉及 FFI、Swift、Apple backend、`project.yml` 或公共装配时运行全量检查。generic iPhoneOS 构建、单元测试和 fake backend 都不能替代 BLE、AWDL、后台定位、UWB、CallKit、锁屏、音频或能耗的多真机验证。

- 保持 Swift 6 严格并发无警告和 Rust Clippy warnings as errors。
- 协议、持久化和跨边界改动应覆盖重复、乱序、过期、丢失、重连与失败路径。
- 报告中区分“存在测试”“本次检查通过”和“真机验收通过”；实现进度只更新 `docs/IMPLEMENTATION_STATUS.md`。
- 不提交 `target/`、`build/`、`DerivedData/` 或生成的正式 `.xcodeproj`。
- 修改前检查 `git status`；只触碰任务所需文件，不覆盖、回滚或格式化用户的无关改动。
