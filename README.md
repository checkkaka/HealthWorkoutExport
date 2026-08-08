# HealthWorkoutExport

按时间范围从 HealthKit 导出体能训练（摘要 + GPS + 心率等时间序列），默认 JSON，可选 Garmin FIT。  
支持多数据源（健康 / 行者 / 顽鹿）合并补缺后，幂等自动同步到 Strava。

**详细使用教程（推荐先读）：** [docs/使用教程.md](docs/使用教程.md)

## 打开工程

```bash
open HealthWorkoutExport.xcodeproj
```

1. **Signing & Capabilities** 选择你的 Team（真机读 HealthKit 建议付费 Developer）
2. 用 **真机** 运行（模拟器无法完整体验健康数据）
3. 允许读取健康数据后，选时间范围 → 勾选训练 → 导出

## 功能

- 时间维度：近 7 天 / 30 天 / 今年 / 自定义
- 导出完整 JSON（摘要、事件、路线、心率等序列）
- 可选同时生成 `.fit`；多文件自动打 zip 再分享
- **合并 FIT**：选主文件，其余补缺（设备时钟可用自动/手动对齐）
- **多页签数据源**：健康 / 行者 / 顽鹿
- **自动同步**：选主源 + 可选补源 → `FitMerger` 合并 → 幂等上传 Strava（当天 / 历史，含全部与自定义）
- **同步恢复**：失败后可继续剩余项目或整批重试；重复活动会进入覆盖确认
- **远端关联**：健康、行者、顽鹿三个页签显示本地记录的 Strava 远端 ID，可直接打开对应活动；历史页支持补全缺失 ID

## 数据源登录

| 源 | 方式 |
|---|---|
| 健康 | 系统 HealthKit 授权 |
| 顽鹿 | App 内账号密码（本机 Keychain） |
| 行者 | App 内账号密码登录网页会话（RSA 加密密码 → `sessionid`），无需开发者 API；对齐 WanSync / SyncOnelapToXoss |

## Strava

- **API（默认）**：自备 Client ID/Secret，App 内 OAuth；上传走 [Uploads API](https://developers.strava.com/docs/reference/) `POST /uploads`，支持 `commute` 字段
- **网页**：WebView 登录后用 Cookie 上传（不依赖 API 上传权限；**通勤标记仅 API 模式生效**）
- 回调：`healthworkoutexport://localhost/callback`（Authorization Callback Domain 填 `localhost`）
- API 设置页显示 Strava 响应头返回的 15 分钟与每日限额使用情况

### 通勤自动标记（API）

满足任一条件则上传时 `commute=1`：

- 距离 &lt; 5 km
- 或平均速度 &lt; 28 km/h **且** 距离 &lt; 16 km

## 本地状态与隐私

App 运行时会在自身沙盒中用 `sync_state.json` 记录同步指纹：

`sha256(主源|活动ID|开始时间|排序后的补源列表|strava)`

已成功上传会跳过；补源集合变更会生成新键。该文件不是项目文件，也不会提交到仓库。

- HealthKit 数据、同步状态和待恢复任务仅保存在设备本地
- 顽鹿、行者与 Strava 的登录凭证保存在系统 Keychain
- 登录凭证只发送给对应平台；顽鹿凭证仅允许发送到顽鹿 HTTPS 域名
- 导出文件由用户通过系统分享面板自行处理，项目不包含任何账号、Cookie 或个人运动数据

## 验证状态

- 模拟器编译：需本地 `xcodebuild` 验证
- 单元测试：`ActivityMatcher` / `SyncFingerprint` / `CommuteClassifier` / `FitActivityEncoder` / `StravaActivityLookup`
- HealthKit / 行者 / 顽鹿 / Strava：需真机与真实账号自测

## 主要目录

- `WorkoutDataSource.swift`：可插拔数据源协议与注册表
- `HealthKitDataSource` / `XingzheDataSource` / `OnelapDataSource`
- `AutoSyncEngine` / `ActivityMatcher` / `SyncStateStore` / `CommuteClassifier`
- `StravaAPIUploader` / `StravaWebUploader`
- `RootTabView` / `AutoSyncView` / 各设置页

## 许可

本项目采用 [GNU General Public License v3.0](LICENSE)（GPL-3.0）。

- 可商用、可修改、可再分发
- 再分发时须保留版权与许可声明
- 衍生作品须以 GPL-3.0（或兼容的同类 copyleft）开源，不可闭源再分发

Copyright (C) 2026 checkkaka
