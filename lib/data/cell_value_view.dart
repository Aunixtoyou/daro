/// 单元格值的多视图(文本 / 十六进制 / 图像 / 网页)纯逻辑。
///
/// 表数据页底部的「单元格编辑器」把当前选中单元格按几种视图呈现:
/// 文本文本框可直接改值;**十六进制**做转储,便于看清不可打印字符;
/// **图像**识别 base64 编码的图片字节(数据库里存二进制/图片的常见存法);
/// **网页**识别 HTML 源码片段。
///
/// 这里只做「字符串 → 视图数据」的判定与转换,不含任何 UI,便于单测。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../l10n/app_localizations.dart';

/// 单元格编辑器的页签
///
/// 页签文字随界面语言变化,而枚举拿不到 `BuildContext`,故由调用方把
/// [AppLocalizations] 传进 [labelOf](同 `ObjectCategory.labelOf` 的范式)。
enum CellViewMode {
  text,
  hex,
  image,
  web;

  /// 页签文字
  String labelOf(AppLocalizations l) => switch (this) {
        CellViewMode.text => l.gridCellEditorTabText,
        CellViewMode.hex => l.gridCellEditorTabHex,
        CellViewMode.image => l.gridCellEditorTabImage,
        CellViewMode.web => l.gridCellEditorTabWeb,
      };
}

/// 十六进制转储:每行 [bytesPerLine] 字节,形如
/// `00000000  77 78 31 65 …  |wx1e…|`(偏移 + 十六进制 + 可打印字符侧栏)。
///
/// 按 UTF-8 编码取值 —— 表格里的值本来就是文本,转储后能看出多字节字符
/// 与不可打印字符的真实分布。空串返回空串。
String hexDump(String value, {int bytesPerLine = 16}) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty) return '';
  final buffer = StringBuffer();
  for (var offset = 0; offset < bytes.length; offset += bytesPerLine) {
    final end = offset + bytesPerLine > bytes.length
        ? bytes.length
        : offset + bytesPerLine;
    final hex = <String>[];
    final ascii = StringBuffer();
    for (var i = offset; i < end; i++) {
      final byte = bytes[i];
      hex.add(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
      // 可打印 ASCII 原样输出,其余(含多字节字符的每个字节)用 `.` 占位
      ascii.write(byte >= 0x20 && byte <= 0x7e
          ? String.fromCharCode(byte)
          : '.');
    }
    buffer
      ..write(offset.toRadixString(16).padLeft(8, '0').toUpperCase())
      ..write('  ')
      // 末行不足一行时右侧补齐,侧栏才能对齐成一列
      ..write(hex.join(' ').padRight(bytesPerLine * 3 - 1))
      ..write('  |')
      ..write(ascii)
      ..write('|');
    if (end < bytes.length) buffer.write('\n');
  }
  return buffer.toString();
}

/// 内容看起来是 HTML(修剪左侧空白后以 `<` 开头,且含成对标签或 doctype)。
///
/// 单个 `<` 太常见(如 `a < b`),故要求出现 `</` 或 `<!doctype html` / `<html`,
/// 避免把普通文本误判成网页。
bool looksLikeHtml(String value) {
  final trimmed = value.trimLeft();
  if (!trimmed.startsWith('<')) return false;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
    return true;
  }
  return lower.contains('</') && lower.contains('>');
}

/// 剥掉 `data:image/png;base64,` 这类 data URI 前缀;无前缀时原样返回。
String stripDataUri(String value) {
  final comma = value.indexOf(',');
  if (comma < 0) return value;
  final head = value.substring(0, comma).toLowerCase();
  return head.startsWith('data:') && head.contains('base64')
      ? value.substring(comma + 1)
      : value;
}

/// 以 base64 解码且首部是已知图片魔数时返回字节,否则返回 null。
///
/// 用 `base64.normalize` 兼容缺省 padding 与 URL-safe 字符集;
/// 解出来的字节还要过 [imageFormatOf],所以普通字符串(如 `wx1ee46353…`)
/// 只会得到 null 而不会被误当成图片。
Uint8List? decodeBase64Image(String value) {
  final raw = stripDataUri(value).trim();
  if (raw.isEmpty) return null;
  final compact = raw.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 8) return null;
  Uint8List bytes;
  try {
    bytes = base64.decode(base64.normalize(compact));
  } catch (_) {
    return null;
  }
  return imageFormatOf(bytes) == null ? null : bytes;
}

/// 按魔数识别图片格式(`png` / `jpeg` / `gif` / `bmp` / `webp`);不认识返回 null
String? imageFormatOf(List<int> bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return 'jpeg';
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'gif';
  }
  if (bytes[0] == 0x42 && bytes[1] == 0x4d) return 'bmp';
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  return null;
}
