# Task Plan: Flutter + Rust 渐进迁移

## Goal
在不破坏现有 SwiftUI 应用和用户未提交改动的前提下，完成移动端优先的 Flutter UI、Rust 核心与 Swift/Kotlin 健康数据适配迁移；现有功能逐项达到行为一致，并通过自动化与平台构建验证后才交付。

## Current Phase
Phase 1

## Phases

### Phase 1: Requirements & Discovery
- [x] 确认移动端优先、Flutter 统一 UI、Rust 核心
- [x] 检查本机版本管理器与现有开发环境
- [x] 重新索引并确认现有 Swift 调用边界
- [x] 完成前端修改二次确认
- **Status:** in_progress

### Phase 2: Planning & Structure
- [ ] 通过 FVM/rustup/fnm 固定工具链
- [ ] 旁路创建 Flutter 应用与 Rust workspace，不覆盖现有 Xcode 工程
- [ ] 跑通 Dart ↔ Rust 最小调用链
- **Status:** pending

### Phase 3: Implementation
- [ ] 迁移跨平台领域模型和 FIT 处理
- [ ] iOS：Swift HealthKit/Keychain/后台任务适配与全部功能对等
- [ ] macOS：桌面文件能力、Apple 平台适配与全部可用功能对等
- [ ] Android：Kotlin Health Connect/凭据/后台任务适配与全部功能对等
- [ ] Windows：桌面文件能力与全部可用功能对等
- [ ] 各平台迁移第三方数据源、Strava OAuth/上传、同步历史、列表、导出和设置
- **Status:** pending

### Phase 4: Testing & Verification
- [ ] 验证 Flutter、Rust、iOS 与 Android 构建
- [ ] 对照现有 Swift 测试验证 FIT 与同步结果一致
- [ ] 运行 GitNexus detect_changes 并记录结果
- [ ] 建立功能对等矩阵，关闭全部已知差异与回归缺陷
- **Status:** pending

### Phase 5: Delivery
- [ ] Review outputs
- [ ] Deliver to user
- **Status:** pending

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| 采用 Flutter + Rust，不采用 Tauri | 移动端优先，避免 WebView UI 与自研移动插件扩大风险 |
| 新架构旁路增量建立 | 当前工作区有未提交 Swift 修改，不能覆盖或重置 |
| Flutter/FVM、Rust/rustup、Node/fnm | 满足工具链可复现与版本可切换要求 |
| 首批仅做骨架和最小链路 | 先验证工具链与桥接，再迁移业务，减少一次性重写风险 |
| 首个 Rust 切片迁移通勤判定 | 纯函数、已有 Swift 测试语义、生产调用点明确，适合低风险验证 |
| 第二个 Rust 切片迁移稳定去重 | `SyncStateStore` 与 `StravaActivityLookup` 共用规则，纯函数且已有 Swift 测试 |
| Flutter-Rust 桥接锁定稳定版 2.12.0 | 2.13 仍为 beta；稳定版已覆盖四个目标平台 |
| 平台顺序为 iOS → macOS → Android → Windows | 用户明确指定；Linux 不纳入本次迁移范围 |

## Errors Encountered
| Error | Resolution |
|-------|------------|
| GitNexus 缺少可用的 `tree-sitter-swift` 原生绑定 | 索引无法提供 Swift 符号影响图；迁移首批不改现有 Swift 符号，并使用 `rg` 调用检索补足边界分析 |
| Homebrew 自动更新时一个无关提交无法 apply | Homebrew 随后正常更新并成功安装 FVM，无需信任或修改无关 tap |
| FRB 2.12.0 锁文件引用已 yanked 的构建期 `futures-util 0.3.29` | 仅代码生成器构建依赖且安装成功；运行时依赖后续使用当前稳定解析结果 |
| Agent Reach 更新检查 DNS 解析失败，重试 3 次 | 不影响已完成的官方资料读取与当前迁移，后续网络恢复再检查 |
