# Flutter + Rust 功能对等矩阵

## 目标与口径

本文件以当前 Swift 应用、`README.md`、`docs/使用教程.md` 和现有 XCTest 为功能基线。迁移完成的定义不是“页面能打开”，而是对应行的验收条件全部通过，且没有已知回归缺陷。

目标职责边界：

- **Flutter**：跨平台 UI、导航、展示状态、文件选择与分享入口。
- **Rust**：纯业务规则、FIT 处理、同步规则、可跨平台的网络与数据处理。
- **原生适配**：iOS HealthKit/Keychain/AuthenticationServices/WebKit/文件保护，Android Health Connect/Keystore/浏览器认证/后台调度，以及桌面平台能力。
- Flutter 与 Rust 之间按活动、文件或批次传输，禁止逐样本高频跨 FFI 调用。

状态定义：

- **未完成**：现有 Swift 功能尚未在新架构中通过对等验收。
- **Rust 已实现，未接入**：纯规则已存在于 `rust/workout_core`，但尚未由 Flutter/原生生产链路调用，不能视为功能完成。
- **Rust 部分实现，已接桥**：已有可由 Flutter 调用的 Rust 子能力，但本行仍有语义处理或生产流程未迁移，不能视为功能完成。
- **部分实现，已接入**：生产 UI/调用链已接入一个可用子流程，但本行仍有明确缺口或真机门禁，不能视为功能完成。
- **适配层已实现，未接入**：平台通道及契约测试已存在，但尚未接入生产 UI/业务链路，不能视为功能完成。
- **已实现，待平台验收**：代码和最小自动测试已接入，但尚缺真机或其余适用平台验收，不能视为功能完成。
- **完成**：实现、自动测试和适用平台验收全部通过；本矩阵初始没有此状态。

## 平台验收门槛

平台验收列固定按 **iOS → macOS → Android → Windows** 排列。Linux 不在本次迁移范围内。后续功能明细中的“共性验收条件”必须再叠加本表对应平台列；任何适用平台未通过，该功能均不得标为完成。

| 分组 | iOS 验收 | macOS 验收 | Android 验收 | Windows 验收 |
|---|---|---|---|---|
| UI | iPhone 真机，触控、系统字体、读屏、前后台切换 | Apple Silicon/Intel 支持范围内，窗口缩放、键鼠、读屏 | 主流真机，返回键、权限、字体缩放、TalkBack | 支持版本真机，窗口缩放、键鼠、高 DPI、Narrator |
| HealthKit | Swift 原生插件读取 HealthKit，与当前 App 真机数据对照 | 系统 HealthKit 能力可用时读取；不可用时明确提示并保留 FIT 导入 | 用 Health Connect 映射可对应字段，缺失字段明确标记 | 无 HealthKit；明确提示不可用并保留 FIT 导入，不伪造健康数据 |
| 第三方源 | 行者/顽鹿真实账号登录、恢复、列表和 FIT 下载 | 同一账号与 iOS 结果对照，凭证存 Keychain | 同一账号结果对照，凭证存 Keystore | 同一账号结果对照，凭证存 Windows Credential Manager |
| FIT | Rust 固定语料与 Swift 基线差分，真机导出可被 Strava/Garmin 解析 | 同一 Rust 语料结果一致 | 同一 Rust 语料结果一致 | 同一 Rust 语料结果一致 |
| 同步 | 三源真实数据到 Strava，覆盖、恢复、取消和幂等通过 | 可用源与文件导入场景结果一致 | Health Connect/第三方源场景结果一致 | 第三方源/FIT 导入场景结果一致 |
| Strava | AuthenticationServices OAuth 与 WKWebView Cookie 流程 | 系统浏览器/OAuth 与 WKWebView Cookie 流程 | Custom Tabs/OAuth 与受控 WebView Cookie 流程 | 系统浏览器/OAuth 与 WebView2 Cookie 流程 |
| 存储 | Application Support、Keychain、完整文件保护和不备份 | Application Support、Keychain、原子写入和文件权限 | App 私有目录、Keystore、原子写入和备份策略 | LocalAppData、Credential Manager、原子写入和 ACL |
| 安全 | 真机权限、Keychain、OAuth state、文件保护检查 | Keychain、沙盒/文件权限、OAuth state 检查 | Keystore、网络安全配置、OAuth state、私有目录检查 | Credential Manager、TLS、OAuth state、ACL 检查 |
| 后台任务 | 先保证当前“App 存活时继续”；系统挂起遵守 iOS 限制 | 窗口关闭/隐藏策略明确，任务可取消和恢复 | 生命周期切换及需要时的 WorkManager 验收 | 窗口最小化/关闭策略明确，任务可取消和恢复 |
| 导入导出 | Files/系统分享面板，安全作用域与临时文件清理 | NSOpenPanel/NSSavePanel/系统分享或保存 | Storage Access Framework/系统分享 | File Picker/Save Picker/系统分享或保存 |

## 1. UI

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| UI-01 | 应用启动与健康/行者/顽鹿三页签 | `HealthWorkoutExportApp.swift`、`RootTabView.swift` | 无 UI 自动测试 | Flutter | 冷启动进入三页签；切换页签不丢列表、选择和正在同步状态；iOS/Android/桌面按平台能力正确展示 | 未完成 |
| UI-02 | 近 7 天、30 天、今年、全部、自定义日期范围 | `DateRangeAndExportViews.swift`、`WorkoutBundle.swift`、`WorkoutDataSource.swift` | 无日期范围专测 | Flutter + Rust 日期规则 | 各预设生成与 Swift 相同的半开区间；自定义起止颠倒时自动归一；本地日历边界一致 | 已实现，待平台验收 |
| UI-03 | 健康训练列表、加载/空态/权限错误、全选与取消全选 | `WorkoutListView.swift`、`ExportViewModel.swift` | 无 UI 自动测试 | Flutter | 加载、空数据、授权失败和重试状态齐全；选择计数与批量选择行为一致 | 已实现，待平台验收 |
| UI-04 | 第三方源登录态、活动列表、退出、全选与导出入口 | `ThirdPartySourceListView.swift`、`SourceLoginView.swift` | 无 UI 自动测试 | Flutter | 未登录/登录中/已登录/会话过期状态正确；退出清理凭证并回到登录态 | 未完成 |
| UI-05 | 活动详情、同步印章、虚拟功率/同步 FIT 徽标、Strava 远端 ID | `ActivityDetailSheet.swift`、`WorkoutListView.swift`、`ThirdPartySourceListView.swift` | `SyncFingerprintTests.swift`（同步 FIT 可用性） | Flutter | 三类源展示相同状态；仅合法数字远端 ID 可打开；删除本地记录后徽标立即刷新 | 未完成 |
| UI-06 | 导出配置、格式/FIT 来源/时区、进度、结果分享和删除 | `DateRangeAndExportViews.swift`、`ExportViewModel.swift` | `FitActivityEncoderTests.swift`、`SyncFingerprintTests.swift` | Flutter | 缺同步 FIT 时选项置灰；进度和错误可恢复；结果可分享并可删除临时文件 | 未完成 |
| UI-07 | FIT 导入、训练选择、主源、时间对齐、合并结果 | `FitMergeView.swift` | `FitActivityEncoderTests.swift`（合并系列） | Flutter + Rust | 单文件直接导出；多文件必须选择主源；自动/手动/绝对时间模式和结果提示一致 | 未完成 |
| UI-08 | 自动同步配置、全局进度、继续/重试/停止和重复活动决策 | `AutoSyncView.swift`、`SyncSession.swift` | 无 UI 自动测试 | Flutter + Rust | 主补源联动、未登录禁选、当天/历史配置、重复弹窗、本批决策、继续/重试/取消均与 Swift 一致 | 未完成 |
| UI-09 | 同步历史筛选、批次选择、重传、清理、远端 ID 补全和异常速度扫描 | `SyncHistoryView.swift` | `SyncFingerprintTests.swift`、`StravaActivityLookupTests.swift` | Flutter + Rust | 失败/无远端 ID/去重/API/网页筛选正确；全选范围与批次选择正确；扫描与补全结果可追溯 | 未完成 |
| UI-10 | Strava 模式、OAuth、Cookie、GCJ 与限额设置页 | `StravaSettingsView.swift` | `StravaActivityLookupTests.swift`（限额解析） | Flutter + 原生认证适配 | API/网页模式切换、授权状态、Cookie 清理、GCJ 开关、15 分钟与每日限额展示一致 | 部分实现，已接入 |
| UI-11 | 中文文案、动态字体、读屏标签与破坏性操作确认 | 全部 SwiftUI 视图 | 无专项测试 | Flutter | 现有中文含义不丢失；主要操作支持系统字体缩放和读屏；清空、退出、删除均二次确认 | 未完成 |

## 2. HealthKit

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| HK-01 | HealthKit 可用性、读取授权、隐私说明与 entitlement | `HealthKitService.swift`、`Info.plist`、`HealthWorkoutExport.entitlements` | 无；需真机 | iOS 原生 Swift 插件 | 真机首次授权、拒绝、重新授权和系统设置跳转可用；只申请现有读取类型；非 Apple 平台显示明确不可用/替代入口 | 已实现，待平台验收 |
| HK-02 | 严格按开始时间查询训练摘要并按时间倒序 | `HealthKitService.swift`、`HealthKitDataSource.swift` | 无；需真机 | iOS 原生 Swift 插件 | `[start,end)` 查询结果、摘要字段、来源名称、活动中文名和排序与 Swift 基线一致 | 已实现，待平台验收 |
| HK-03 | 训练缓存与按 UUID 回查，避免列表后逐条 N+1 | `HealthKitService.swift` | 无 | iOS 原生 Swift 插件 | 同批导出优先命中缓存；缓存缺失可按 UUID 回查；并发导出无竞态或错误复用 | 适配层已实现，未接入 |
| HK-04 | 读取心率、能量、距离、步频/踏频、跑步动态、速度和功率等序列 | `HealthKitService.swift`、`WorkoutBundle.swift` | `FitActivityEncoderTests.swift`（编码侧字段） | iOS 原生 Swift 插件 → Rust 批量模型 | 各 quantity 使用与 Swift 相同单位；关联查询失败时保留现有来源/日期兜底；空序列不伪造数据 | 适配层已实现，未接入 |
| HK-05 | 读取路线、多段 route、海拔/时间/速度、训练事件和 metadata | `HealthKitService.swift`、`WorkoutBundle.swift` | `FitActivityEncoderTests.swift`（事件/JSON/路线编码） | iOS 原生 Swift 插件 → Rust 批量模型 | 多段路线顺序稳定；暂停/恢复等事件名称一致；可选值与 metadata 序列化不崩溃 | 适配层已实现，未接入 |
| HK-06 | HealthKit 活动转换为统一数据源并现场生成 FIT | `HealthKitDataSource.swift`、`FitActivityEncoder.swift` | `FitActivityEncoderTests.swift` | 原生 HealthKit + Rust FIT | 同一训练生成的统一活动 ID、时间、距离和 FIT 语义与当前 Swift 输出一致 | 部分实现，已接入 |
| HK-07 | Android 健康数据对应能力 | 当前 Swift 无 Android 实现 | 无 | Android 原生 Health Connect 插件 | 明确映射可支持字段；无法等价的 HealthKit 字段标记缺失而非伪造；权限、撤销和无服务状态可测 | 未完成 |

## 3. 第三方数据源

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| SRC-01 | 统一数据源契约与健康/行者/顽鹿注册 | `WorkoutDataSource.swift`、`HealthKitDataSource.swift`、`XingzheDataSource.swift`、`OnelapDataSource.swift` | `ActivityMatcherTests.swift`（统一活动参与匹配） | Rust 数据模型 + Flutter 注册/调度 | 三源统一支持认证状态、登录/退出、列表和 FIT 获取；源 ID 与活动 ID 保持稳定 | 未完成 |
| SRC-02 | 行者 RSA 密码登录、`sessionid` 提取与恢复 | `XingzheClient.swift`、`XingzheDataSource.swift` | `XingzheRateLimitTests.swift`（限流解析） | Rust HTTP/RSA + 原生安全存储 | 真实账号登录、Cookie 多头兼容、冷启动恢复、过期重登和退出全部通过 | Rust 已接桥，未接安全存储/UI |
| SRC-03 | 行者分页活动列表、时间筛选、FIT 下载与限流等待 | `XingzheClient.swift`、`XingzheDataSource.swift` | `XingzheRateLimitTests.swift` | Rust | 7/30/全年/全部/自定义结果与当前客户端一致；限流响应按服务端提示等待；取消可立即生效 | 未完成 |
| SRC-04 | 顽鹿签名登录、token/uid 会话与恢复 | `OnelapClient.swift`、`OnelapDataSource.swift` | `ActivityMatcherTests.swift`（可信 URL） | Rust HTTP/签名 + 原生安全存储 | 真实账号登录、冷启动恢复、过期重登和退出通过；认证头只发往允许域名 | 未完成 |
| SRC-05 | 顽鹿骑行列表、分页、详情与 FIT 下载 | `OnelapClient.swift`、`OnelapDataSource.swift` | 无真实接口自动测试 | Rust | 时间范围、分页终止、活动字段和下载 FIT 与 Swift 基线一致；错误信息不泄露凭证 | 未完成 |
| SRC-06 | 第三方源错误、空列表、网络超时和取消语义 | `WorkoutDataSource.swift`、两个 Client/DataSource | 仅部分限流测试 | Rust + Flutter | 未认证、登录失败、拉取失败、超时、取消分别呈现；重试不产生重复请求或状态错乱 | 未完成 |

## 4. FIT

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| FIT-01 | WorkoutBundle 编码 Garmin FIT | `FitActivityEncoder.swift` | `FitActivityEncoderTests.swift`（头、累计距离、动态字段、事件） | Rust | 合成和真机样本均可被 Garmin/Strava 解码；时间、距离、事件、路线和传感器字段与基线一致 | 已实现，待平台验收 |
| FIT-02 | FIT 解码、重编码、有效性和内容质量探测 | `FitMerger.swift` 中 `FitMessagesReencoder`、`FitContentProbe` | `FitActivityEncoderTests.swift` | Rust | 非 FIT 被拒绝；重编码保留未知/数组字段；GPS、心率点数和质量分稳定 | Rust 部分实现，已接桥 |
| FIT-03 | 主文件优先、补文件只填缺失字段 | `FitMerger.swift` | `FitActivityEncoderTests.swift`（主源优先、补缺） | Rust | 字段冲突主源胜出；缺失传感器可补；不插入不允许的 GPS/间隙记录 | Rust 最小实现，未接业务 |
| FIT-04 | 全字段与仅传感器补充模式 | `FitMerger.swift` | `FitActivityEncoderTests.swift` | Rust | 两种模式在记录插入、GPS、事件、lap/session 处理上与 Swift 一致 | 未完成 |
| FIT-05 | 自动、手动、逐文件和绝对时间对齐 | `FitMerger.swift`、`FitMergeView.swift` | `FitActivityEncoderTests.swift`（时钟偏差、互相关、累计距离兜底） | Rust + Flutter | 同场可估偏移；不同活动拒绝自动对齐；手动偏移和逐文件偏移精确生效；估算失败有明确错误 | 未完成 |
| FIT-06 | 合并后事件/lap 排序、距离重基准和 session 范围修正 | `FitMerger.swift` | `FitActivityEncoderTests.swift` | Rust | 事件和 lap 时间单调；分段总距离正确；session 覆盖全部合并记录；数组字段完整 | 未完成 |
| FIT-07 | GPS 速度尖峰识别与修复 | `FitMerger.swift` 中 `FitSpeedSpikeFixer` | `FitActivityEncoderTests.swift`、`VirtualPowerPhysicsTests.swift` | Rust | 瞬时跳变并回落时修复；持续真实加速/急刹不误修；修复后 FIT 仍有效 | 未完成 |
| FIT-08 | GCJ-02 → WGS-84 坐标转换和 FIT 重写 | `FitMerger.swift` 中 `Gcj02ToWgs84`、`FitGcjCoordinateRewriter` | `FitActivityEncoderTests.swift` | Rust | 中国境内坐标转换与基线误差在容差内；境外不移动；仅开关开启时改写上传副本 | 未完成 |
| FIT-09 | Gribble 虚拟功率物理、风/坡度/惯性和滑行规则 | `VirtualPowerPhysics.swift`、`VirtualPowerSettings.swift` | `VirtualPowerPhysicsTests.swift` | Rust | 稳态算例、负功率、踏频 0、空气密度、风向、坡度、加速度钳位逐项通过移植测试 | Rust 已实现，未接入 |
| FIT-10 | Open-Meteo 数据源分流、Archive 回退和网格/日期缓存 | `OpenMeteoWeatherClient.swift`、`OpenMeteoWeatherCache.swift` | `OpenMeteoWeatherClientTests.swift`、`OpenMeteoWeatherCacheTests.swift` | Rust | 近 7 天/2022 后/更早分流一致；失败回退 Archive；取消不回退；缓存键与过期行为一致 | 未完成 |
| FIT-11 | 虚拟功率覆盖、失败秒邻值、失败率门槛和活动类型过滤 | `FitVirtualPowerFiller.swift` | `FitVirtualPowerFillerTests.swift` | Rust | 现有全部 filler 测试移植通过；失败率 ≥10% 拒绝整场；非骑行跳过；残留功率不泄漏 | 未完成 |
| FIT-12 | `powerSource=virtual` 标记、结果徽标与活动描述文案 | `VirtualPowerSourceMark.swift`、`VirtualPowerSocialCopy.swift` | `FitVirtualPowerFillerTests.swift`、`VirtualPowerSocialCopyTests.swift` | Rust | 标记可写可读且不破坏 FIT；仅实际写入虚拟功率时展示徽标并生成确认文案 | 未完成 |

## 5. 同步

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| SYNC-01 | 当天、历史 7/30/90 天、全部和自定义同步区间 | `AutoSyncEngine.swift`、`WorkoutDataSource.swift` | 无专项测试 | Rust | 当天按本地日历 `[00:00,次日00:00)`；历史与自定义半开区间和 Swift 一致 | 未完成 |
| SYNC-02 | 主源与一个/两个补源活动匹配 | `ActivityMatcher.swift`、`AutoSyncEngine.swift` | `ActivityMatcherTests.swift` | Rust | IoU ≥50% 优先；否则开始差 ≤15 分钟且时长差 ≤20%；擦边和远距离活动不匹配 | Rust 已接桥，未进入补源编排 |
| SYNC-03 | 拉主源 FIT、缺补源可跳过、匹配补源后合并上传 | `AutoSyncEngine.swift` | FIT/匹配有单测，编排无端到端测试 | Rust 编排 + 原生源适配 | 单条补源失败不拖垮主活动；每条结果、跳过原因和计数准确；批次可取消 | 未完成 |
| SYNC-04 | SHA-256 同步指纹，补源排序后稳定 | `SyncFingerprint.swift` | `SyncFingerprintTests.swift` | Rust | 相同输入和不同补源顺序得到相同 64 位小写摘要；任一业务字段变化会改变指纹 | Rust 已接桥，HealthKit 首传已使用 |
| SYNC-05 | 跨主源开始时间/距离/时长稳定去重 | `SyncFingerprint.swift` 中 `SyncStableDedupe`、`SyncStateStore.swift`、`StravaActivityLookup.swift` | `SyncFingerprintTests.swift` | Rust | 紧窗、宽窗、距离绝对/相对误差和时长误差全部通过；生产链路改为调用 Rust 后再标完成 | Rust 已接桥，尚未接入去重决策 |
| SYNC-06 | 跳过同指纹、同主活动或稳定近似的历史记录，异常速度例外 | `AutoSyncEngine.swift`、`SyncStateStore.swift`、`StravaActivityLookup.swift` | `SyncFingerprintTests.swift`、`StravaActivityLookupTests.swift` | Rust | 开关开启时三层去重准确；被判异常的骑行仍可重传；关闭后交由远端预检决策 | 未完成 |
| SYNC-07 | 上传前远端预检与重复活动决策 | `AutoSyncEngine.swift`、`StravaActivityLookup.swift`、`SyncSession.swift` | `StravaActivityLookupTests.swift` | Rust + Flutter | IoU/开始+时长/开始+距离匹配一致；支持跳过、整批跳过、打开远端、覆盖、整批覆盖 | 未完成 |
| SYNC-08 | 同步进度、结果备注、取消、继续上次同步与整批重试 | `SyncSession.swift`、`AutoSyncEngine.swift` | 无编排自动测试 | Flutter + Rust | processed/uploaded/deduped/failed 计数不漂移；取消快速终止；继续只跑剩余；重试按原配置执行 | 未完成 |
| SYNC-09 | 勾选历史记录覆盖重传和删除远端前落盘恢复 | `AutoSyncEngine.swift`、`SyncHistoryView.swift`、`SyncStateStore.swift` | `SyncFingerprintTests.swift`（恢复文件） | Rust + 原生受保护存储 | 删除远端前最终上传包已原子保存；删除后上传失败可再次恢复；成功后清理恢复文件 | 部分实现，未接入 |
| SYNC-10 | 批次内速度尖峰修复、GCJ、虚拟功率的固定处理顺序 | `AutoSyncEngine.swift` | 各处理器有单测，顺序无端到端测试 | Rust | 首传和重传均严格执行“尖峰 → GCJ → 虚拟功率 → 探测 → 上传”；各开关只影响对应步骤 | 未完成 |

## 6. Strava

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| STRAVA-01 | API/网页两种上传模式和统一上传契约 | `StravaUploading.swift`、两个 Uploader | `StravaActivityLookupTests.swift`（轮询/错误） | Rust 接口 + 原生认证/WebView | 两模式 readiness、上传结果、错误和重复语义统一；切换模式不丢各自凭证 | 未完成 |
| STRAVA-02 | OAuth 自定义 scheme、token 保存/刷新与 scope | `StravaAPIUploader.swift`、`StravaUploading.swift`、`Info.plist` | 无真实 OAuth 自动测试 | iOS AuthenticationServices / Android 浏览器认证 + Rust token 客户端 | `healthworkoutexport://localhost/callback` 在 iOS 保持兼容；授权、取消、过期刷新、撤销后重登均通过 | 部分实现，已接入 |
| STRAVA-03 | Uploads API multipart FIT、轮询、错误清洗与远端 ID | `StravaAPIUploader.swift`、`StravaUploading.swift` | `StravaActivityLookupTests.swift` | Rust | 首次立即轮询、总预算约 70 秒、处理中/成功/重复/硬失败分支一致；HTML 错误不会直接展示 | 未完成 |
| STRAVA-04 | API 活动列表、详情速度、分页和限额响应头 | `StravaAPIUploader.swift`、`StravaActivityLookup.swift` | `StravaActivityLookupTests.swift` | Rust | 活动分页无重复遗漏；ID 类型兼容；15 分钟/每日 read/overall 限额解析与 429 保留 | Rust 已接桥，未接预检 UI |
| STRAVA-05 | WebView 登录 Cookie、CSRF 上传、网页活动列表和 Cookie 删除远端 | `StravaWebUploader.swift` | 重复文案有单测；真实网页无自动测试 | 原生 WebView/Cookie + Rust/原生网页客户端 | 登录后 Cookie 可恢复；CSRF 上传可用；Cookie 过期提示明确；覆盖删除只命中目标活动；网页改版失败不损坏本地状态 | 未完成 |
| STRAVA-06 | duplicate 文案/HTML 解析与活动 ID 提取 | `StravaActivityLookup.swift` | `StravaActivityLookupTests.swift` | Rust | 大小写、纯文本、HTML 链接、缺失和 NSNull/数字 ID 等现有用例全部通过 | 未完成 |
| STRAVA-07 | 远端活动匹配、可打开 ID、远端 ID 回填 | `StravaActivityLookup.swift`、`SyncStateStore.swift`、`SyncHistoryView.swift` | `StravaActivityLookupTests.swift`、`SyncFingerprintTests.swift` | Rust + Flutter deep link | 匹配不误伤热身/短段；回填严格小于 2 分钟且 ID 不重复占用；有效 ID 可打开 Strava | 未完成 |
| STRAVA-08 | 骑行异常速度扫描：摘要、最佳成绩和速度流 | `StravaActivityLookup.swift`、两个 Uploader、`SyncHistoryView.swift` | `StravaActivityLookupTests.swift` | Rust + Flutter | 仅骑行参与；阈值、最佳成绩优先级、占位 ID 与本地记录标记和 Swift 一致 | 未完成 |
| STRAVA-09 | API 通勤自动标记 | `CommuteClassifier.swift`、`AutoSyncEngine.swift` | `CommuteClassifierTests.swift` | Rust | `<5km` 或“均速 `<28km/h` 且距离 `<16km`”严格边界通过；只在 API 上传写 commute；生产链路接入后再标完成 | Rust 已接 HealthKit 首传 |
| STRAVA-10 | 虚拟功率活动描述仅在可支持的上传路径写入 | `AutoSyncEngine.swift`、`StravaAPIUploader.swift`、`StravaWebUploader.swift` | `VirtualPowerSocialCopyTests.swift` | Rust + 上传适配 | 仅 `powerSource=virtual` 时生成；API 成功携带描述；网页不支持时不谎报已写入 | 未完成 |

## 7. 存储

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| STORE-01 | `sync_state.json` 状态机：pending/uploaded/failed/duplicate/channel | `SyncStateStore.swift` | `SyncFingerprintTests.swift` | Rust 持久化模型 + 原生文件目录 | 冷启动往返不丢字段；uploaded 可被后台硬错误改为 failed；duplicate 可补远端 ID；旧字段兼容 | 部分已接 HealthKit 首传 |
| STORE-02 | 按指纹保存最终同步 FIT，并维护主活动索引/徽标 | `SyncStateStore.swift` | `SyncFingerprintTests.swift` | Rust 索引 + 原生文件存储 | 上传成功原子保存；列表索引只反映真实存在文件；删除记录同步删 FIT；旧记录无文件时正确降级 | 部分已接 HealthKit 首传 |
| STORE-03 | `pending_resync` 覆盖恢复包 | `SyncStateStore.swift` 中 `ResyncRecoveryStore` | `SyncFingerprintTests.swift` | Rust 编解码 + 原生受保护文件 | 仅合法十六进制指纹可成为文件名；保存/读取/删除往返一致；崩溃后可恢复 | 部分实现，未接入 |
| STORE-04 | Strava、虚拟功率与界面偏好 | `StravaUploading.swift`、`VirtualPowerSettings.swift`、各 ViewModel | 部分纯规则测试 | Flutter preferences + 原生安全存储 | 模式、GCJ、惯性、质量、车重、CdA 等默认值和持久化一致；凭证绝不进入普通 preferences | 部分实现，已接入 |
| STORE-05 | Open-Meteo 缓存 | `OpenMeteoWeatherCache.swift` | `OpenMeteoWeatherCacheTests.swift` | Rust | 同网格/同日/同来源命中；跨日或来源变化未命中；容量和生命周期不会无限增长 | 未完成 |
| STORE-06 | 现有数据迁移与回滚 | 当前 Swift 文件/Keychain/UserDefaults 键 | 无迁移测试 | 原生迁移层 + Rust schema | 首次新版本启动可读取原 App 的凭证、设置、同步记录、最终 FIT 和恢复文件；失败不删除旧数据；可回滚 | 未完成 |

## 8. 安全

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| SEC-01 | 行者、顽鹿、Strava 凭证与 Cookie 存系统 Keychain | `KeychainStore.swift`、各 DataSource、`StravaUploading.swift` | 无设备级测试 | iOS Keychain / Android Keystore 封装 / 桌面凭证库 | 普通文件、日志、崩溃信息和 Flutter preferences 中无明文秘密；升级迁移后仍可读取；退出/清除彻底删除 | 部分实现，已接入 |
| SEC-02 | 顽鹿认证请求只允许可信 HTTPS 主机 | `OnelapClient.swift` | `ActivityMatcherTests.swift` | Rust URL 校验 | HTTPS、精确允许域、重定向后主机均校验；HTTP、子域伪装、用户名主机混淆全部拒绝 | 未完成 |
| SEC-03 | 行者 RSA 登录与会话 Cookie 边界 | `XingzheClient.swift` | `XingzheRateLimitTests.swift`（非安全专项） | Rust + 原生安全存储 | 密码只在登录请求短暂存在；RSA/随机数失败直接中止；sessionid 不发送给非行者域名 | 未完成 |
| SEC-04 | OAuth state、回调 scheme、token 刷新和网页 CSRF/Cookie 隔离 | `StravaAPIUploader.swift`、`StravaWebUploader.swift` | 无安全专项测试 | 原生认证/WebView + Rust | 回调必须匹配本次 state 和 scheme；Cookie 仅发 Strava；CSRF 缺失不上传/删除；重定向不可越权 | 部分实现，已接入 |
| SEC-05 | 同步 FIT/恢复文件完整保护、原子写入、排除备份 | `SyncStateStore.swift` | `SyncFingerprintTests.swift` | iOS 原生文件保护 / Android 加密存储 / 桌面权限 | iOS 维持 complete file protection 与不备份；中断写入不产生半文件；各平台采用等价的最小权限 | 未完成 |
| SEC-06 | HealthKit 本地处理、最小授权与隐私披露 | `HealthKitService.swift`、`Info.plist`、教程 | 无；需真机/审核 | 原生 | 只读且只请求当前需要类型；未授权数据不上传；隐私文案与实际流向一致 | 未完成 |
| SEC-07 | 不可信 FIT、JSON、远端响应和文件名输入验证 | FIT/导出/Client/Store 各实现 | 仅部分非 FIT、JSON nil、错误解析测试 | Rust | 畸形/超大输入有上限并返回可诊断错误；路径穿越、zip slip、崩溃、越界和秘密回显测试通过 | 未完成 |

## 9. 后台任务与生命周期

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| BG-01 | 关闭自动同步页或切换 Tab 后，同步在 App 进程内继续 | `SyncSession.swift`、`RootTabView.swift`、`AutoSyncView.swift` | 无生命周期测试 | Flutter 全局 session + Rust worker | 页面销毁/重建和 Tab 切换不取消任务；任意入口看到同一进度；同一时间只允许一个批次 | 未完成 |
| BG-02 | 用户主动停止与网络/天气取消传播 | `SyncSession.swift`、`AutoSyncEngine.swift`、`FitVirtualPowerFiller.swift`、`OpenMeteoWeatherClient.swift` | `FitVirtualPowerFillerTests.swift`（取消） | Flutter → Rust cancellation token | 停止后不再开始新上传；网络和天气请求可取消；Cancellation 不被当作普通失败或触发 Archive 回退 | 未完成 |
| BG-03 | 失败后继续、整批重试和覆盖恢复 | `SyncSession.swift`、`SyncStateStore.swift`、`AutoSyncEngine.swift` | `SyncFingerprintTests.swift`（恢复） | Rust + 持久化 | 前台中断、进程终止和设备重启后都能识别可恢复项；不会重复删除远端或重复上传成功项 | 未完成 |
| BG-04 | 长历史同步的前台限制与平台后台能力 | 教程注明“全部可能较久，保持 App 在前台” | 无 | Flutter + iOS BGTask/Android WorkManager（仅在能力允许时） | 首先完整保留“前台运行”语义；若增加系统后台任务，必须满足 HealthKit/网络平台限制、可取消且不会改变幂等结果 | 未完成 |
| BG-05 | 系统挂起、低内存、无网和应用升级恢复 | 当前实现仅由本地状态部分覆盖 | 无 | 原生生命周期 + Rust | 每个阶段在持久化检查点后可安全重入；恢复后计数、记录和远端状态一致；无数据损坏 | 未完成 |

## 10. 导入导出

| ID | 当前功能 | Swift 实现基线 | 已有测试 | 目标归属 | 对等验收条件 | 状态 |
|---|---|---|---|---|---|---|
| IO-01 | HealthKit 完整 JSON：摘要、metadata、事件、序列、路线 | `WorkoutBundle.swift`、`ExportPipeline.swift` | `FitActivityEncoderTests.swift`（JSON 可选值/核心字段/时区） | Rust JSON + Flutter 文件流程 | 字段名、可选字段省略规则、ISO8601 小数秒和时区偏移与 Swift 基线一致 | 已实现，待平台验收 |
| IO-02 | 行者/顽鹿活动摘要 JSON | `ExportPipeline.swift` | 无专项测试 | Rust | 活动 ID、源、标题、起止、时长、距离和时区字段齐全；不伪造第三方源没有的明细 | 未完成 |
| IO-03 | HealthKit 生成 FIT、第三方原始 FIT、Strava 同步版 FIT | `ExportPipeline.swift`、`FitActivityEncoder.swift`、`SyncStateStore.swift` | `FitActivityEncoderTests.swift`、`SyncFingerprintTests.swift` | Rust + 原生文件存储 | 三种来源选择正确；同步版缺失立即阻止；导出字节与保存/下载/生成源一致 | 部分实现，已接入 |
| IO-04 | 批量并发导出与进度 | `ExportPipeline.swift` | 无并发专项测试 | Rust worker + Flutter | 并发上限不会压垮 HealthKit/第三方源；进度从 0 到总数单调；任一失败可诊断且不分享残缺结果 | 未完成 |
| IO-05 | 单文件直接分享，多文件 ZIP | `ExportPipeline.swift` 中 `ZipWriter` | 无 ZIP 专测 | Rust ZIP + Flutter/原生分享 | 单文件不额外打包；多文件 zip 可由系统工具解压；CRC、UTF-8 文件名和空选择错误正确 | 已实现，待平台验收 |
| IO-06 | 文件名、时区候选和上海时区保证 | `ExportPipeline.swift`、`WorkoutBundle.swift` | `FitActivityEncoderTests.swift` | Rust | 文件名时间戳、类型清洗、ID 前缀、当前时区与固定候选同 Swift；跨夏令时测试通过 | 未完成 |
| IO-07 | 导入一个/多个 FIT 和从 HealthKit 训练生成待合并 FIT | `FitMergeView.swift`、`HealthKitService.swift`、`FitActivityEncoder.swift` | `FitActivityEncoderTests.swift` | Flutter 文件选择 + 原生 HealthKit + Rust FIT | 支持安全作用域/平台文件权限；拒绝无效 FIT；两种来源可混合；重复文件处理明确 | 未完成 |
| IO-08 | 分享、保存、结果删除与历史临时目录清理 | `DateRangeAndExportViews.swift`、`FitMergeView.swift`、`ExportPipeline.swift` | 无 | Flutter + 原生文件/分享 API | iOS/Android/桌面均可保存或分享；删除只作用于本次临时结果；旧临时目录可控清理且不删同步 FIT | 已实现，待平台验收 |

## 完成门槛

任何一行从“未完成”改为“完成”前，至少满足：

1. 现有对应 XCTest 已移植到 Rust/Flutter/原生测试并通过；没有现有测试的功能补最小自动测试。
2. 使用固定样本做 Swift 与新实现的差分测试；JSON/FIT 字节不要求无意义的编码顺序一致，但业务字段和解析结果必须一致。
3. 涉及系统能力的行按固定顺序完成 iOS、macOS、Android、Windows 验收；平台不存在对应能力时必须通过本表规定的不可用态/替代入口验收。
4. 错误、取消、超时、空数据、会话过期、进程终止和重复操作场景均有明确结果，不允许静默丢数据。
5. 发现已知缺陷时该行不得标为完成；先记录复现、修复并补回归测试。
