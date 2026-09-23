import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/cell_value_view.dart';

/// 一个最小的合法 PNG 头(base64 往返用,不需要真能解码出像素)
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG 魔数
  0x00, 0x00, 0x00, 0x0d,
]);

void main() {
  group('hexDump 十六进制转储', () {
    test('ASCII 内容:偏移 + 每字节两位十六进制 + 右侧可打印字符', () {
      expect(
        hexDump('AB'),
        '00000000  ${'41 42'.padRight(47)}  |AB|',
      );
    });

    test('空串返回空串(界面据此显示"当前单元格为空")', () {
      expect(hexDump(''), '');
    });

    test('不可打印字符用 . 占位', () {
      final dump = hexDump('A\nB');
      expect(dump, contains('41 0A 42'));
      expect(dump, contains('|A.B|'));
    });

    test('每行 16 字节,超出换行且偏移递增', () {
      final dump = hexDump(List.filled(17, 'A').join());
      final lines = dump.split('\n');
      expect(lines.length, 2);
      expect(lines[0], startsWith('00000000  '));
      expect(lines[1], startsWith('00000010  '));
      // 末行不足 16 字节:右侧补齐后侧栏仍对齐在固定列
      expect(lines[1].endsWith('|A|'), isTrue);
    });

    test('按 UTF-8 编码:中文占三字节', () {
      final dump = hexDump('中');
      expect(dump, contains('E4 B8 AD'));
      expect(dump, contains('|...|'));
    });

    test('可自定义每行字节数', () {
      final dump = hexDump('ABCD', bytesPerLine: 2);
      expect(dump.split('\n').length, 2);
      expect(dump.split('\n')[0], contains('|AB|'));
    });
  });

  group('looksLikeHtml 网页识别', () {
    test('doctype / html 标签直接判为网页', () {
      expect(looksLikeHtml('<!DOCTYPE html><html></html>'), isTrue);
      expect(looksLikeHtml('  <html>\n<body>x</body>'), isTrue);
    });

    test('含成对标签的片段判为网页', () {
      expect(looksLikeHtml('<div>hello</div>'), isTrue);
      expect(looksLikeHtml('<p><b>x</b></p>'), isTrue);
    });

    test('普通文本不误判', () {
      expect(looksLikeHtml('a < b'), isFalse);
      expect(looksLikeHtml('wx1ee46353ec01af8a'), isFalse);
      expect(looksLikeHtml('{"a": 1}'), isFalse);
      // 只有一个开标签、没有闭合:不作为网页(单个 < 太常见)
      expect(looksLikeHtml('<b>'), isFalse);
    });
  });

  group('imageFormatOf / decodeBase64Image 图像识别', () {
    test('识别常见图片魔数', () {
      expect(
        imageFormatOf(_pngBytes),
        'png',
      );
      expect(
        imageFormatOf([0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        'jpeg',
      );
      expect(
        imageFormatOf([0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0, 0, 0, 0, 0]),
        'gif',
      );
      expect(
        imageFormatOf([0x42, 0x4d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        'bmp',
      );
      expect(
        imageFormatOf([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        'webp',
      );
    });

    test('非图片字节 / 过短字节返回 null', () {
      expect(imageFormatOf(utf8.encode('hello world!')), isNull);
      expect(imageFormatOf([0x89, 0x50]), isNull);
    });

    test('base64 图片可解码,并剥掉 data URI 前缀', () {
      final encoded = base64.encode(_pngBytes);
      expect(decodeBase64Image(encoded), _pngBytes);
      expect(decodeBase64Image('data:image/png;base64,$encoded'), _pngBytes);
      // 带换行的 base64(PEM 风格)也能解
      expect(decodeBase64Image('$encoded\n'), _pngBytes);
    });

    test('普通字符串不会被误判成图片', () {
      // 真实截图里的值:合法 base64 字符集,但解出来不是图片
      expect(decodeBase64Image('wx1ee46353ec01af8a'), isNull);
      expect(decodeBase64Image('hello world!'), isNull);
      expect(decodeBase64Image(''), isNull);
      expect(decodeBase64Image('   '), isNull);
      expect(decodeBase64Image('!!!'), isNull);
    });

    test('stripDataUri 只剥 base64 data URI 前缀', () {
      expect(stripDataUri('data:image/png;base64,AAAA'), 'AAAA');
      expect(stripDataUri('data:IMAGE/PNG;BASE64,AAAA'), 'AAAA');
      expect(stripDataUri('AAAA'), 'AAAA');
      expect(stripDataUri('data:text/plain,AAAA'), 'data:text/plain,AAAA');
    });
  });

  group('CellViewMode 页签', () {
    test('四个页签的顺序与英文标识固定,文字随语言取自 l10n', () {
      expect(CellViewMode.values.map((m) => m.name).toList(),
          ['text', 'hex', 'image', 'web']);
    });
  });
}
