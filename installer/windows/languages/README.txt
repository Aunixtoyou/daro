简体中文语言文件说明
====================

Inno Setup 默认只附带英文 Default.isl。若需中文安装界面，
请下载非官方 ChineseSimplified.isl 并放到本目录（installer/windows/languages/）。

获取方式：
1) Inno Setup 官方翻译页：https://jrsoftware.org/files/istrans/
   在 "Chinese (Simplified)" 行下载 .isl 文件。
2) 或安装 Inno Setup 的简体中文语言包后从安装目录复制：
   C:\Program Files (x86)\Inno Setup 6\Languages\ChineseSimplified.isl

installer.iss 编译逻辑：
  - 优先读取本目录下的 ChineseSimplified.isl
  - 其次尝试 Inno Setup 安装目录内的 compiler:Languages\ChineseSimplified.isl
  - 都不存在时静默回退为仅英文界面（不报错）
