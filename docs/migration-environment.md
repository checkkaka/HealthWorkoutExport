# Flutter + Rust 迁移环境台账

更新日期：2026-08-11。以下内容只记录项目目录外的安装、缓存和全局配置；卸载前需确认其他项目未共用。

## 本次任务新增或写入

| 项目 | 当前位置 / 大小 | 何时可卸载 | 卸载影响 |
|---|---|---|---|
| Flutter 3.44.9 / Dart 3.12.2（FVM 缓存） | `~/fvm/versions/stable`，约 3.1 GB | 本仓库及其他 FVM 项目都不再使用 `stable` 后 | `fvm flutter` 会失去当前 SDK，下次使用需重新下载 |
| Android SDK | `~/Library/Android/sdk`，约 3.5 GB | 不再构建、调试 Android，且其他 Android 项目不共用后 | APK 构建、ADB、NDK 交叉编译全部不可用 |
| Android SDK 包 | Platform 33/36、Build Tools 36、Platform Tools 37.0.1、NDK 28.2、CMake 3.22.1、Command-line Tools 22 | 对应 Android 构建完成后，可逐包卸载 | 删除任一构建期包都可能让 Gradle 再次下载或直接失败 |
| Gradle wrapper/依赖缓存 | `~/.gradle`，约 3.8 GB | 所有 Gradle 构建停止后可清缓存 | 不删除源码，但所有 Java/Android 项目下次会重新下载依赖 |
| `flutter_rust_bridge_codegen` 2.12.0 | `~/.cargo/bin/flutter_rust_bridge_codegen` | 不再生成或更新 Dart↔Rust 绑定后 | 已生成代码仍可编译，但不能再生绑定 |
| `cargo-expand` 1.0.124 | `~/.cargo/bin/cargo-expand` | 不再调试 FRB 宏展开后，当前即可卸载 | 不影响普通 Cargo 构建，只失去宏展开命令 |
| Cargo crate 缓存 | `~/.cargo/registry`，约 391 MB | 所有 Cargo 构建停止后可清缓存 | 不影响源码和已生成二进制；下次构建会重新下载 FRB、SHA-256、时间处理等依赖 |
| Rust 跨平台 targets | `~/.rustup/toolchains/stable-aarch64-apple-darwin` | 不再构建对应平台 Rust 产物后 | 删除哪个 target，哪个平台就不能交叉编译；`i686-linux-android` 可确认由 Android 构建自动补装 |
| Flutter 全局 JDK 选择 | `jdk-dir=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home` | 不再构建 Android，或要统一切换到另一 JDK 时 | 影响本机所有 Flutter 项目的 Android Gradle JDK；当前设置本身不占额外磁盘 |
| FRB 探测目录 | `/tmp/frb-healthworkoutexport.XlttlS`（约 836 MB）、`/tmp/frb-manual-healthworkoutexport.TMCSiR`（约 1.0 GB） | 当前即可删除 | 仅丢失一次性探测副本，不影响仓库和已生成桥接代码 |

## 建议卸载命令

优先使用对应管理工具，不直接删除共享目录：

```bash
# 不再使用当前 Flutter SDK 后
fvm remove stable

# 不再生成 FRB 绑定或查看宏展开后
cargo uninstall flutter_rust_bridge_codegen
cargo uninstall cargo-expand

# 示例：只删除可确认由本次 Android 构建补装的 x86 target
rustup target remove i686-linux-android

# Android 开发全部结束后，按包卸载
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  /opt/homebrew/bin/sdkmanager --sdk_root="$HOME/Library/Android/sdk" --uninstall \
  "platforms;android-33" "platforms;android-36" "build-tools;36.0.0" \
  "platform-tools" "ndk;28.2.13676358" "cmake;3.22.1" "cmdline-tools;latest"

# 不再需要管理 Android SDK 后
brew uninstall --cask android-commandlinetools
```

`~/.gradle`、`~/Library/Android/sdk`、`~/fvm` 和 `/tmp` 探测目录如需整目录删除，应在所有相关进程停止后人工确认精确路径；它们可能被其他项目共用，因此不在自动清理流程中删除。

## 本次未新装或归属无法确认

- 已确认迁移前存在：Xcode 26.6、Command Line Tools、rustup/stable Rust 1.97.1、OpenJDK 17、fnm/Node。
- 无法仅凭当前状态确认是本次新装、升级还是重链接：FVM 4.1.2、CocoaPods 1.17.0、Homebrew Ruby。
- Android Studio 2026.1 在 Android SDK 创建前已存在，本次不按新增软件处理。
- 未代用户执行 `flutter doctor --android-licenses`；仍有部分 Android 法律条款未接受。

不要因本仓库结束就直接卸载 Xcode、Rustup、OpenJDK、Node、CocoaPods、Ruby 或 Android Studio；这些是全局工具，会影响其他项目。
