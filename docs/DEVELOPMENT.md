# Development workflow

## 唯一受支持的环境

仓库开发工具统一由 Nix flake 管理。受支持的入口是：

```sh
nix develop
```

`flake.lock` 固定 nixpkgs 与 Fenix；devShell 提供：

- Rust stable toolchain、Clippy、rustfmt、rust-analyzer；
- `aarch64-apple-ios` Rust standard library；
- XcodeGen；
- SQLite、OpenSSL、pkg-config；
- libimobiledevice 真机工具。

不要为此仓库单独安装或优先使用全局 `cargo`、`rustc`、`xcodegen`。脚本通过 `TC_NIX_DEVSHELL=1` 判断是否处于项目环境；`scripts/check.sh` 与 `scripts/build-rust-ios.sh` 在外部执行时也会重新进入这个 flake。

### 必要的主机例外

Nix 不分发 Apple 的授权 SDK。以下组件必须来自 macOS 主机：

- 完整 Xcode 26；
- `xcrun`、`xcodebuild`、codesign 与 iPhoneOS SDK；
- 连接真机时使用的 Apple Developer 签名身份和 provisioning profile。

devShell 通过 `TC_HOST_XCRUN`、`TC_HOST_XCODEBUILD` 和 `TC_HOST_DEVELOPER_DIR` 显式引用这些主机组件。这个例外不意味着可以绕过 devShell 使用另一套 Rust/XcodeGen 工具链。

devShell 会移除 nixpkgs 默认导出的 `LD=ld`。Xcode 会把继承的环境变量解释为 build setting，而 SwiftPM 的 `Ld` 阶段需要由 clang driver 处理 `-Xlinker` 等参数；把 `LD` 覆盖成裸 `ld` 会导致 Apple module 的静态 product 链接失败。已经从旧 devShell 启动的 Xcode 进程需要完全退出后，从新的 `nix develop` 会话或 Finder 重新启动。

## 标准检查

从仓库根目录运行：

```sh
nix develop --command ./scripts/check.sh
```

脚本当前执行：

1. `cargo fmt --all --check`；
2. `cargo clippy --workspace --all-targets -- -D warnings`；
3. `cargo test --workspace`；
4. `xcodegen generate`；
5. generic iPhoneOS、禁用签名的 `build-for-testing`。

这套检查验证格式、Rust lint/unit tests、Swift 6 编译、链接和测试 bundle 装配。它没有安装或运行 App，也不会产生 BLE、AWDL、Core Location、Nearby Interaction、CallKit 或能耗的真机证据。

## 分步工作

进入 devShell 后可以运行较窄的命令：

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p xtask -- check
cargo run -p xtask -- test
```

生成 Xcode 工程：

```sh
xcodegen generate
```

`TravelCompanion.xcodeproj` 是生成物并被 `.gitignore` 忽略。修改工程设置时应编辑 `project.yml`，不要把手工修改后的 `.pbxproj` 当作源码。

构建 Rust iPhone 静态库：

```sh
./scripts/build-rust-ios.sh Debug
./scripts/build-rust-ios.sh Release
```

脚本使用 Fenix 提供的 iOS Rust target，并使用主机 iPhoneOS SDK 的 clang/SQLite。产物写入 `build/ios/<Configuration>/libapp_ffi.a`，随后从该静态库重新生成 `bindings/app-ffi/generated/` 下的 Swift sources 与 C headers。`build/` 和 `target/` 都是生成目录；UniFFI 生成文件是 Xcode 编译输入，修改 Rust export 后不要手工编辑它们。

只需从已有 host 静态库刷新 binding 时可运行：

```sh
./scripts/generate-uniffi-swift.sh target/debug/libapp_ffi.a
```

## Xcode 与真机

先在 devShell 生成工程，再用主机 Xcode 打开：

```sh
nix develop --command xcodegen generate
open TravelCompanion.xcodeproj
```

Xcode target 的 pre-build phase 会调用 `scripts/build-rust-ios.sh`；脚本会确保 Rust 构建仍处于 Nix devShell。真机安装还需要开发者自行选择签名 Team。

项目有意只声明 `iphoneos`，不支持 Simulator、Mac Catalyst 或 Designed for iPad。通用无签名构建只检查装配；正式的无线电/后台验收必须在符合产品边界的 iOS 26 UWB iPhone 上进行。

## 真机日志

Rust 核心使用 `tracing`。Apple 平台上的 subscriber 同时装配两个 layer：

- `tracing-oslog` 写入 subsystem `com.ken.TravelCompanion`、category `RustCore` 的统一系统日志；
- `tracing-appender` 写入 App 数据容器中的按日滚动文件。

文件日志位于：

```text
Library/Application Support/TravelCompanion/Logs/travel-core.log.YYYY-MM-DD
```

当前文件 layer 在所有 Apple 构建配置中启用，不只限于 Debug。它保留最近 7 个按日日志文件；每行包含时间、level、Rust target、源码文件和行号。日志只写 OSLog 和上述文件，不得写入 SQLite 事件库或 App state。调用点应直接使用 `tracing::debug!`、`tracing::info!`、`tracing::warn!` 或 `tracing::error!`，不要重新建立会持久化诊断 entry 的包装层。

先列出已连接设备并确认日志文件：

```sh
xcrun devicectl list devices
xcrun devicectl device info files \
  --device <device-identifier> \
  --domain-type appDataContainer \
  --domain-identifier com.ken.TravelCompanion \
  --subdirectory 'Library/Application Support/TravelCompanion/Logs'
```

复现问题后，把指定设备的当日日志拉到 Mac：

```sh
xcrun devicectl device copy from \
  --device <device-identifier> \
  --domain-type appDataContainer \
  --domain-identifier com.ken.TravelCompanion \
  --source 'Library/Application Support/TravelCompanion/Logs/travel-core.log.YYYY-MM-DD' \
  --destination /tmp/travel-core-<device-name>.log
```

多机问题必须分别导出每台设备的文件，并用时间、event ID、peer ID、request ID 或 connection handle 对齐。不要把 Mac 上运行 Rust 单元测试产生的 OSLog 当作真机日志；若问题已经发生且文件日志不存在，才考虑收集体积更大的 sysdiagnose。日志可能包含设备或群组标识，分享前应检查并脱敏。

## 测试结果应如何表述

建议在提交或报告中区分：

- “存在单元测试”：测试源码已经落盘；
- “本次检查通过”：附上本次 `scripts/check.sh` 输出或 CI 产物；
- “真机验收通过”：附上设备、系统版本、权限、无线电条件、样本量和原始日志；
- “M6 完成”：还必须包含长期后台、2/4/8 设备、故障、能耗、内存/网络与发布检查。

不要用 generic `build-for-testing` 代替真机结论，也不要根据 Apple backend 可以编译就声称后台或 AWDL 行为已经验证。

## 归档原型

如需复现 M0 API 实验，请进入 `prototypes/ios-validation-lab/` 并遵循该目录 README。它有独立的 XcodeGen 工程和实验模型；不得从那里复制 Debug 安全设计或持久化模型到正式 workspace。
