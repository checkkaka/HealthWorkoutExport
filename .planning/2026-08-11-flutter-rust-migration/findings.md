# Findings & Decisions

## Requirements
- 平台实施顺序为 iOS、macOS、Android、Windows；Linux 不纳入范围。
- Flutter 负责统一 UI，Rust 负责 FIT、合并、虚拟功率、同步规则等核心逻辑。
- HealthKit 保留 Swift 适配；Health Connect 使用 Kotlin 适配。
- 安装开发环境时优先使用版本管理工具。
- 前端文件写入前必须完成二次确认。
- 最终完成条件升级为现有功能全部对等，且自动化测试、iOS/Android/桌面构建与关键真机流程无已知缺陷。

## Research Findings
- 当前仓库原始实现是原生 SwiftUI iOS 应用；迁移分支旁路新增 Flutter/Rust，未覆盖原工程。
- 迁移开始前已安装 Rust 1.97.1（rustup stable）与 Node 24.15.0（fnm）；本次会话补充了 Flutter/FVM 与 Android SDK 工具链。
- 已安装 Xcode 26.6，可继续承担 iOS 原生插件、签名与构建。
- FVM 4.1.2 已通过 Homebrew 安装，Flutter stable 3.44.9 / Dart 3.12.2 已缓存完成。
- Android Studio 2026.1.3.8 已通过 Homebrew Cask 安装；SDK/NDK 正在独立配置。
- 现有 `WorkoutDataSource` 已形成数据源抽象，可作为平台适配迁移边界。
- GitNexus 旧索引无法识别 `HealthKitService`、`AutoSyncEngine`、`FitMerger`，需要重新分析。
- `flutter_rust_bridge` 当前稳定版为 2.12.0，2.13.0 仍为 beta；官方支持 Android、iOS、Windows、Linux、macOS。

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| 保留现有 SwiftUI 工程作为行为基准 | 避免一次性替换导致数据与功能回归 |
| 不同时引入 Tauri | 单一 Flutter UI 已覆盖目标平台，第二套 UI 框架没有必要 |
| Rust 首切片为 `is_commute` | 无第三方依赖，直接复用现有严格边界语义，适合验证 Rust 测试链 |
| Rust 第二切片为 `stable_dedupe_matches` | 两条生产路径共享且已有对等测试，可减少后续跨平台重复实现 |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| GitNexus 缺少 `tree-sitter-swift`，52 个 Swift 文件无法解析 | 迁移首批不修改原有 Swift 符号，以源码调用检索补足；后续修改符号前需先恢复 Swift 解析能力 |

## 项目外环境台账

完整只读审计已生成到 `/tmp/healthworkoutexport-environment-audit.md`。最终交付前仍需按当时实际状态复核版本、路径、卸载命令、最早安全卸载时机及全局影响。

有强证据属于本次新增：Android Command-line Tools、`~/Library/Android/sdk` 下 Android 36 / Build Tools 36 / platform-tools / NDK 28.2、Android 构建自动补充的 Platform 33 与 CMake 3.22.1、`~/fvm/versions/stable` 的 Flutter 3.44.9 与 Android engine 缓存、`flutter_rust_bridge_codegen` 2.12.0、`cargo-expand` 1.0.124、Rust Android 目标（含构建时补装的 `i686-linux-android`），以及 Gradle 在 `~/.gradle` 写入的 wrapper/依赖缓存。FVM、CocoaPods、Ruby 仅能确认本日链接操作，无法可靠区分新装/升级；rustup、fnm/Node、Xcode/CLT、OpenJDK 17 可确认原先已有。Flutter 用户级配置已固定 JDK 到 `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`；这会影响本机所有 Flutter 项目的 Android 构建，可在不再构建本项目后用 `flutter config --jdk-dir=<其他JDK路径>` 调整。Android SDK 许可仍有部分未接受，本次未代用户接受法律条款。

FRB 采用最小集成：没有运行会覆盖 `lib/main.dart` 的 `integrate`，只复用 Cargokit 四平台构建钩子并生成现有 `is_commute` API 绑定。Flutter 测试会编译并加载真实 Rust 动态库，避免仅验证 Dart mock。

iOS 原生通道已接入 HealthKit 可用性、全量现有读取类型授权、设置跳转、半开区间训练摘要，以及兼容旧 service 的 Keychain 读写删除。Bundle ID、URL scheme、entitlement 和隐私文案与原工程保持一致；最低系统也按原工程统一为 iOS 17。

Flutter 健康页已调用上述 HealthKit 通道，并覆盖授权、日期查询、加载/空态/错误重试与选择状态。iOS Strava OAuth 原生通道只接受官方 HTTPS 授权地址，使用 256 位随机 state，并严格校验 `healthworkoutexport://localhost/callback`；Rust token 交换和 Flutter 设置页已接入，刷新编排仍留给后续切片。Rust 同步指纹已与 Swift 固定摘要对齐，但尚未替换生产调用。

HealthKit 完整训练包现通过一个 UUID 集合查询回查训练，再以最多 3 条并发读取 quantity、路线、事件和 metadata；Flutter 对返回数量、UUID 顺序及所有嵌套字段做严格解析。Rust FIT 首切片已实现严格完整性探测、内容质量摘要和原字节无损重编码，并生成真实 Flutter FFI；语义级消息编辑、合并与编码仍未完成，不能把 FIT-02 标为完整完成。

当前锁定的 FITSwiftSDK 与 Rust 实现都不支持 compressed timestamp data message；Rust `is_valid_fit` 会做完整 CRC/消息边界校验，而旧 `FitContentProbe.isValidFit` 只检查文件魔数。前者是有意的严格校验，后续若引入压缩时间戳解码，必须同时扩展摘要与重编码测试，不能只放宽入口判断。

Strava 非敏感设置必须继续使用原 `UserDefaults.standard` 键（`strava.uploadMode`、`strava.expiresAt`、`strava.gcjCorrectionEnabled`），否则 Flutter 升级后会看不到旧状态；敏感项继续使用 Keychain service `com.checkkaka.HealthWorkoutExport` 下的原 account。当前采用一个无依赖的原生标量 Preferences 通道，避免 `shared_preferences` 的键前缀造成迁移分叉。

Strava 契约审计报告位于 `/tmp/healthworkoutexport-strava-contract.md`。当前仅完成 API OAuth/token 子闭环：固定 scope、256-bit state、精确回调、标准 form 编码、rustls、响应上限、脱敏错误，以及成功后完整授权事务写入；取消或失败不会覆盖旧授权。并发 refresh 合并、401 强制刷新一次、Uploads/poll、限额、活动查询、Web Cookie/CSRF 与同步状态仍是明确缺口。

Preferences 原生通道只允许 Strava 与 VirtualPower 的既有白名单键，不能让 Flutter 任意访问 `UserDefaults.standard`。本次 Rust HTTPS 依赖只更新 Cargo 项目依赖和 `~/.cargo/registry` 缓存，没有安装新工具或修改全局环境。

FIT 语义物化方案因 sync FFI 极端输入内存放大被撤回；公开摘要/校验继续保持流式 O(input + 16 definitions)，`reencode_fit` 在没有编辑参数时只做严格验证后原字节复制。真正字段编辑应在有明确调用方时实现受限流式重写，不能先保留高开销语义树。

## Resources
- `HealthWorkoutExport/WorkoutDataSource.swift`
- `HealthWorkoutExport/HealthKitService.swift`
- `HealthWorkoutExport/AutoSyncEngine.swift`
- `HealthWorkoutExport/FitMerger.swift`
