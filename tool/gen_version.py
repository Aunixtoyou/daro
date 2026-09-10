"""从 pubspec.yaml 生成版本号常量,消除"多处各写一份版本"的分叉。

单一数据源:pubspec.yaml 的 version: <semver>[+<build>]
生成两个消费端:
  - lib/app/version.g.dart          -> Dart 侧("关于"对话框等)
  - installer/windows/version.inc   -> Inno Setup(ISPP)侧,GUI 直接编译 .iss 也能拿到

用法:
  python tool/gen_version.py            重新生成两份文件
  python tool/gen_version.py --print    只打印版本号(给 build_installer.bat 用)
  python tool/gen_version.py --check    校验已生成文件与 pubspec 一致,不一致退出码 1
"""
import os
import re
import sys

# stdout/stderr 被重定向(CI 的 `>nul`、管道、日志文件)时,Python 会退回系统 ANSI
# 代码页编码 —— 英文版 Windows(含 GitHub windows-latest)是 cp1252,打印中文会
# 抛 UnicodeEncodeError 并以退出码 1 结束,build_installer.bat 就会报成
# "gen_version.py failed - check the version: line in pubspec.yaml"(误导)。
# 放宽编码错误,保证"中文日志"永远不能拖垮生成逻辑本身。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(errors="backslashreplace")
    except (AttributeError, OSError, ValueError):
        pass

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBSPEC = os.path.join(REPO, "pubspec.yaml")
DART_OUT = os.path.join(REPO, "lib", "app", "version.g.dart")
ISS_OUT = os.path.join(REPO, "installer", "windows", "version.inc")

DART_TMPL = """// 本文件由 tool/gen_version.py 从 pubspec.yaml 自动生成,请勿手工修改。
// 改版本只改 pubspec.yaml 的 version:,然后运行:
//   python tool/gen_version.py
// 一致性由 test/app_version_test.dart 守护(漂移会让 CI 失败)。

/// 语义版本号(不含 build 号),例如 `0.1.0`。
const String kAppVersion = '{version}';

/// pubspec.yaml 里 `+` 后面的构建号,例如 `1`。
const String kAppBuild = '{build}';

/// 完整版本串,例如 `0.1.0+1`。
const String kAppVersionFull = '{full}';
"""

ISS_TMPL = "; 本文件由 tool/gen_version.py 从 pubspec.yaml 自动生成,请勿手工修改。\n" \
           "; 改版本只改 pubspec.yaml 的 version:,然后运行: python tool/gen_version.py\n" \
           '#define PubAppVersion "{version}"\n' \
           '#define PubAppVersionFull "{full}"\n'


def read_version():
    text = open(PUBSPEC, encoding="utf-8").read()
    m = re.search(r"^version:\s*([0-9][^\s]*)\s*$", text, re.MULTILINE)
    if not m:
        sys.exit("ERROR: pubspec.yaml 里找不到形如 `version: 1.2.3+4` 的行")
    full = m.group(1)
    base, _, build = full.partition("+")
    if not re.match(r"^\d+\.\d+\.\d+$", base):
        sys.exit(f"ERROR: 版本号 {base} 不是 x.y.z 形式")
    return base, (build or "0"), full


def render(path, tmpl, **kw):
    body = tmpl.format(**kw)
    if "--check" in sys.argv:
        cur = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if cur != body:
            sys.exit(f"ERROR: {os.path.relpath(path, REPO)} 与 pubspec.yaml 不一致,"
                     f"请运行 python tool/gen_version.py 后提交")
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        print("已写出", os.path.relpath(path, REPO))


def main():
    version, build, full = read_version()
    if "--print" in sys.argv:
        print(version)
        return
    render(DART_OUT, DART_TMPL, version=version, build=build, full=full)
    render(ISS_OUT, ISS_TMPL, version=version, full=full)
    if "--check" in sys.argv:
        print("版本一致性检查通过:", full)


if __name__ == "__main__":
    main()
