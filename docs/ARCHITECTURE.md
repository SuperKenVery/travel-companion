# Architecture

本文描述当前仓库实际采用的依赖方向。设计来源是 [`TASK.md`](../TASK.md) 第 12 节：Rust-first multi-crate workspace、纵向自包含的 polyglot capability module，以及只观察顶层核心快照的 SwiftUI App。

## 设计约束

1. 领域状态机、协议、安全、复制、持久化和 materialization 优先放在 Rust。
2. Swift 负责 SwiftUI、Apple App 生命周期，以及每个 capability module 自己的 Apple framework backend。
3. SwiftUI 只依赖一个 `TravelCore` GUI 门面，不直接操作 Core Bluetooth、Network、Core Location、Nearby Interaction、CallKit 或内部 Rust crate。
4. Apple framework 对象不跨 capability FFI。该边界只传 typed 普通值、native capability 所需的 opaque packet/frame bytes 和 UniFFI 管理的 foreign object；业务消息类型与 GUI JSON 都在 Rust 侧终止。
5. BLE 是小型控制面；事件正文、资源和实时音频由 peer transport 数据面承载。
6. 同步事实源是不可变事件日志，不把 SwiftUI snapshot 或可变数据库行发送给成员。
7. 复制针对少量、机会式相遇的旅行设备，不实现全局事务、选主、共识或强一致锁。

## 当前依赖图

```text
TravelCompanionApp / AppShell / feature views
                    |
                    v
             TravelCore.swift
                    |
                    | TravelCoreBinding (UniFFI)
                    v
               app-ffi
             /             \
            v               v
         travel-core      module foreign traits
        +-----------+---------------------+
        |                                 |
        v                                 v
 domain/infrastructure crates      module Rust capability runtimes
 model, crypto, auth, protocol     semantic command/event + raw fake backend
 store, replication, resources            |
 location, IM, document, call              |
                                          |
                   typed methods / plain values
                                          |
                                          v
                              AppleCapabilityRuntime.swift
                              ordered actor-hop adapters
                                          |
        +------------+------------+-------+-------+--------------+
        v            v            v               v              v
 Core Bluetooth    Network    Core Location   NearbyInteraction  UN/CX/AV/Keychain
 Swift Package   Swift Package Swift Package   Swift Package      Swift Packages
```

`AppleCapabilityRuntime` 只装配七个 UniFFI foreign-trait 实现。适配器保持 command 顺序，把工作送到对应 backend 的 `MainActor`/actor，并在独立串行队列把 event 回送 Rust；它不实现群组、消息、复制、文档或通话业务规则。业务协调仍由 `travel-core` 完成。

## Rust workspace

### 领域与基础设施 crate

| crate | 责任 |
| --- | --- |
| `model` | 稳定 ID、事件 envelope、HLC、audience、delivery policy、sync digest |
| `crypto` | Ed25519、AEAD、KDF 与签名验证 primitive |
| `group-auth` | PAKE/PIN 入群 primitive、群凭据与会话材料 |
| `protocol` | 显式 protocol version、wire frame 编解码 |
| `store` | SQLite 事件、事务性 sender sequence、ACK/relay、frontier 与 sparse gaps |
| `replication` | 发布目标固化、签名 ingest、anti-entropy、逐目标 delivery 状态 |
| `resources` | manifest、hash/chunk 校验、content-addressed 磁盘对象、恢复/取消/重试 |
| `location-logic` | GPS 距离/方位、UWB 距离/方向独立来源、stale 与降级 |
| `im` | 群聊/私聊和消息内容/materialization 类型 |
| `document` | 不可变 `Trip.md` revision、lease、确定性 head 与冲突副本 |
| `call` | 一对一呼叫信令、冲突、连接与结束状态机 |
| `travel-core` | 唯一应用协调者；持久状态、用例、module command/event 与 UI snapshot |

`travel-core` 可以组合这些 crate，但不得导入 `CBPeripheral`、`NWConnection`、`CLLocation`、`NISession`、`CXCall` 或其他 Apple 类型。

### Polyglot capability module

每个 `modules/*` 目录是一个逻辑 package，而不是把所有 Apple 代码集中到 App：

```text
modules/example/
  Cargo.toml
  src/lib.rs                 # 平台无关 Rust Command/Event/Backend/FakeBackend
  src/ffi.rs                 # UniFFI foreign trait 与 Rust event sink
  Package.swift
  apple/
    Sources/TcExampleApple/  # Apple framework backend
```

当前 module 对应关系：

| module | Rust 语义 | Apple backend |
| --- | --- | --- |
| `bluetooth` | typed 控制消息、BLE envelope、分片/重组、TTL、去重、ACK | Core Bluetooth packet I/O、MTU、背压、状态恢复 |
| `peer-transport` | group hello/HMAC、连接准入、数据/实时 channel 映射 | Network framework / Bonjour / TLS、opaque TLV I/O |
| `location` | 旅行位置 session、缓存、按需样本 | Core Location |
| `ranging` | discovery token、UWB session、距离/方向 | Nearby Interaction |
| `notifications` | 本地通知发布、合并、点击事件 | UserNotifications |
| `call-system` | 系统通话、音频 route/frame、jitter 事件 | CallKit / AVFAudio |
| `secure-storage` | 小型 secret 的保存、读取、删除 | Keychain / Security |

Rust side 为各 module 提供 fake backend，以便在 host 上检查异步提交、去重、超时和状态转换。fake backend 不能替代 Apple backend 的真机 contract test。

## 两层边界

### GUI 公共 UniFFI

`app-ffi` 导出的 `TravelCoreBinding` 是 SwiftUI 面向 Rust 的唯一公共核心对象：

```text
TravelCoreBinding(config, seven platform backends, listener)
  dispatchJson(commandJson)
  snapshotJson()
  shutdown()
```

`app-ffi` 把 Swift 的紧凑 command schema 适配为 `travel-core` 用例，并把内部 snapshot 投影成稳定 GUI schema。UniFFI 管理对象、字符串和 callback 生命周期；Rust 入口仍用 panic boundary 转换错误。`CoreEventListener` 把异步状态更新送回 Swift，`TravelCore` 只观察 reply/snapshot，不再手工 drain module queue。

### Capability platform 边界

每个 module 的主 `Backend: Send + Sync` 本身就是 UniFFI foreign trait，包含 typed `capabilities` snapshot、`attachEventSink`、该 native capability 的逐项操作方法和 `shutdown`；Rust fake 与 Swift adapter 实现同一个接口，没有平行 backend、通用 `submit(bytes)` 或 fake-only capability 旁路。Rust `EventSink` 对象也以逐项 typed 方法把异步结果送回 Rust。真正的 Apple 调用仍由 module 自己的 backend 执行；Rust 在释放 core mutex 后才调用 backend，因此它即使在操作方法栈内同步报告 event 也不会死锁。

这里的“逐项方法”按 platform capability 分层，而不是照搬应用消息。`BluetoothBackend` 暴露 `sendPacket`/`packetReceived`，Swift 只处理 MTU、write/update 和背压；Rust `BluetoothRuntime` 把 `SendControl(ControlMessage)` 编码、分片并处理 TTL/ACK/去重。`PeerTransportBackend` 暴露 scoped discovery、provisional connection 与 `sendFrame`/`frameReceived`；Rust `PeerTransportRuntime` 持有 group key，生成/验证 hello、执行连接准入并把 audio TLV 内的 realtime wire frame交给 `protocol`。因此 `invitationInfo`、`joinHello`、`groupControl`、group HMAC 和 realtime JSON 都不属于 Apple backend contract。

`travel-core` 为了保持 capability 无关，内部 outbox/inbox 仍可使用 `module + serde_json::Value`。这个动态表示必须在 Rust 的 `app-ffi` 内终止：binding 将 command 解成对应 module 的 Rust enum，再经需要的 Rust runtime 降成 platform operation；typed EventSink 则先进入 runtime，再物化为 semantic Rust event。整条 command/event 不得编码成 JSON/Data 动态 envelope 跨 capability UniFFI，也不得成为 Apple module 的公开 contract。跨边界的 bytes 必须是 native framework 直接搬运/消费的原子值，例如 BLE packet、Network TLV frame、discovery token、PCM 或 secret；其应用含义由 Rust 负责编解码。

`shutdown` 的同步返回表示 backend 已停止接受新命令，并已按原命令顺序安排平台资源清理；actor/MainActor 上的实际 teardown 可以随后异步完成。Rust travel-core 会先关闭事件入口，所以清理期间到达的迟发事件只会被丢弃，而不会重新驱动状态机。

这意味着当前代码中应区分：

- `app-ffi`：GUI 与顶层 Rust 核心的公共边界；
- module UniFFI foreign trait：某一个 capability 的私有 platform 边界；
- `AppleCapabilityRuntime`：薄装配和并发适配，不是集中业务 adapter。

不得为了方便把 module 私有 framework 对象或生成类型提升为 SwiftUI API。

## Command/event 生命周期

### 用户操作

```text
SwiftUI
  -> await TravelCore.send(CoreCommand)
  -> TravelCoreBinding.dispatchJson
  -> travel-travel-core 更新事务性领域状态并生成 module commands
  -> 释放 travel-core lock
  -> app-ffi 解出 module command
  -> 对应 Backend typed operation method
  -> Apple adapter 串行跳到 backend actor
```

Apple API 通常只接受异步请求。Backend 操作方法只同步确认已接受，不等待 framework 结果；请求相关的完成、失败和超时在适用时携带 request ID，主动状态/数据变化按各自 typed 字段通过 EventSink 返回。

BLE 入群消息只暴露随机 admission ID 和 PAKE 握手材料；真实 group ID、名称与群密钥位于 PAKE 会话封装的 credential 内。入群完成后的 presence、位置请求、精确定位请求、同步提示和通话信令统一封装为 `groupControl`，使用当前 group key 做 XChaCha20-Poly1305 加密，并校验成员、接收者、epoch、TTL 与持久化 replay ID。只有解密后的 presence 才能把 Core Bluetooth 的临时 handle 绑定到稳定 `PeerId`。

### Apple framework 回调

```text
Apple delegate / async sequence
  -> module typed Swift event
  -> adapter event relay（非 MainActor 串行队列）
  -> Rust EventSink typed method
  -> travel-travel-core 更新状态/materialization
  -> CoreEventListener(AppSnapshot reply)
  -> TravelCore
  -> Swift Observation 刷新 feature view
```

Swift backend 在自己的 actor/queue 上持有 framework 对象。Rust 只看到 peer handle、request ID、坐标、token bytes、packet/frame bytes 和普通状态值；Swift 不解析这些 packet/frame 的应用消息种类。

## 事件、复制与 materialization

业务写入遵循以下顺序：

1. `travel-core` 把消息、地点、revision、lease 或控制语义转换成不可变 payload。
2. store 在同一事务中分配 `(sender_id, sender_sequence)`；replication 把完整 unsigned event 编码为不可变 `eventBytes`，直接对这些 bytes 签名，并把外层 signer、原始 bytes 与 signature 一起落盘。
3. `replication` 固化发布时的目标成员，并计算发送计划。
4. peer transport 发送 opaque protocol frame；接收端只从未认证外层读取 signer 以选择成员公钥，先对收到的原始 `eventBytes` 验签，成功后才解析事件，并继续核对内外 sender、group/epoch 和重复项再持久化。存储转发不得重新序列化被签名内容。
5. 只有发布目标设备验证并落盘后才算 target delivery；relay 保存副本不能显示为目标已送达。
6. 重连双方交换每个 sender 的连续 frontier 与精确 sparse gaps，补齐事件和可转发 ACK。
7. materializer 从原始事件重建会话、地点与文档 snapshot；UI 不成为第二事实源。

delivery policy 分为：

- `durable`：消息、地点、revision、tombstone 等需要补同步的事实；
- `latestValue`：位置/presence 等可由新值取代并带 TTL 的状态；
- `transient`：精确定位和通话信令等过期后不补发的点对点事件。

上述是当前领域/协议实现的语义目标。多设备断线、relay 与 ACK 路径仍需真机/集成验证，见 [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)。

## 资源存储

`resources` 把资源拆成带 SHA-256 的 manifest/chunk，并在 App Support 下维护：

```text
Resources/
  transfers/<resource-digest>/manifest.json
  transfers/<resource-digest>/chunks/
  objects/<content-hash>.resource
```

临时写入采用原子替换；重启会重新验证已存在 chunk；完成对象按内容 hash 去重；取消删除 partial transfer，重试保留已验证 chunk。`travel-core` 发布持久 manifest 事件、按精确缺块发送 `ResourceRequest`、验证 `ResourceChunk`，并允许已经持有完整对象的认证 relay 提供 chunk；GUI FFI 投影 core 的 canonical 资源状态，只在新建本地媒体尚未进入 snapshot 时保留短暂的来源元数据 fallback。真实多设备传输、后台中断和磁盘压力仍属于待验收范围。

## 定位与通话隔离

- 普通 GPS 位置、UWB ranging 和通话分别是独立状态机。
- GPS snapshot 携带坐标、精度、采样时间、来源和 stale。
- UWB 距离和方向可独立缺失；方向缺失时 UI 回退到有来源标记的 GPS bearing，不保留旧箭头。
- App 进入后台时，core/Apple backend 有结束 ranging 的代码路径；系统是否按预期回调仍需真机验证。
- 通话信令经 BLE/事件路径，实时音频经 peer transport realtime traffic class；CallKit 与音频 route 由 `call-system` 持有。

## 文档一致性边界

`Trip.md` 不实现强一致多人编辑：

- 编辑前发布短期 lease；
- revision 不可变并引用 parent；
- 正常连通时 UI 对非 holder 只读；
- 分区可能产生重叠 lease 和多个 tip；
- deterministic ordering 选择 head，其余 tip 保留为 conflict revision。

这不是共识锁或 CRDT。只有多副本分区/合并测试完成后，才能宣称冲突保全满足验收标准。

## 构建边界

- Cargo 编译 Rust workspace 与 `libapp_ffi.a`。
- SwiftPM/Xcode 编译 SwiftUI App 和七个本地 Apple Swift Package。
- XcodeGen 从 `project.yml` 生成工程。
- `scripts/build-rust-ios.sh` 在 Nix devShell 中交叉编译 `aarch64-apple-ios`，但 clang、SDK、签名仍来自主机 Xcode。
- Xcode target 只面向 iPhoneOS 26.0；生成工程、`target/`、`build/` 和 `DerivedData/` 不是源码。

受支持的工作流见 [`DEVELOPMENT.md`](DEVELOPMENT.md)。
