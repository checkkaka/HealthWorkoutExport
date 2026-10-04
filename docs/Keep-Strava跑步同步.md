# Keep 跑步同步到 Strava（实验性）

适用：Flutter/Rust 客户端。旧 Swift 客户端不包含本功能。

## 使用

1. 打开 **Keep** 页签，先阅读非官方接口和账号风险提示
2. 输入自己的 Keep 手机号/账号与密码。密码只用于本次登录，不保存；登录成功后仅把账号和令牌写入系统安全存储
3. 选择时间范围并刷新，勾选室外/室内跑步记录
4. 在 **Strava 设置** 使用已有应用配置完成授权，确保有 `activity:write` 上传权限。使用 API 模式即可使用官方上传接口；无需新建付费服务
5. 点击 **自动同步所选**，检查预览再上传。跑步保留跑步类型和标题，不会自动改成“通勤🚲”。室内跑步不创建虚假轨迹
6. 成功后可在记录/详情页打开 Strava 活动、导出实际上传的 FIT；失败后可继续剩余项目或恢复保存的最终 FIT

运动记录可能包含路线、心率、时间和距离。只有用户启动同步才会上传到 Strava，活动可见范围按 Strava 账号设置处理。请检查默认隐私范围后再上传。

## 能力与边界

- Keep 读取端使用非官方、未承诺兼容性的接口；Strava API 上传端使用官方 Uploads API
- 支持 `outdoorRunning`、`indoorRunning`，保留 Keep 字符串活动 ID，时间按 UTC、距离按米、时长按秒处理
- 已获得的 GPS/心率按其真实时间保存；缺失内容保持缺失，不补造路线/心率/步频。GCJ-02 坐标转换为 WGS84 一次；全局纠偏设置不会再次修改已转换的 Keep 文件
- FIT 的绝对时间保留原始时间，当前 Keep 导出将 FIT 本地时间字段按 UTC 写入，不根据“现在”的时区推算历史夏令时
- 室内跑步写为 Running/Treadmill；Strava 上传发送 `sport_type=Run`、`trainer=1`。收到上传 ID 后继续查询处理结果，不把 HTTP 201 当作完成
- 同一活动的本地指纹和 Strava `external_id` 用于幂等恢复。运行中停止后不启动新上传；已完成的远端效果仍记录。失败和重启不重新纠偏已保存的 FIT
- 近似去重/补源必须有相容的运动类型。旧健康记录缺少类型时不会据此关联另一项活动，避免错误覆盖；同源活动 ID/精确指纹仍用于去重
- 读取有响应、解压、样本、分页和总耗时上限，达到上限会报错，不能把截断结果当完整列表

## 失败处理

- 密码错误：检查 Keep 账号后重新手动登录；不会自动反复提交密码
- 令牌失效、验证码/风控、401/403：停止读取并重新登录，不绕过平台安全验证
- 接口格式变更：保留已有同步文件与历史，等待适配更新；不把解析失败显示为空记录
- Strava 权限、应用容量、429 限额：按提示检查已有授权或稍后恢复，避免自动重复创建活动
- 退出 Keep 只清除 Keep 账号/令牌，不删除已保存的 FIT 和同步历史

Keep 的[用户协议](https://m.gotokeep.com/fd-page/document/show?param=tos)可能限制第三方访问和数据使用；本功能不表示获得 Keep 的官方认可，也不能保证账号或接口持续可用。Keep [隐私政策](https://m.gotokeep.com/fd-page/document/show?param=privacy)提供个人信息下载渠道，但此版本不是“官方导出文件导入器”，未假定官方邮件导出具有某一固定格式。

## 协议和许可来源

- [running_page 的 Keep 实现](https://github.com/yihong0618/running_page/blob/6ffdd23ad8cd96118ba0cd93ccf07320676e01e3/run_page/keep_sync.py)，参考提交 `6ffdd23ad8cd96118ba0cd93ccf07320676e01e3`：登录/分页/详情字段、公开格式解码参数。MIT Copyright (c) 2025 yihong，许可保留于 [running-page-MIT.txt](third-party/running-page-MIT.txt)
- [Strava Uploads](https://developers.strava.com/docs/uploads/)：multipart FIT、运动类型、室内标志、异步处理与状态轮询
- [Strava Authentication](https://developers.strava.com/docs/authentication/)：OAuth scopes 和令牌更新

实现使用合成运动数据和本地 HTTP 测试，不包含账号、令牌或个人运动记录。真实 Keep 版本/账号与 Strava 的端到端兼容性需要用户在自己的设备上验收。
