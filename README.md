<div align="center">

<img src="assets/icons/app_logo.svg" alt="daro" width="96" />

# daro

Flutter 构建的轻量级桌面数据库管理工具

本项目创建之初致敬了navicat界面和操作习惯，后续将按照社区反馈进行迭代完善；本项目为完全免费使用，仅作为学习和分享Flutter技术探索，不提供任何技术支持和售后行为。

</div>

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

## 🔗 相关链接

- 组件库：[base-ui-flutter](https://github.com/SpringHgui/base-ui-flutter)