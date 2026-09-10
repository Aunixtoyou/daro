<div align="center">

<img src="assets/icons/app_logo.svg" alt="daro" width="96" />

# daro

Flutter 构建的轻量级桌面数据库管理工具

本项目创建之初致敬了navicat界面和操作习惯，后续将按照社区反馈进行迭代完善；本项目为完全免费使用，仅作为学习和分享Flutter技术探索，不提供任何技术支持和售后行为。

</div>
<img width="2544" height="1430" alt="image" src="https://github.com/user-attachments/assets/c1e907c6-112b-490b-a1f2-7b1ab08a1a78" />
<img width="2544" height="1430" alt="image" src="https://github.com/user-attachments/assets/8c2b87ad-f382-472a-95ae-d984def3e6c1" />
<img width="2544" height="1430" alt="image" src="https://github.com/user-attachments/assets/c64b96c7-d5ab-4d81-801b-bbc4b756d421" />
<img width="2544" height="1430" alt="image" src="https://github.com/user-attachments/assets/5b47023c-4a1c-45c9-8f45-1ad40360d43e" />

---

## 🗄️ 支持的数据库

| 引擎 | 状态 | 驱动方式 |
|---|---|---|
| MySQL | ✅ 已支持 | `mysql_client` |
| MariaDB | ✅ 已支持 | `mysql_client` |
| PostgreSQL | ✅ 已支持 | `postgres` |
| SQL Server | ✅ 已支持 | 原生协议驱动 |
| SQLite | ✅ 已支持 | `sqlite3`（FFI，文件型） |
| Access | ✅ 已支持 | `dart_odbc`（ODBC，文件型） |
| Oracle | ⏳ 规划中 | — |
| MongoDB | ⏳ 规划中 | — |
| Redis | ⏳ 规划中 | — |
| Snowflake | ⏳ 规划中 | — |

> 各引擎能力（是否支持模式层、函数 / 过程、角色管理、实体化视图等）由
> `lib/data/drivers/db_driver.dart` 中的能力集合常量声明，界面据此动态显隐。

---
 
## 🚀 快速开始

### 环境要求

- Flutter SDK（stable 渠道，Dart ≥ 3.0）
- 桌面构建工具链（Windows：Visual Studio 2022 + 「使用 C++ 的桌面开发」工作负载）
- 访问 Access 需系统安装对应 ODBC 驱动

### 拉取代码（含子模块）

本项目的 `base-ui-flutter` 以 git submodule 引入，克隆时需一并拉取：

```bash
# 方式一：克隆时递归拉取子模块
git clone --recursive https://github.com/SpringHgui/daro.git

# 方式二：已克隆后补拉子模块
git submodule update --init --recursive
```

### 运行

```bash
flutter pub get
flutter run -d windows
```

> SQLite 依赖 `sqlite3_flutter_libs`，已锁定 `0.5.42`
> （`0.6.0+` 为 EOL 占位包、不再捆绑 `sqlite3.dll`，请勿升级）。

---

## 📦 发布与安装包（GitHub Actions 自动打包）

本机（Windows）只能打 Windows 包，macOS / Linux 需在各自平台构建——因此打包交给
GitHub Actions，一次触发并行产出三平台安装包：

| 平台 | Runner | 产物 |
|---|---|---|
| Windows | `windows-latest` | `daro-Setup-<ver>-x64.exe`（Inno Setup，复用 `installer/windows`） |
| macOS | `macos-14` | `daro-<ver>-macos-universal.dmg` / `.zip`（x86_64 + arm64 通用） |
| Linux | `ubuntu-22.04` | `daro-<ver>-linux-amd64.deb` 与 `daro-<ver>-linux-x64.tar.xz` |

工作流：`.github/workflows/release.yml`。版本号唯一来源仍是 `pubspec.yaml` 的
`version:`，打包脚本（`installer/linux/package_linux.sh`、`installer/macos/make_dmg.sh`
及既有 `installer/windows/build_installer.bat`）都从中取值。

**发布流程**：

```bash
# 1) 确认版本号已在 pubspec.yaml 里更新，并同步生成的常量文件
python tool/gen_version.py
# 2) 打 tag 推送 → Actions 自动构建三平台产物并发布 Draft Release
git tag v0.2.0
git push origin v0.2.0
```

- 打 `v*` tag：构建三平台 → 汇总成一个 **Draft Release**（预填变更说明，人工确认后手动
  Publish，避免误发）。
- 只想试跑：在 Actions 页面手动 `Run workflow`（`workflow_dispatch`），产物以 artifacts
  形式保留，不建 Release。

**已知限制 / 需自行处理**：

- macOS 包仅做 ad-hoc 签名、未做开发者证书签名与公证，用户首次打开需右键“打开”绕过
  Gatekeeper。要正式分发需在 Secrets 里配置签名证书并加公证步骤。
- Linux arm64、Windows arm64 未纳入默认矩阵（x64 runner 无法可靠交叉编译）；如需要，
  用对应架构的原生 runner 追加 job 即可。
- 目标机使用 SQL Server / Access（ODBC）与 MySQL 仍需自行安装对应系统驱动，与打包无关。

---

## 🔗 相关链接

- 组件库：[base-ui-flutter](https://github.com/SpringHgui/base-ui-flutter)
