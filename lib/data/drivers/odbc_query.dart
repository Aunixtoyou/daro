import 'package:dart_odbc/dart_odbc.dart';

/// `dart_odbc` 系驱动(SQL Server / Access)共享的**封顶流式**取数结果。
class OdbcCappedResult {
  const OdbcCappedResult({
    required this.columns,
    required this.rows,
    required this.moreRows,
  });

  /// 列名(按首行的键序);空列表表示语句无结果集
  final List<String> columns;

  /// 字符串化行数据(每行与 [columns] 等宽,真 NULL 显示为 "NULL")
  final List<List<String>> rows;

  /// 结果集是否还有未取回的行(由多取的那 1 行精确判定,非按触顶推断)
  final bool moreRows;
}

/// 执行 [sql],最多取回 [limit] 行,超出部分不下发也不读取。
///
/// 为什么不能用 `DartOdbc.execute`:它内部是 `_getResultBulk` —— 把**整棵结果集**
/// 在 ODBC isolate 里逐行逐列 `SQLGetData` 抽干、堆成 `List<Map<String, dynamic>>`,
/// 再整体跨 isolate 拷回主 isolate。`SELECT * FROM 大表` 因此会把全表在内存里
/// 存两遍(实测把进程顶到 5 GB+),要么几十秒不返回(必须等全表读完才出结果),
/// 要么最终由驱动报 HY001「Memory allocation failure」。在调用方再 `break`
/// 也救不回来——数据那时已经全部进了内存。
///
/// 本函数改用 `executeCursor`(dart_odbc 6.1.0+ 的流式接口):取满 `limit + 1`
/// 行即停,`finally` 关闭游标 → 释放语句句柄 → 服务端随之中止剩余结果。
/// 第 `limit + 1` 行只用于精确判定「还有更多行」,不纳入返回结果。
/// [offset] > 0 时先丢弃前 offset 行再取(「加载更多」续取):ODBC 游标只能从头
/// 逐行读,故在客户端跳过,不改写用户 SQL(避开 SQL Server OFFSET/FETCH 强制
/// ORDER BY 的方言问题)。代价是服务端仍会重跑并扫到 offset 行。
Future<OdbcCappedResult> odbcQueryCapped(
  IDartOdbc odbc,
  String sql, {
  required int limit,
  int offset = 0,
}) async {
  final rows = <List<String>>[];
  List<String>? columns;
  var moreRows = false;
  var skipped = 0;
  // 游标在 try 内创建:executeCursor 自身失败时底层已自行释放语句句柄,
  // 外层再 close 会二次释放,故用可空变量 + `?.` 只关闭成功创建的那个
  OdbcCursor? cursor;
  try {
    cursor = await odbc.executeCursor(sql);
    // 取满 limit 行后再多读一行即判定「还有更多」并停;游标从头读,先跳过 offset 行
    while (true) {
      final item = await cursor.next();
      if (item is CursorDone) break;
      final row = (item as CursorItem).value;
      if (skipped < offset) {
        skipped++;
        continue;
      }
      if (rows.length >= limit) {
        moreRows = true;
        break;
      }
      // 列名与顺序以首行为准(ODBC 结果集各行的键序一致)
      columns ??= row.keys.toList();
      rows.add([
        for (final col in columns) row[col]?.toString() ?? 'NULL',
      ]);
    }
  } finally {
    await cursor?.close();
  }
  return OdbcCappedResult(
    columns: columns ?? const [],
    rows: rows,
    moreRows: moreRows,
  );
}
