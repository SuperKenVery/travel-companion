# 离线旅行伴侣 iOS App — 第一版任务说明

> 文档状态：第一版范围已确认  
> 编写日期：2026-07-14  
> 核心优先级：同行成员定位 > 离线通信可靠性 > IM 与协作功能 > 旧设备兼容性

## 1. 目标

开发一款完全不依赖互联网或云服务器的 iPhone 旅行伴侣 App。附近的一群人可以建立旅行群组，并通过设备间无线连接完成：

- 查看成员的相对位置与最后已知位置；
- 群聊和私聊；
- 发送文字、图片和语音消息；
- 进行一对一语音通话；
- 在地图或同行雷达上标注地点；
- 共同查看和轮流编辑一份 Markdown 行程文档。

第一版必须把“定位”做成核心能力。IM、地图标注和共享文档围绕同一个离线群组与同步协议构建，不引入互联网账户、远端服务器、APNs 或云存储。

## 2. 产品原则

1. **运行时完全离线**：建群、发现、认证、定位、消息、资源传输、通话和同步均可在无互联网环境完成。
2. **优先采用最新且简洁的系统 API**：不为旧系统维护 Multipeer Connectivity 等兼容路径。
3. **能力不满足时明确拒绝运行**：设备缺少所需的蓝牙、Wi‑Fi、本地网络权限或 UWB 时展示原因，不静默切换到另一套旧实现。
4. **后台能力是 best effort**：遵循 iOS 的调度与隐私规则，不承诺被用户强制退出、无线电关闭或权限撤销后仍能通信。
5. **本地优先、可恢复**：所有消息和变更先落本地，再向可达成员同步；断线重连后去重、补传，不因短暂分区丢失内容。
6. **位置永不伪装成实时**：每个位置都显示来源、精度与采样时间；过期数据必须明显标记。

## 3. 首版平台边界

- 开发语言：Swift 6，启用严格并发检查。
- UI：SwiftUI。
- Deployment Target：iOS 26.0。
- 仅支持 iPhone 真机；不把 Simulator、iPad、Mac Catalyst、watchOS 或 Android 纳入首版。
- 设备必须同时满足：
  - Core Bluetooth central/peripheral 与本地网络权限可用；
  - `NISession.deviceCapabilities` 支持 UWB 精确测距；
  - Wi‑Fi、Nearby Interaction 和定位权限可用。
- 预计覆盖 iPhone 12 及更新且带 UWB 的机型，但最终以运行时 capability check 为准；不按型号字符串硬编码。
- 第一版按 2–8 人小群设计和验收；这个数字是产品范围，而不是对底层 API 能力的断言。
- 同一时间只允许加入并激活一个旅行会话，以简化后台生命周期、无线电占用和用户认知。

禁止引入：

- `MultipeerConnectivity`；
- 针对 iOS 25 及更早版本的兼容代码；
- 依赖公网、APNs、CloudKit、Firebase 或自建服务器的关键路径；
- 为掩盖能力缺失而使用的第二套传输栈。

硬件 capability check、权限状态处理和无线电暂时不可用处理不属于“旧版兼容路径”，必须保留。

## 4. 已确定的系统技术路线

### 4.1 高速数据面：Bonjour + Network framework peer-to-peer

采用 Bonjour 和 iOS 26 新版 Network framework：

- Core Bluetooth：发现附近设备并完成自定义 PIN 入群；
- `NetworkBrowser<Bonjour>`：发现携带同一 group ID 的旅行伴侣服务；
- `NetworkListener`：发布服务并接受连接；
- `NetworkConnection`：建立加密连接并收发数据；
- `Coder`/TLV framing：传输小型 `Codable` 协议消息；
- 分块二进制流：传输图片、语音文件、文档快照等大资源。

所有 listener、browser 和 connection 都设置 `includePeerToPeer`/`peerToPeerIncluded = true`，允许系统在没有共同接入点时使用 AWDL。业务连接限制在本地链路，不解析或连接公网 endpoint。Bonjour TXT 只承载 group ID、peer ID、协议版本和显示名称等发现元数据；TCP 首包和 UDP 业务包必须通过群组凭据认证，认证完成前不处理业务内容。

每台已入群设备同时发布和浏览服务。每对 peer 使用稳定 ID 决定唯一主动拨号方，避免重复连接；服务重新出现或连接失败后自动重拨。用户只需入群一次，不进行每人对其余 `n-1` 人的系统配对。

普通消息和同步使用节能优先的配置；照片等资源传输使用 bulk 倾向；只有实时语音通话期间才申请 voice/realtime 倾向，通话结束立即恢复。

Bonjour/AWDL 数据面负责高吞吐、低延迟传输，但不被假设为能够单独、持续唤醒一个已挂起的 App。

### 4.2 后台控制面：Core Bluetooth

Core Bluetooth 只承载小型、幂等、可快速处理的控制消息：

- presence/peer hint；
- `locationRequest` 与小型 `locationResponse`；
- `precisionLocateRequest`、`precisionLocateResponse` 与 `precisionLocateCancel`；
- `dataAvailable` 同步提示；
- `callOffer`、`callAnswer`、`callReject`、`callEnd`；
- 建立或恢复 Bonjour 数据连接所需的短控制信号。

要求：

- 同时实现 central 与 peripheral 角色；
- 声明 `bluetooth-central` 和 `bluetooth-peripheral` 后台模式；
- 使用固定 service UUID，群组身份放在加密后的应用层载荷中；
- 实现 Core Bluetooth state preservation/restoration；
- 请求 ID、序号、TTL、确认与去重齐全；
- 回调中只做落盘、必要响应和调度，避免长任务。

`dataAvailable` 只表示“某成员的本地事件日志已有新内容”，不承载消息正文。接收方被 BLE 事件唤醒后，使用自己的同步游标通过已发现的 Bonjour peer-to-peer 连接主动拉取缺失事件；这样文字、图片、语音、文档和其他事件始终共用一套可靠内容传输与确认逻辑。

BLE 不直接承载消息正文、图片、语音文件、文档全文或通话音频。高速连接暂时不可用时，控制提示可以合并和排队，但不能假装内容已经送达。

### 4.3 旅行会话与后台生命周期

用户必须在前台明确点击“开始旅行”，App 才进入后台活跃状态。活动会话包括：

- Core Bluetooth 管理器与状态恢复；
- Core Location 服务会话和后台活动会话；
- 必要的本地通知与通信状态展示。

Nearby Interaction 不属于后台旅行会话。App 离开前台时立即结束当前 UWB 精确定位，回到 GPS 最后位置和 BLE 请求/响应策略。

用户点击“结束旅行”后，停止定位、UWB、广播和扫描，并清理短期会话密钥与租约。

不得设计任何绕过系统后台限制的保活机制。用户强制退出 App、关闭蓝牙/Wi‑Fi/定位、撤回权限或系统拒绝后台运行时，UI 应解释当前影响。

## 5. 核心定位功能

### 5.1 定位信息来源

第一版使用两层定位，不做复杂传感器融合：

1. **GPS/Core Location 层**
   - 用于所有可达成员的地理坐标、远距离直线距离和方位角；
   - 传输纬度、经度、海拔、水平精度、速度、航向和采样时间；
   - 根据本机位置和对端最后位置计算相对距离与方位；
   - 数据过期时继续显示，但必须附带“最后更新于……”和 stale 状态。

2. **UWB/Nearby Interaction 层**
   - 每个近距离对端使用 `NINearbyPeerConfiguration`；
   - discovery token 通过已认证的数据面交换；
   - 仅当查看者和被查看者的 App 都处于前台时运行；
   - UWB 可用时展示更精确的距离和方向；
   - UWB 暂停、超距、遮挡或无方向结果时立即回退到 GPS 表示；
   - 首版不把 UWB 结果强行换算成新的全球经纬度。

定位 UI 同时提供：

- **同行雷达**：完全离线，不依赖地图瓦片，展示方向、距离、来源、精度和新鲜度；
- **地图视图**：展示成员经纬度和地点标注，Apple 地图底图仅作为可用时的增强。

### 5.2 后台位置更新策略

基线方案采用“自适应低频采样 + BLE 按需刷新”的混合策略，而不是完全依赖收到 BLE 后才从零启动定位：

1. 活动旅行会话在前台创建 `CLServiceSession` 和 `CLBackgroundActivitySession`；
2. 使用 `CLLocationUpdate` 的异步更新流，由 Core Location 根据移动状态调节供给；
3. 平稳或静止时降低采样和广播频率，并保存最后可信位置；
4. 对端通过 BLE 发送 `locationRequest(requestID, desiredFreshness, deadline)`；
5. 如果缓存样本满足新鲜度，立即经 BLE 返回；
6. 缓存过旧时，在系统给予的后台执行窗口内请求更精确的新样本；
7. 超过截止时间则返回明确的 stale/timeout 状态，不返回伪造的新位置；
8. 得到新样本后只向提出请求的成员回应；常规位置广播按节流策略进行。

具体采样间隔、`distanceFilter`、活动类型和请求超时不能凭感觉固定，必须由第 11 节的真机技术验证决定。

### 5.3 请求对方提供精确位置

查看者在成员详情或同行雷达中点击“请求精确位置”后：

1. App 通过 BLE 发送带 request ID、请求者身份、创建时间和 TTL 的 `precisionLocateRequest`；
2. 如果被查看者在后台，BLE 回调只负责验证、去重、落盘，并通过 `UNUserNotificationCenter` 生成本地通知，例如“某成员正在寻找你，打开 App 提供精确位置”；
3. 被查看者从通知进入 App 后，页面明确显示请求者，并提供“提供精确位置”和“忽略”；
4. 用户同意且双方仍在前台、请求仍有效时，通过已认证的数据面交换 Nearby Interaction discovery token；
5. 双方启动 UWB peer session，查看者获得精确距离和方向；
6. 任一 App 进入后台、用户取消、请求超时或设备超距时立即结束 UWB session，并回退到 GPS 结果。

约束：

- 这是 BLE 事件触发的本地通知，不使用 APNs；
- 通知权限被拒绝时，只在下次打开 App 后显示待处理请求，查看者仍能看到 GPS 位置；
- 请求必须有冷却时间、合并和频率限制，防止成员反复打扰；
- 被查看者可以按群组或成员关闭精确定位请求通知；
- 暂停位置共享时自动拒绝请求，不披露新的 GPS 或 UWB 数据；
- 不能把“已发送请求”显示成“对方正在提供精确位置”，只有对方确认并成功启动 UWB 后才切换状态。

### 5.4 位置隐私与控制

- 仅群成员可解密位置；
- 用户可暂停/恢复自己的位置共享；
- 暂停后仍可查看之前位置，但所有成员都看到“已暂停”；
- App 内始终明确显示当前是否正在共享位置，后台定位使用系统提供的位置指示；
- 结束旅行后不继续采集；
- 本地位置历史默认只保留当前旅行所需的数据，提供清除旅行数据入口；
- 权限文案必须准确解释持续定位、蓝牙、Nearby Interaction 和本地网络用途。

## 6. 离线群组与同步

### 6.1 身份与入群

- 首次启动在本机生成稳定的设备身份、显示名称和 CryptoKit 密钥对；
- 创建群组时生成 group ID、群组 epoch、随机群组密钥和一次性 PIN；
- 加入者通过 Core Bluetooth 发现邀请者并输入一次 PIN；
- 双方通过 PIN 认证的握手确认群组名称、成员身份和 transcript，不依赖系统 Wi‑Fi Aware 配对；
- 正式产品使用 PAKE 或等价协议抵抗 PIN 离线穷举，再用接收者公钥封装随机群组密钥；群组密钥和 PIN 不以明文广播；
- 加入成功后同步成员列表、事件索引和所需资源清单。

PIN 是一次入群凭据，不是长期群组密钥。成员成功入群后持久化受 Keychain 保护的群组凭据，之后由 BLE state restoration 与 Bonjour 自动重连。新增第 `n` 个成员只与一个现有成员完成一次入群握手，不要求与其余 `n-1` 个成员分别配对。

不实现手机号、邮箱、Apple ID 登录、联系人匹配或互联网身份恢复。

### 6.2 拓扑

采用**机会式逻辑网状网络**：

- 整个网络只由同行成员的 iPhone 组成，不包含互联网服务、云端节点、中心服务器或无线路由器；
- `Network.framework` 只连接带同群标识的本地 Bonjour endpoint，参数启用 peer-to-peer 并限制本地链路，不允许回退到公网连接；
- 邀请者是新成员的首个本地点对点连接，不是服务器；
- 已完成群组认证的成员之间自动建立直接连接；无共同接入点时允许系统选择 AWDL；
- 当前无法直连时，事件可由其他已认证成员手机在本地存储，并在后来直接遇到目标成员时转发；
- 所有成员保存群组数据副本，断线后可浏览本地历史；
- 成员重新靠近、恢复本地点对点链路时执行 anti-entropy 同步、去重和缺块补传。

这里的 mesh、relay、store-and-forward 和 anti-entropy 都是**手机之间的本地协议行为**，不代表也不预留任何互联网服务。即使设备当前恰好可以上网，本 App 的群组业务协议也不访问公网。

首版不实现复杂的全局共识协议。成员管理由群主授权；群主不可达时，普通消息、位置和已保存内容继续工作，踢人、密钥轮换等管理操作等待群主恢复。

### 6.3 事件与资源模型

所有小型状态变更使用不可变事件封装：

```text
EventEnvelope
  id
  groupID
  groupEpoch
  senderID
  senderSequence
  logicalClock
  audience
  eventType
  deliveryPolicy
  createdAt
  expiresAt?
  payload
  signature
```

要求：

- `(senderID, senderSequence)` 和 event ID 保证幂等，并允许准确检测每个发送者的缺失区间；
- 使用 Hybrid Logical Clock 为不同发送者的事件提供稳定展示顺序，不依赖设备墙上时间完全一致，也不宣称全局强一致顺序；
- 每个 peer 保存同步游标和缺失事件集合；
- 图片、语音等资源使用 manifest、哈希、大小、MIME type 和分块清单；
- 支持中断续传、完整性校验、重复块消除和磁盘空间失败提示；
- 元数据存入 SwiftData，资源文件存入 App 沙箱文件目录；
- 数据访问与连接状态由 actor 隔离，UI 不直接操作 socket 或数据库。

### 6.4 可复用的群组可靠分发原语

所有需要“发给群内成员”的功能统一依赖 `GroupReplicationEngine`，feature 不自行遍历连接、管理 ACK 或实现重传。Bonjour/AWDL 没有被当成底层广播网络；逻辑群组广播由多次点对点复制、成员手机存储转发和重连后的 anti-entropy 共同实现。

建议业务接口：

```swift
protocol GroupDisseminating: Sendable {
    func publish<Payload: GroupPayload>(
        _ payload: Payload,
        to audience: GroupAudience,
        policy: DeliveryPolicy
    ) async throws -> Publication

    func deliveryUpdates(for publicationID: EventID)
        -> AsyncStream<DeliveryState>
}
```

同一套接口支持三种交付策略：

1. **`durable`：最终送达事件**
   - 用于群聊消息、地点标注、文档 revision、成员管理和删除 tombstone；
   - 事件写入持久日志并由所有可达成员转发；
   - 在目标成员确认持久化前保留，超过产品保留期后才允许清理；
   - 新加入成员是否补历史由事件类型的 backfill policy 决定。

2. **`latestValue(key, ttl)`：可替换状态**
   - 用于成员位置、presence、输入状态等只关心最新值的数据；
   - 新版本通过相同 key 取代旧版本，旧位置不形成无限待发送队列；
   - 每个版本仍带发送者序号、采样时间、TTL 和签名，乱序到达时不会覆盖更新的数据；
   - 最后可信位置可以按位置历史策略落盘，但不要求每个中间 GPS 样本都被所有成员 ACK。

3. **`transient(recipients, ttl)`：短期信令**
   - 用于精确定位请求、来电信令和取消操作；
   - 只发给指定成员，过期后不补发；
   - 可以重试和去重，但不进入长期群组历史。

功能映射：

| 功能 | 策略 | 说明 |
| --- | --- | --- |
| 群聊/私聊消息 | `durable` | 私聊使用指定 audience，群聊使用发送时的成员快照 |
| 地点创建、修改、删除 | `durable` | 修改引用 entity ID；删除使用 tombstone |
| Markdown revision | `durable` | revision 不可变，冲突由文档层处理 |
| 成员 GPS 位置 | `latestValue(memberID/location, ttl)` | 只保证最终得到可达的最新值 |
| presence | `latestValue(memberID/presence, ttl)` | 过期自动变为未知 |
| 精确定位请求 | `transient` | 超时后不再打扰对方 |
| 来电信令 | `transient` | 通话结束或超时后失效 |

#### 分发与补同步算法

1. `publish` 先在本机事务性分配 `senderSequence`、签名并落盘；只有落盘成功才返回 publication ID。
2. `GroupReplicationEngine` 向所有当前直接连接的目标成员发送事件批次；收到事件的成员先验证、去重和持久化，再返回到达确认。
3. 任何已认证成员都可以转发原始签名事件；relay 不能修改 sender、sequence、audience 或 payload。
4. 每台设备维护精确的 `SyncDigest`，至少包含 `groupEpoch`、每个 sender 的最大连续 sequence 和稀疏缺口。
5. 任意两台设备建立 Bonjour peer-to-peer 连接时先交换 digest，再双向请求缺失区间；同步不依赖某条 BLE 提示一定到达。
6. ACK 使用按“接收者 × 原始发送者”压缩的连续序号 frontier 与缺口集合传播，避免每条群消息产生 ACK 风暴。
7. 事件的目标成员集合按发布时的 group epoch 和 audience 固化；成员退出后通过新 epoch 和保留策略停止无限等待。
8. durable 事件只有在目标成员已确认或保留策略允许后才能回收；latest-value 和 transient 按 supersede/TTL 回收。

`DeliveryState` 至少区分：

- `persistedLocally`：已经安全写入发送者本机；
- `replicatedToRelay(count)`：其他成员持有副本，但目标不一定收到；
- `delivered(memberSet)`：这些目标成员已经持久化；
- `complete`：发布时的所有有效目标成员均确认；
- `expired/policyEvicted`：按策略停止传播，不等同于送达。

#### 保证与明确限制

- 在目标成员最终重新靠近，或者随时间存在一条由同行手机物理相遇形成的存储转发路径，且设备存储、权限和群组密钥均可用的前提下，`durable` 事件保证最终送达且至多呈现一次。
- “至多呈现一次”由幂等 materialization 保证；网络层允许重复传输。
- 不保证所有成员同时收到，不保证永久离线成员收到，也不提供跨发送者的原子全序广播。
- feature 只能根据 `DeliveryState` 展示真实状态；持有 relay 副本不能显示成目标成员已收到。

## 7. IM 功能

### 7.1 会话类型

- 每个旅行群有一个群聊；
- 支持成员之间的一对一私聊；
- 消息状态至少包含：排队、正在发送、已到达某成员、发送失败；
- 群聊首版不把“所有成员均已读”作为交付条件。

### 7.2 消息类型

1. **文字消息**
   - 支持纯文本；
   - 前台直连时即时发送；
   - 离线或分区时本地排队并在重连后补发。

2. **图片消息**
   - 支持相册选择和拍照；
   - 先同步缩略图和元数据，再按需传原图；
   - 显示进度，支持取消、失败重试和断点续传。

3. **语音消息**
   - 长按或点击录制，显示时长；
   - 以系统原生音频容器和编码保存；
   - 支持进度、取消、重传和本地播放。

### 7.3 后台提醒

消息提醒采用“BLE 敲门，Bonjour/AWDL 取内容”的流程：

1. 发送方先把新消息作为不可变事件写入本地事件日志，成功落盘后才更新 UI 为“排队/发送中”；
2. 发送方向当前可达且属于该会话的接收方发送 BLE `dataAvailable`；
3. 接收方通过已连接、已订阅的 GATT characteristic 收到提示，Core Bluetooth 获得后台处理机会；
4. 接收方验证提示的认证标签、TTL、序号和防重放信息，将多个提示按 peer 与 sync generation 合并；
5. 接收方复用或恢复对应 peer 的 Bonjour `NetworkConnection`，发送自己的同步 cursor，并拉取 cursor 之后缺失的事件；
6. 优先拉取文字、事件元数据和资源 manifest；图片原件、长语音等资源使用分块协议继续传输，不要求在一次后台窗口中完成；
7. 拉取消息内容成功后生成包含发送者和允许展示的摘要的本地通知；如果后台时间不足或 peer-to-peer 连接暂时失败，则生成不含正文的“有新消息”通知；
8. 未完成内容在下一次 BLE 提示、重新建立本地连接或用户打开 App 后继续同步；
9. 到达确认通过同步协议返回；“已到达”不等同于“已读”。

`dataAvailable` 建议载荷：

```text
DataAvailableHint
  protocolVersion
  groupID
  senderPeerID
  syncGeneration
  frontierDigest
  contentKinds
  requestID
  expiresAt
  authenticationTag
```

要求：

- 尽量维持成员之间的 BLE GATT 连接与 characteristic subscription，不把反复后台扫描 advertisement 作为主要消息提示机制；
- 同一成员连续产生多个事件时只发送合并后的最新 sync generation/frontier digest，避免重复唤醒；
- BLE 提示不包含消息正文，锁屏摘要遵循用户的通知隐私设置；
- BLE 提示只能触发本地 peer 同步，不得触发任何公网请求；
- App 被强制退出、蓝牙关闭、权限撤销或系统未给予后台时间时不承诺即时提醒；下次启动或重连后必须自动补同步。

## 8. 一对一语音通话

第一版只做一对一纯语音通话，不做群组通话或视频。

流程：

1. 主叫通过 BLE 发送小型 `callOffer`；
2. 被叫获得后台运行机会后报告本地来电 UI，并通过 CallKit 管理接听/拒绝/结束；
3. 双方建立直接 Bonjour peer-to-peer `NetworkConnection`；
4. 使用 `AVAudioSession` 的 `.playAndRecord`/`.voiceChat` 模式和系统语音处理；
5. 音频帧使用独立的低延迟通道，带序号、时间戳和轻量 jitter buffer；
6. 连接中断时短暂重试，超时后明确结束通话；
7. 通话期间启用所需 audio 后台模式，结束后立即释放音频和 realtime 网络资源。

编码格式在技术验证中从 Apple 原生支持的低延迟方案中选择。首版不为不同系统版本维护多编码兼容矩阵。

必须验证：锁屏来电、后台接听、耳机/扬声器切换、音频中断、蓝牙耳机、双方同时拨打和网络短暂中断。

## 9. 地图与地点标注

### 9.1 首版能力

- 展示自己和群成员的最后已知经纬度；
- 在同行雷达中展示完全离线的相对方向与距离；
- 可在当前位置、成员位置或指定坐标创建地点标注；
- 标注包含标题、备注、坐标、作者和创建时间；
- 标注通过统一事件协议同步；
- 作者可编辑/删除自己的标注，群主可管理群内标注；
- 对离线状态、底图不可用和位置过期做明确 UI 表示。

### 9.2 离线地图边界

MapKit 没有向第三方 App 提供可依赖的 Apple 离线地图包下载接口，因此：

- 首版的离线承诺覆盖定位数据、同行雷达、坐标投影、标注和同步；
- Apple 地图瓦片可能来自系统缓存，但不得成为功能正确性的前提；
- 底图不可用时仍必须能查看相对位置、坐标和标注列表；
- 可导入的 MBTiles/矢量离线地图包、离线搜索、路径规划和导航列入后续版本。

## 10. Markdown 共享文档

每个群组第一版只有一份 `Trip.md` 行程文档。

功能：

- “编辑”和“预览”是两个明确分离的模式；
- 编辑使用原生文本编辑器；
- 预览使用系统 Markdown/AttributedString 能力，首版只承诺常用 Markdown 子集；
- 文档保存时生成不可变 revision，包含 revision ID、父 revision、作者、时间和内容哈希；
- 所有成员可离线查看最后同步的 revision；
- 保存后通过事件协议广播，正文可按资源方式传输。

第一版不提供真正的多人同时编辑：

- 开始编辑时发布短期 editor lease，其他在线成员进入只读；
- lease 具有 holder、lease ID 和过期时间，可主动释放；
- 网络分区可能导致极端情况下出现两个编辑副本，因此不能宣称实现了分布式强一致锁；
- 合并网络后使用确定性规则选出主 revision，同时把另一个版本保留为“冲突副本”，确保内容不丢失；
- CRDT、逐字符协作、评论、富文本、表格和附件留到后续版本。

## 11. 必须先完成的真机技术验证

在全面开发 UI 前，直接在正式 App 中完成第一个端到端 vertical slice，并提供仅 Debug 构建可见的诊断页面。优先验证两台真机之间的 BLE PIN 入群、BLE 提示、Bonjour/AWDL 内容同步和位置响应；无需建立独立 target 或强制编写正式报告。关键测试仍需在开发日志或自动化测试产物中记录设备、系统版本、权限状态、成功率、延迟和能耗，以便据此冻结后台策略。

### 11.1 BLE 入群、Bonjour/AWDL 与新版 Network API

- 两台和四台真机完成一次性 PIN 入群，确认无需逐对系统配对；
- 验证多连接、断线重连和设备离开/回来；
- 测量小消息延迟、大文件吞吐和 realtime/bulk 模式能耗；
- 在离开已知 Wi‑Fi、关闭蜂窝数据的条件下验证连接仍可建立，并记录 path interface 与是否观察到 `awdl0`；
- 验证所有 listener、browser、connection 的 `peerToPeerIncluded` 为 true，且业务没有连接公网 endpoint；
- 验证 TLS/Coder framing 与大文件分块可以共存。

### 11.2 BLE 后台控制面

- central/peripheral 双角色同时运行；
- 前台、后台、锁屏、系统回收后恢复等状态分别测试；
- 使用固定 service UUID 验证后台发现、连接、订阅通知、GATT 请求和唤醒表现；
- 验证 `dataAvailable` 唤醒后恢复 Bonjour peer-to-peer 连接、按 cursor 拉取文字消息并生成本地通知的完整流程；
- 验证连续消息提示合并、重复提示去重、提示丢失后的 anti-entropy 补同步和内容拉取失败后的通用通知；
- 验证 `precisionLocateRequest` 能在获得后台运行机会后生成本地通知；
- 测试 30 分钟屏幕关闭期间的重复控制请求，记录成功率和 P50/P95 延迟；
- 明确区分“系统终止”和“用户强制退出”的行为。

### 11.3 后台定位策略对比

用相同行走路线和请求序列比较：

- 仅 BLE 唤醒后临时请求位置；
- 活动 `CLBackgroundActivitySession` 的低频自适应更新；
- 自适应更新加 BLE 按需提高新鲜度的混合方案。

至少记录：请求响应率、样本年龄、水平精度、响应延迟、2 小时耗电和后台终止情况。最终参数以数据决定；若实验未推翻基线，则使用混合方案。

### 11.4 UWB 前台精确定位

- 交换 discovery token 并完成 iPhone-to-iPhone 测距；
- 验证双方都在前台时的距离/方向回调；
- 验证被查看者在后台收到 BLE 请求、本地通知展示、从通知进入 App、确认请求和启动 UWB 的完整流程；
- 验证任一方进入后台时立即结束精确定位并回退到 GPS；
- 验证通知权限被拒绝、请求被忽略、请求过期、频率受限和位置共享暂停等分支；
- 测试近距离、超距、遮挡、横竖屏和 session 恢复；
- 多成员时验证同时维护多个 `NISession` 的实际资源上限和调度策略。

### 11.5 离线来电

- BLE `callOffer` 能否在后台/锁屏时触发本地来电流程；
- 接听后能否及时建立 Bonjour peer-to-peer 音频连接；
- 验证 CallKit、音频后台模式和 App Review 合规假设；
- 若 iOS 状态下无法可靠呈现，记录可复现边界，并将 UI 降级为“未接来电/打开 App 后回拨”，不引入互联网推送。

## 12. 建议代码结构

```text
App/
  AppState
  Navigation
Domain/
  Identity
  Group
  Events
  Messaging
  Location
  Documents
  Calls
Transport/
  PeerToPeerTransport
  BluetoothControlPlane
  ProtocolFraming
  ResourceTransfer
Sync/
  EventStore
  PeerSyncEngine
  ConflictResolution
Persistence/
  SwiftDataModels
  ResourceStore
Features/
  Onboarding
  GroupSetup
  Radar
  Map
  Chat
  Call
  TripDocument
Support/
  Permissions
  Diagnostics
  Logging
```

架构约束：

- feature 层依赖 domain protocol，不直接依赖 Core Bluetooth 或 Network framework；
- 高速数据面与 BLE 控制面通过统一 peer identity 关联；
- 连接、同步、定位和文档状态分别由 actor 管理；
- SwiftUI view 不持有底层 manager delegate；
- 协议从第一天带显式 `protocolVersion`，但首版不实现旧协议兼容；
- 所有系统时间、无线电和传输层都可注入 fake，以便单元测试和模拟网络分区。

## 13. 分阶段交付

### M0：可行性验证

- 完成第 11 节全部实验；
- 根据结果冻结后台定位和来电策略；
- 给出不依赖猜测的设备与系统限制。

### M1：群组、连接与事件同步

- 本地身份、创建群、加入群、成员列表；
- Bonjour/AWDL 数据面和 BLE 控制/入群面；
- 事件存储、去重、补同步和资源分块基础设施。

### M2：定位核心

- 旅行会话、后台定位和权限流程；
- Core Location 混合更新；
- BLE 位置请求/响应；
- 前台 UWB 距离/方向；
- 精确定位请求、本地通知、确认与超时流程；
- 同行雷达、成员新鲜度与错误状态。

### M3：IM

- 群聊、私聊和文字消息；
- 图片和语音消息；
- BLE `dataAvailable`、Bonjour cursor 拉取、本地通知和资源断点续传。

### M4：语音通话

- BLE 来电信令；
- CallKit 与音频会话；
- Bonjour peer-to-peer 实时音频、重连和中断处理。

### M5：标注与共享文档

- 地图/雷达地点标注与同步；
- `Trip.md` 编辑、预览、lease、revision 和冲突副本。

### M6：稳定性、能耗与发布准备

- 2/4/8 设备测试；
- 长时间后台、分区重连、磁盘不足和权限变化；
- Instruments Energy Log、网络和内存分析；
- 隐私说明、诊断导出、无障碍和本地化基础。

## 14. 第一版验收标准

### 离线与建群

- [ ] 关闭蜂窝数据且没有可用互联网路由时，2–4 台支持设备可创建并加入群组。
- [ ] 抓取 App 网络行为后，没有关键功能访问公网服务。
- [ ] 设备断开并重新靠近后自动发现缺失事件和资源并补齐。
- [ ] 重复事件、重复分块和重复 BLE 请求不会产生重复消息或副作用。

### 定位

- [ ] 每个成员都显示最后位置、采样时间、水平精度、数据来源和 stale 状态。
- [ ] GPS 可计算远距离成员的距离和方位；UWB 可用时切换为精确距离/方向。
- [ ] UWB 暂停或超距后 UI 正确回退，不冻结旧方向箭头。
- [ ] UWB 只在双方 App 均处于前台且请求有效时运行，任一方进入后台后立即结束。
- [ ] 后台成员收到精确定位请求后可看到本地通知，打开 App 并确认后开始 UWB；拒绝、过期和通知权限关闭均有明确状态。
- [ ] 活动旅行会话在锁屏/后台测试中能按系统允许程度持续更新，并有可复现测试报告。
- [ ] BLE 请求能触发缓存回复或 best-effort 新采样；超时明确可见。
- [ ] 暂停共享和结束旅行会立即停止新的对外位置更新。

### IM 与通话

- [ ] 群聊和私聊文字在直连前台场景正常收发，分区后可补发。
- [ ] 后台接收方可由经过认证的 BLE `dataAvailable` 获得处理机会，并通过 Bonjour peer-to-peer 连接拉取消息内容。
- [ ] 多条 BLE 提示可以合并，重复、乱序或丢失提示不会造成重复消息或永久漏同步。
- [ ] 内容拉取成功时本地通知可显示允许的摘要；拉取失败时只显示通用提醒并保留待同步状态。
- [ ] 图片和语音支持进度、校验、取消、重试和断点续传。
- [ ] 后台可用时 BLE 提示能生成本地消息提醒；不可用时重启后自动补同步。
- [ ] 两台真机可在无互联网环境完成一对一语音通话。
- [ ] 锁屏、音频路由变化、来电冲突和短暂断连均有明确行为。

### 标注与文档

- [ ] 无底图时，同行雷达、坐标、标注列表和同步仍可使用。
- [ ] 地点标注可创建、同步、编辑和删除。
- [ ] `Trip.md` 的编辑与预览完全分离。
- [ ] 正常连通时只有一个成员进入编辑态；异常分区冲突不会丢失任一版本。
- [ ] 所有成员可离线查看最后同步的文档 revision。

### 工程质量

- [ ] Swift 6 严格并发无警告；关键状态无未隔离的共享可变数据。
- [ ] 事件合并、协议 framing、资源校验、lease 和位置新鲜度有单元测试。
- [ ] fake transport 可覆盖掉线、重复、乱序、延迟和网络分区。
- [ ] 真机报告包含后台成功率、P50/P95 延迟、吞吐和能耗，而不是只给主观结论。
- [ ] 权限被拒绝、无线电关闭、存储不足、App 被强制退出时均有准确错误说明。

## 15. 第一版明确不做

- Android、Web、iPad 和 Apple Watch 客户端；
- iOS 25 或更早系统、无 UWB 设备、Multipeer Connectivity fallback；
- 互联网账户、云同步、跨地域聊天、远程推送和远程备份；
- 视频消息、视频通话和群组语音通话；
- 后台持续 UWB 测距；
- 严格保证强一致的分布式锁或共识系统；
- Markdown 多人实时协作、CRDT、评论和富文档；
- 可下载的完整离线地图、离线 POI 搜索、路线规划和导航；
- 强制退出 App 后仍实时收消息、来电或位置请求的承诺。

## 16. 后续方向

- 导入或预下载合法授权的离线矢量地图包；
- 群组语音通话与更完整的 IM 状态；
- 多文档、附件、评论、CRDT 实时协作；
- 更强的成员移除、群主迁移和分布式管理；
- Apple Watch 距离提示；
- 旅行结束后的加密导出、备份和设备迁移；
- 在不破坏简洁性的前提下评估跨平台 BLE 入群与本地服务发现客户端。

## 17. 官方技术依据

- [Multipeer Connectivity / MCSession 已 deprecated，Apple 要求使用 Network framework](https://developer.apple.com/documentation/multipeerconnectivity/mcsession)
- [iOS 26 的 NetworkConnection、NetworkListener、NetworkBrowser 与 Swift structured concurrency](https://developer.apple.com/videos/play/wwdc2025/250/)
- [NWParameters.includePeerToPeer：为 connection 与 listener 启用点对点链路技术](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)
- [NWBrowser：浏览 Bonjour 网络服务](https://developer.apple.com/documentation/network/nwbrowser)
- [Core Bluetooth API 概览](https://developer.apple.com/documentation/corebluetooth)
- [Core Bluetooth 后台处理的系统限制](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Core Location 后台更新、CLServiceSession 与 CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Nearby Interaction 的 UWB peer session 与 discovery token](https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session)
- [NINearbyPeerConfiguration：iPhone 间 UWB 距离与方向](https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration)
- [Apple Developer Forums：MapKit 未向第三方提供离线地图下载 API](https://developer.apple.com/forums/thread/731922)
