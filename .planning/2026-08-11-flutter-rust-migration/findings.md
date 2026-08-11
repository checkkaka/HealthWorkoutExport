# Findings & Decisions

## Requirements
- 平台实施顺序为 iOS、macOS、Android、Windows；Linux 不纳入范围。
- Flutter 负责统一 UI，Rust 负责 FIT、合并、虚拟功率、同步规则等核心逻辑。
- HealthKit 保留 Swift 适配；Health Connect 使用 Kotlin 适配。
- 安装开发环境时优先使用版本管理工具。
- 前端文件写入前必须完成二次确认。
- 最终完成条件升级为现有功能全部对等，且自动化测试、iOS/Android/桌面构建与关键真机流程无已知缺陷。

## Research Findings
- 当前仓库是原生 SwiftUI iOS 应用，工作区已有大量用户未提交修改。
- 已安装 Rust 1.97.1（rustup stable）与 Node 24.15.0（fnm）；Flutter/FVM、Android Studio/SDK 未安装。
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

## Resources
- `HealthWorkoutExport/WorkoutDataSource.swift`
- `HealthWorkoutExport/HealthKitService.swift`
- `HealthWorkoutExport/AutoSyncEngine.swift`
- `HealthWorkoutExport/FitMerger.swift`
