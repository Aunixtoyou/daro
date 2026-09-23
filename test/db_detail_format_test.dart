import 'package:daro/data/db_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

// 详情面板的取值折算:这些函数决定了「128.00 KB (131,072)」这类展示,
// 一旦改动会同时影响库/表两页,故单独钉住。

void main() {
  group('formatThousands', () {
    test('三位一分组,不足三位原样', () {
      expect(formatThousands(0), '0');
      expect(formatThousands(999), '999');
      expect(formatThousands(1000), '1,000');
      expect(formatThousands(131072), '131,072');
      expect(formatThousands(1234567890), '1,234,567,890');
    });

    test('负号留在最前,分组只看绝对值', () {
      expect(formatThousands(-1000), '-1,000');
    });
  });

  group('formatByteSize', () {
    test('不足 1 KiB 用 bytes 单位', () {
      expect(formatByteSize(0), '0 bytes (0)');
      expect(formatByteSize(1), '1 byte (1)');
      expect(formatByteSize(1023), '1023 bytes (1,023)');
    });

    test('1024 进制换算,人读值带两位小数并附原始字节数', () {
      expect(formatByteSize(1024), '1.00 KB (1,024)');
      expect(formatByteSize(131072), '128.00 KB (131,072)');
      expect(formatByteSize(16384), '16.00 KB (16,384)');
      expect(formatByteSize(1536), '1.50 KB (1,536)');
      expect(formatByteSize(2 * 1024 * 1024), '2.00 MB (2,097,152)');
      expect(formatByteSize(3 * 1024 * 1024 * 1024), '3.00 GB (3,221,225,472)');
    });

    test('取不到值时返回 null,由界面显示占位符而非 0', () {
      // 0 会被读成「零字节」,与「目录没给这个数」是两回事
      expect(formatByteSize(null), isNull);
    });
  });

  group('formatDetailTimestamp', () {
    test('定长 YYYY-MM-DD HH:MM:SS,月日时分秒补零', () {
      expect(
        formatDetailTimestamp(DateTime(2026, 3, 3, 14, 43, 56)),
        '2026-03-03 14:43:56',
      );
      expect(
        formatDetailTimestamp(DateTime(2026, 1, 9, 0, 0, 0)),
        '2026-01-09 00:00:00',
      );
    });

    test('目录未记录该时间(如 InnoDB 不维护 UPDATE_TIME)返回 null', () {
      expect(formatDetailTimestamp(null), isNull);
    });
  });
}
