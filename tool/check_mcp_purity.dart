// MCP 纯 Dart 校验器(简报 §6 W1 的落地)。
//
// 用法:`dart run tool/check_mcp_purity.dart`
// 已接进 `.github/workflows/ci.yml`,本地也可单独跑。
//
// 为什么不是简报里写的那条 `grep -r "package:flutter" lib/mcp`:
// grep 只看得到**直接** import。`lib/mcp` 里只要有人写
// `import '../data/db_types.dart';`(它 import 了 material + flutter_svg),
// grep 会安静放行,而 `dart compile exe`(Phase-2 的 stdio 宿主)当场编不过 ——
// 报错点离根因隔了两层。所以这里做**传递闭包**:从 lib/mcp 出发沿 import/export/part
// 走完整张图,碰到任何 Flutter 侧的节点就失败,并打印完整链路。
//
// 校验的是 `lib/mcp/` 整棵树(不是 lib/data —— `mcp_policy_store.dart` 合法依赖
// path_provider 这个 Flutter 插件,它天生在应用侧)。
import 'dart:io';

/// 禁止出现的包前缀。
const _bannedPackages = ['package:flutter', 'dart:ui'];

/// 入口目录。
const _root = 'lib/mcp';

/// package:daro/... → 仓库内路径前缀。
const _selfPackage = 'package:daro/';

void main(List<String> args) {
  final dir = Directory(_root);
  if (!dir.existsSync()) {
    stderr.writeln('找不到 $_root/ 目录,校验无意义。');
    exit(1);
  }
  final entries = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (entries.isEmpty) {
    stderr.writeln('$_root/ 下没有 .dart 文件。');
    exit(1);
  }

  final violations = <List<String>>[];
  for (final start in entries) {
    final path = _norm(start.path);
    final chain = <String>[path];
    _walk(path, chain, violations, {path});
  }

  if (violations.isEmpty) {
    stdout.writeln('✓ ${entries.length} 个入口,lib/mcp 传递闭包内无 Flutter 依赖。');
    return;
  }
  stderr.writeln('✗ lib/mcp 的 import 闭包触碰到了 Flutter 侧:');
  for (final v in violations) {
    stderr.writeln('  ${v.join(' → ')}');
  }
  stderr.writeln('');
  stderr.writeln('修复方式:把需要的逻辑留在 lib/mcp(纯 Dart),');
  stderr.writeln('Flutter 侧依赖(如 db_types.dart 的图标、sql_completions.dart 的浮层)改由宿主注入。');
  exit(1);
}

/// 沿 import/export/part 走传递闭包;发现违规就把**完整链路**记进 [violations]。
void _walk(
  String file,
  List<String> chain,
  List<List<String>> violations,
  Set<String> seen,
) {
  for (final target in _importsOf(file)) {
    // 第三方/SDK 包:只判禁用的包名。
    if (target.startsWith('package:') || target.startsWith('dart:')) {
      if (_bannedPackages.any((b) => target.startsWith(b))) {
        violations.add([...chain, '$file  →  $target']);
      }
      continue;
    }
    final resolved = _resolve(file, target);
    if (resolved == null) {
      violations.add([...chain, '$file  →  $target(无法解析,可能指向 Flutter 包)']);
      continue;
    }
    if (!seen.add(resolved)) continue; // 已访问,防环
    _walk(resolved, [...chain, resolved], violations, seen);
  }
}

/// 一个文件里的 import / export / part URI 列表(跳过注释行)。
List<String> _importsOf(String file) {
  final lines = File(file).readAsLinesSync();
  final out = <String>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//')) continue;
    if (!line.startsWith('import ') &&
        !line.startsWith('export ') &&
        !line.startsWith('part ')) {
      continue;
    }
    final m = RegExp("""(?:import|export|part)\\s+['"]([^'"]+)['"]""").firstMatch(line);
    final uri = m?.group(1);
    // `import 'x' if (dart.library.io) 'y'` 这类条件导入:两个都查。
    out.add(uri ?? '');
    for (final alt in RegExp("""\\)\\s*['"]([^'"]+)['"]""").allMatches(line)) {
      out.add(alt.group(1) ?? '');
    }
  }
  return out.where((e) => e.isNotEmpty).toList();
}

/// 相对 URI → 仓库内文件路径;`package:daro/` → lib/。找不到返回 null。
String? _resolve(String from, String target) {
  String path;
  if (target.startsWith(_selfPackage)) {
    path = _norm('lib/${target.substring(_selfPackage.length)}');
  } else if (target.startsWith('package:') || target.startsWith('dart:')) {
    return null; // 外部包,交由调用方按包名判定
  } else {
    final base = File(from).parent.path;
    path = _norm('$base/$target');
  }
  return File(path).existsSync() ? path : null;
}

/// 统一路径分隔符并折叠 `.` / `..` 段(Windows 下 `lib/mcp/../data/x.dart`
/// 不折叠就 existsSync 失败,会误报「无法解析」)。
String _norm(String p) {
  final segs = <String>[];
  for (final seg in p.replaceAll(r'\', '/').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (segs.isNotEmpty && segs.last != '..') {
        segs.removeLast();
      } else {
        segs.add('..');
      }
      continue;
    }
    segs.add(seg);
  }
  return segs.join('/');
}
