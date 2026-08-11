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

## Resources
- `HealthWorkoutExport/WorkoutDataSource.swift`
- `HealthWorkoutExport/HealthKitService.swift`
- `HealthWorkoutExport/AutoSyncEngine.swift`
- `HealthWorkoutExport/FitMerger.swift`
