/// 「运行 SQL 文件 / 还原转储」执行引擎:流式读取脚本文件,逐条执行语句。
///
/// 与导出引擎对称:文件读取与语句切分在此完成,写库由调用方注入
/// [SqlExecutor](复用导入引擎的同一回调签名),故本文件不依赖
/// AppState / ConnectionManager,可脱离 UI 单测。
///
/// 内存占用与文件大小无关:字节流 → UTF-8 解码 → [SqlStatementSplitter]
/// 增量切分 → 立即执行,任一时刻只保留「当前语句 + 当前数据块」。
library;

import 'dart:convert';
import 'dart:io';

import 'db_import.dart' show SqlExecutor;
import 'sql_split.dart';

/// 执行过程中的进度快照([onProgress] 回调携带)
class SqlRunProgress {
  const SqlRunProgress({
    required this.succeeded,
    required this.failed,
    required this.bytesDone,
    required this.totalBytes,
    required this.current,
  });

  /// 已成功执行的语句数
  final int succeeded;

  /// 已失败的语句数
  final int failed;

  /// 已从文件读取的字节数(进度条口径,与 File.length 一致)
  final int bytesDone;

  /// 文件总字节数
  final int totalBytes;

  /// 正在执行的语句预览(截断)
  final String current;

  /// 已执行的语句总数
  int get executed => succeeded + failed;
}

/// 一次「运行 SQL 文件」的结果
class SqlRunResult {
  const SqlRunResult({
    this.succeeded = 0,
    this.failed = 0,
    this.errors = const [],
    this.cancelled = false,
    this.stoppedOnError = false,
    this.fatalError,
  });

  final int succeeded;
  final int failed;

  /// 失败语句的错误摘要(至多 [runSqlFile] 的 maxErrors 条)
  final List<String> errors;

  /// 是否被用户中途停止
  final bool cancelled;

  /// 是否因「遇错即停」提前中断
  final bool stoppedOnError;

  /// 整体性失败(文件打不开、编码不合法),与单条语句失败区分
  final String? fatalError;

  /// 已执行的语句总数
  int get executed => succeeded + failed;

  /// 是否全部语句成功且无整体性错误
  bool get ok => fatalError == null && failed == 0 && !cancelled;
}

/// 流式执行 [filePath] 中的 SQL,逐条交给 [execute]。
///
/// [stopOnError] 为真时第一条失败语句即中断(默认继续跑完,转储里
/// 「表已存在」这类可容忍错误不少);[onProgress] 每 [progressEvery] 条
/// 语句回调一次(大转储下避免刷爆 UI);[isCancelled] 每条语句前检查,
/// 停止时已执行的语句不会回滚(转储本身就带自己的事务边界)。
Future<SqlRunResult> runSqlFile({
  required String filePath,
  required SqlExecutor execute,
  void Function(SqlRunProgress progress)? onProgress,
  bool Function()? isCancelled,
  bool stopOnError = false,
  int maxErrors = 50,
  int progressEvery = 20,
}) async {
  var succeeded = 0;
  var failed = 0;
  var bytesDone = 0;
  var cancelled = false;
  var stoppedOnError = false;
  final errors = <String>[];

  int totalBytes;
  try {
    totalBytes = await File(filePath).length();
  } catch (e) {
    return SqlRunResult(fatalError: '无法读取文件:$e');
  }

  final splitter = SqlStatementSplitter();
  final every = progressEvery <= 0 ? 1 : progressEvery;
  var firstTextChunk = true;

  /// 执行一条语句:返回 false 表示应当中断本次循环(取消或遇错即停)
  Future<bool> runStatement(String sql) async {
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      return false;
    }
    // 按语句序号节流:大转储十万条语句若逐条回调会把 UI 的 setState 打爆,
    // 首条(序号 0)必定回调保证一点「开始执行」就有反馈
    final index = succeeded + failed;
    if (index % every == 0) {
      onProgress?.call(SqlRunProgress(
        succeeded: succeeded,
        failed: failed,
        bytesDone: bytesDone,
        totalBytes: totalBytes,
        current: _preview(sql),
      ));
    }
    try {
      await execute(sql);
      succeeded++;
    } catch (e) {
      failed++;
      if (errors.length < maxErrors) {
        errors.add('第 ${index + 1} 条语句失败:${_preview(sql)}\n$e');
      }
      if (stopOnError) {
        stoppedOnError = true;
        return false;
      }
    }
    return true;
  }

  try {
    final bytes = File(filePath).openRead().map((chunk) {
      bytesDone += chunk.length;
      return chunk;
    });
    // allowMalformed=false:非 UTF-8(常见为 GBK / ANSI)立即报错,
    // 不能带着替换字符继续,否则转储里的中文数据会被静默写坏
    await for (final text in bytes.transform(
        const Utf8Decoder(allowMalformed: false))) {
      var script = text;
      if (firstTextChunk) {
        firstTextChunk = false;
        if (script.startsWith('\uFEFF')) script = script.substring(1);
      }
      var keepGoing = true;
      for (final stmt in splitter.feed(script)) {
        keepGoing = await runStatement(stmt);
        if (!keepGoing) break;
      }
      if (!keepGoing) break;
    }
    if (!cancelled && !stoppedOnError) {
      for (final stmt in splitter.finish()) {
        if (!await runStatement(stmt)) break;
      }
    }
  } on FormatException catch (e) {
    return SqlRunResult(
      succeeded: succeeded,
      failed: failed,
      errors: errors,
      fatalError: '文件不是合法的 UTF-8 文本(GBK / ANSI 编码的转储请先另存为 '
          'UTF-8):${e.message}',
    );
  } catch (e) {
    return SqlRunResult(
      succeeded: succeeded,
      failed: failed,
      errors: errors,
      fatalError: '执行中断:$e',
    );
  }

  return SqlRunResult(
    succeeded: succeeded,
    failed: failed,
    errors: errors,
    cancelled: cancelled,
    stoppedOnError: stoppedOnError,
  );
}

/// 语句预览:压成单行并截断,供进度提示与错误列表定位语句
String _preview(String sql) {
  final oneLine = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.length <= 160) return oneLine;
  return '${oneLine.substring(0, 157)}...';
}
