# Progress Log

## Session: 2026-08-11

### Current Status
- **Phase:** 2/3 - 桥接与增量实现
- **Started:** 2026-08-11

### Actions Taken
- 已恢复并保留上一项已完成规划上下文。
- 已创建独立迁移规划目录，未覆盖旧规划。
- 已确认工作区存在用户未提交 Swift/测试/文档修改。
- 已确认 Rust 由 rustup 管理、Node 由 fnm 管理；Flutter/FVM 与 Android 环境尚未安装。
- 已重建 GitNexus 索引；因 `tree-sitter-swift` 原生绑定缺失，Swift 符号仍无法解析，错误已记录。
- 用户已完成前端修改二次确认，Flutter 代理开始建立独立骨架。
- 已通过 Homebrew 安装 FVM 4.1.2，并由 FVM 安装 Flutter 3.44.9 / Dart 3.12.2。
- 已通过 Homebrew Cask 安装 Android Studio 2026.1.3.8。
- Rust 首切片已新增 `rust/workout_core`，迁移通勤判定并通过测试；现有 Swift 文件未修改。
- 目标已升级为完整功能对等与无已知缺陷；骨架完成不视为交付。
- 已安装 `flutter_rust_bridge_codegen` 2.12.0，并通过 rustup 增加 iOS 真机/模拟器目标。
- Rust 第二切片已迁移稳定去重规则；`cargo test` 当前 2/2 通过。
- 用户明确平台顺序为 iOS → macOS → Android → Windows；已通知并行代理排除 Linux。
- 已创建并推送远程分支 `codex/flutter-rust-migration`，当前包含 Flutter/Rust 基线、功能对等矩阵和迁移计划。
- Flutter 基线已通过 analyze、widget test、iOS 模拟器构建和 macOS Debug 构建；Rust 2/2 测试通过。
- 已并行启动 ActivityMatcher Rust 迁移、Flutter iOS 三页签/日期范围、项目外环境审计。
- Rust 已迁移 ActivityMatcher 时间区间匹配，当前 4/4 测试通过。
- Flutter 已实现健康/行者/顽鹿三页签、各页独立日期状态和半开区间；复核时把活动列表误用的“近90天”修回 Swift 基线“今年”。
- 原 Swift XCTest 已在 iPhone 17 Pro / iOS 26.5 模拟器完整通过；直接选 Mac 目标会受 iOS-on-Mac 签名限制，不代表源码测试失败。
- 项目外环境只读审计已完成，报告位于 `/tmp/healthworkoutexport-environment-audit.md`。
- 已迁移 VirtualPowerPhysics 纯计算逻辑，连同 ActivityMatcher、通勤判定和稳定去重共 12 个 Rust 测试通过。
- 已接通 Flutter Rust Bridge 2.12.0；Flutter 测试现场编译并加载真实 Rust 动态库，`is_commute` 调用通过。
- 已复用 FRB 的最小 Cargokit 平台钩子，未运行会覆盖 Flutter 入口的 `integrate`。
- Flutter iOS 模拟器和 macOS Debug 已成功链接 Rust 静态库；Android 构建已进入 Gradle 依赖下载/编译阶段。
- Flutter 用户级 JDK 已固定为 Homebrew OpenJDK 17；Android 构建自动补装 Platform 33，许可余项未代用户接受。
- iOS Runner 已注册 HealthKit 与 Keychain 原生通道；保留原 Bundle ID、URL scheme、HealthKit entitlement、读取类型和 Keychain service。
- iOS 最低版本已从模板的 13.0 对齐原工程 17.0；HealthKit/Keychain RunnerTests 3/3 通过。
- 生产入口会在渲染 UI 前初始化 FRB；iOS 模拟器安装并启动后持续运行，无动态库加载崩溃。
- 已兼容 Gradle 9 的 `ExecOperations` 并把 FRB Android 插件 compileSdk 对齐 36；四 ABI Rust 编译及 Debug APK 构建通过。
- Android 构建新增 CMake 3.22.1 与 `i686-linux-android` Rust target，已补入项目外环境台账。
- Flutter 健康页已接入 HealthKit 生产通道，覆盖可用性、授权、日期查询、加载/空态/错误重试和批量选择；快速切换日期时会丢弃旧请求结果。
- iOS 已注册 Strava OAuth 原生通道；授权请求使用随机 state，回调严格校验 scheme/host/path/state，并只把授权码返回 Flutter，尚未接入 token 交换与设置页。
- Rust 已迁移 SHA-256 同步指纹规则，保持 Swift 的整秒 RFC3339、补源排序和空字段语义；当前尚未接入生产同步链路。
- 本批次验证已覆盖 iOS、macOS、Android 构建和 iOS 模拟器实际启动；Windows 需在 Windows 主机上验收。
- 审查发现并修复 HealthKit 首次授权期间切换日期的竞态、非 iOS 平台误调用 HealthKit、拒绝权限后缺少系统设置入口；三项均补了组件回归测试。
- iOS HealthKit 已新增按 UUID 批量读取完整训练包，quantity、路线、事件与 metadata 最多 3 条并发且保持请求顺序；Flutter typed client 会严格校验 UUID、数量、顺序与字段类型。
- Rust 已实现 FIT 严格头/长度/CRC/消息边界探测、GPS/心率质量计数及无损字节重编码，并通过真实 FRB 接口供 Flutter 调用；可编辑消息模型尚未迁移。
- 提交前复审撤回了 compressed timestamp 误报：当前锁定 FITSwiftSDK 同样明确不支持该消息类型；本批次无 Critical/Important 缺陷，Rust 19/19、Flutter 22/22 与静态分析再次通过。
- 已提交并推送 `79a8034`：HealthKit 完整明细与 Rust FIT 探测，远端分支与本地一致。
- iOS 新增原始 UserDefaults 通道，并以原键名读写 Strava 模式、token 过期时间和 GCJ 纠偏；敏感凭据仍沿用旧 Keychain service/account，Flutter 设置仓测试 13/13 通过。
- GitNexus 已重建为 711 nodes / 882 edges / 28 flows；Swift、Dart、Kotlin 可选 parser 仍不可用，相关影响继续用 `rg` 源码调用链补足。
- Strava API 授权已接入生产设置页：Flutter 生成固定 scope URL，iOS 原生校验 state/回调，Rust 使用 rustls 标准表单交换 token；OAuth 成功后原生一次提交 clientId/secret/refresh/access/expires，任一 Keychain 写入失败会回滚，取消不会覆盖旧授权。网页 Cookie、限额和真机 OAuth 尚未完成。
- Rust Strava token mock 覆盖编码、refresh rotation、错误/响应上限与脱敏；FRB 真实调用已接通。当前 Rust 25/25、Flutter 30/30、RunnerTests 11/11。
- FIT 高风险复审发现语义树会让 1 MB 极端输入产生约 69 MB 峰值；已恢复流式摘要/校验和“验证后原字节复制”，并补 12-byte header、零 header CRC 与 local definition replacement 回归。
- Strava 批次复审报告的 OAuth 取消覆盖、桥接 DTO 明文 Debug、设置异步乱序均已修复；iOS、macOS、Android 重新完整构建，iOS 模拟器重新安装启动成功。

### Test Results
| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| `cargo fmt --check && cargo test` | Rust 格式正确、全部通过 | 25/25 通过 | ✅ |
| `fvm flutter test` | Flutter 单测/组件测试、原生通道契约及真实 Rust FFI 全部通过 | 30/30 通过 | ✅ |
| `fvm flutter analyze` | 无静态分析问题 | No issues found | ✅ |
| `fvm flutter build ios --simulator --debug` | Flutter UI 与 Rust 在 iOS 模拟器链接成功 | Built Runner.app | ✅ |
| `fvm flutter build macos --debug` | Flutter UI 与 Rust 在 macOS 链接成功 | Built health_workout_export.app | ✅ |
| `xcodebuild test`（Flutter Runner，iOS 26.5 模拟器） | HealthKit/Keychain/OAuth 原生边界测试通过 | 11/11 通过 | ✅ |
| `fvm flutter build apk --debug` | Flutter UI 与四 ABI Rust 在 Android 链接成功 | Built app-debug.apk | ✅ |
| `xcodebuild test`（iOS 26.5 模拟器） | Swift 基线全部通过 | TEST SUCCEEDED | ✅ |
| `xcodebuild test`（Mac 运行 iOS App） | 可安装测试宿主 | provisioning/未签名宿主不可安装 | ⚠️ 改用 iOS 模拟器完成验证 |

### Errors
| Error | Resolution |
|-------|------------|
| GitNexus 跳过 52 个 Swift 文件 | 首批保持现有 Swift 源码不动，以 `rg` 检索调用边界；后续再单独修复解析器 |
| Homebrew 自动更新出现无关提交 apply 警告 | 安装流程继续并成功完成 FVM；未修改或信任无关第三方 tap |
| Agent Reach 更新检查 DNS 失败 | 已按工具自身重试 3 次；不重复同一失败，暂不影响主任务 |
| 代理误提交并快进本地 main | 已恢复功能分支并重置本地 main 指针到 origin/main；远端 main 未改变 |
| FRB `integrate` 会覆盖入口并生成 demo | 不在项目内运行，仅移植必要构建钩子并生成真实 API 绑定 |
| iOS Cargokit 找不到 Rust 静态库 | 对齐 Rust package/产物名后，iOS 与 macOS 均构建通过 |
| Android 首次构建使用 JDK 25 且依赖下载缓慢 | Flutter 配置固定到 OpenJDK 17；依赖缓存完成后已构建成功 |
| Flutter iOS 模板 13.0 无法编译 iOS 16/17 HealthKit 类型 | 对齐原应用最低 iOS 17；模拟器构建和 RunnerTests 通过 |
| Gradle 9 删除 `Project.exec`，Cargokit Android task 失败 | 改用注入的 `ExecOperations`；Rust 四 ABI 编译通过 |
| FRB Android library 固定 compileSdk 33 | 对齐 Android 36；AndroidX metadata 检查及 Debug APK 构建通过 |
| 直接运行 `dart format` 找不到全局 Dart | 改用项目固定工具链的 `fvm dart format`，格式化与 analyze 通过 |
| iOS RunnerTests 在并行 FIT/Strava RED 中间态构建 Rust 失败 | FIT 临时借用错误已修复；最终 RunnerTests 11/11 与三平台构建均通过，不把并发中间态当产品缺陷 |
| FRB codegen 生成的 Rust import 顺序不符合 rustfmt | 生成后固定执行 `cargo fmt`；Rust 25/25 通过 |
