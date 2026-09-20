import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

import 'db_data.dart';
import 'drivers/db_driver.dart';

/// Navicat 导出的连接配置(`.ncx`)导入:XML 解析 + 保存的密码解密 + 映射为
/// daro 的 [ConnectionInfo]。
///
/// ── 密码加密方式(实测本机 Navicat Premium 16/17 导出文件所得) ──
/// `<Connection>` 的 `Password` 属性是**大写十六进制**密文,算法为
/// AES-128-CBC + PKCS#7,密钥与 IV 是 Navicat 内置固定常量(libcc 公共库,
/// 与其源文件名同名):
///
/// * key = `libcckeylibcckey` (16 字节 ASCII)
/// * iv  = `libcciv libcciv ` (16 字节 ASCII,末尾一个空格)
///
/// 因为是固定 IV 的确定性加密,同一个密码在任何连接/任何导出文件里密文完全
/// 相同(空密码恒为 `E191AF42327478CC5F143EF279EC4D81`),这既是识别该方案的
/// 依据,也是 [test/navicat_import_test.dart] 里往返对拍的基准。
///
/// ── 尚未支持的路径 ──
/// 旧版 Navicat(Navicat 11~16 的部分导出)用 Blowfish 加密,密文同样是十六进制。
/// 本机手上没有这类真实样本可供闭环验证,故不凭记忆实现猜测性分支:这类值会走
/// [NavicatPasswordState.undecryptable],导入后由用户手填密码并在界面明示。
/// 拿到真实旧版样本后,可用 pointycastle 的 `BlowfishEngine` 补一条解密分支。

/// Navicat 内置密码加密密钥(libcc 常量,非用户口令)
const String kNavicatLibccKey = 'libcckeylibcckey';

/// Navicat 内置密码加密 IV(libcc 常量,末尾含一个空格)
const String kNavicatLibccIv = 'libcciv libcciv ';

/// [kNavicatLibccKey] 的字节形式(AES-128 需要 16 字节密钥)
final Uint8List _libccKeyBytes = Uint8List.fromList(utf8.encode(kNavicatLibccKey));

/// [kNavicatLibccIv] 的字节形式(AES 块大小 16 字节)
final Uint8List _libccIvBytes = Uint8List.fromList(utf8.encode(kNavicatLibccIv));

/// Navicat 连接类型 → daro `DbType.id`。
///
/// 值域与 [kSupportedDriverTypes] 对齐:不在此表内的 ConnType 原样小写返回,
/// 由 [NavicatConnection.isSupported] 判定是否可导入。
const Map<String, String> kNavicatConnTypes = {
  'MYSQL': 'mysql',
  'MARIADB': 'mariadb',
  'POSTGRESQL': 'postgresql',
  'SQLSERVER': 'sqlserver',
  'SQLITE': 'sqlite',
  'ACCESS': 'access',
  'ORACLE': 'oracle',
  'MONGODB': 'mongodb',
  'REDIS': 'redis',
  'SNOWFLAKE': 'snowflake',
};

/// 一条 Navicat 连接里密码的可得性。
enum NavicatPasswordState {
  /// 该连接本就不需要密码(如 SQLite 未加密、SQL Server Windows 身份验证)
  noPassword,

  /// 密码已解密
  decrypted,

  /// Navicat 端未勾选「保存密码」,导出文件里没有密文
  notSaved,

  /// 有密文但解不出来(旧版加密方式等),导入后需手填
  undecryptable,
}

/// 解析自 `.ncx` 的一条连接。
class NavicatConnection {
  const NavicatConnection({
    required this.attributes,
    required this.passwordState,
    this.password = '',
  });

  /// `<Connection>` 元素上的全部属性(Navicat 把配置平铺在属性里,无子节点)
  final Map<String, String> attributes;

  /// 密码解密结果状态
  final NavicatPasswordState passwordState;

  /// 明文密码,仅当 [passwordState] == [NavicatPasswordState.decrypted] 时有意义
  final String password;

  String attr(String key) => attributes[key] ?? '';

  /// 连接显示名
  String get name => attr('ConnectionName');

  /// Navicat 原始类型(MYSQL / POSTGRESQL / SQLSERVER / SQLITE ...)
  String get connType => attr('ConnType');

  /// daro 私有的分组属性(Navicat 自身不写也不读,见 navicat_export.dart 顶部说明)。
  ///
  /// 老文件与 Navicat 原生导出的文件都没有这个属性,返回空串 = 未分组。
  String get group => attr('Group').trim();

  /// 归一到 daro 的类型 id
  String get typeId =>
      kNavicatConnTypes[connType.toUpperCase()] ?? connType.toLowerCase();

  /// daro 是否已实现该引擎的驱动(未实现的导入进来也是死条目,故不放开勾选)
  bool get isSupported => kSupportedDriverTypes.contains(typeId);

  /// SQLite / Access:寻址方式是文件路径而非 host:port
  bool get isFileBased => typeId == 'sqlite' || typeId == 'access';

  /// 文件型连接的数据库文件路径
  String get filePath =>
      attr('DatabaseFileName').isNotEmpty ? attr('DatabaseFileName') : attr('Database');

  String get host => isFileBased ? filePath : attr('Host');

  String get port => attr('Port');

  String get database => isFileBased ? filePath : attr('Database');

  String get userName => attr('UserName');

  /// 需要用户在导入后自行补填密码(未保存 or 未能解密)
  bool get needsManualPassword => passwordState == NavicatPasswordState.notSaved ||
      passwordState == NavicatPasswordState.undecryptable;

  /// SQL Server 验证方式,其余引擎留空(与连接表单的约定一致)
  String get authMethod => typeId != 'sqlserver'
      ? ''
      : (attr('MSSQLAuthenMode').toUpperCase() == 'WINDOWS' ? 'windows' : 'sql');

  /// 一行摘要:文件型显示路径,其余显示 host:port(有实例名时保留 host 原文)
  String get targetLabel {
    if (isFileBased) return filePath.isEmpty ? '(未指定文件)' : filePath;
    final h = host.isEmpty ? '(未指定主机)' : host;
    if (port.isEmpty || port == '0') return h;
    // SQL Server 的命名实例形如 localhost\SQLEXPRESS,不再追加端口
    return typeId == 'sqlserver' ? h : '$h:$port';
  }

  /// 映射为 daro 连接配置。
  ///
  /// 字段约定与新建连接表单([ConnectionInfo] 的落盘格式)保持一致:
  /// 文件型把路径同时写入 host 与 database;SQL Server 不写端口(驱动按
  /// host/实例名寻址);未解出密码时 password 留空,不写假值。
  ConnectionInfo toConnection({String? overrideName}) {
    return ConnectionInfo(
      name: (overrideName ?? name).isEmpty ? connType : (overrideName ?? name),
      typeId: typeId,
      host: host,
      // 表单约定:文件型与 SQL Server 均不落端口
      port: (isFileBased || typeId == 'sqlserver') ? '' : port,
      username: userName,
      password: passwordState == NavicatPasswordState.decrypted ? password : '',
      database: database,
      authMethod: authMethod,
      // 分组随连接一起落地;分组条目由 AppState.addConnections 在缺失时自动登记
      group: group,
      isLive: true,
    );
  }
}

/// 一个 `.ncx` 文件的解析结果。
class NavicatNcx {
  NavicatNcx({required this.connections, this.formatVersion = ''});

  /// 全部连接(保持文件中的原始顺序)
  final List<NavicatConnection> connections;

  /// `<Connections Ver="1.5">` 里的导出格式版本,仅用于界面提示
  final String formatVersion;

  /// 读取并解析磁盘上的 `.ncx`。
  ///
  /// Navicat 在中文 Windows 上偶尔按本地代码页(GBK)写出、却仍声明 UTF-8,
  /// 因此 UTF-8 解码失败时回退 [systemEncoding],避免整文件不可用。
  static NavicatNcx readFileSync(String path) {
    final bytes = File(path).readAsBytesSync();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = systemEncoding.decode(bytes);
    }
    return NavicatNcx.parse(text);
  }

  /// 解析 NCX 文本。格式不符时抛 [FormatException](带中文原因,供 UI 直接展示)。
  static NavicatNcx parse(String text) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlParserException catch (e) {
      throw FormatException('文件不是合法的 XML:${e.message}');
    }
    if (doc.rootElement.name.local != 'Connections') {
      throw FormatException('根节点不是 <Connections>,不像 Navicat 导出的连接文件(.ncx)');
    }
    // 同一密码在导出文件里会重复上百次(实测 379 条连接只有 29 个不同密文),
    // 按密文记忆化解密结果,避免重复做 AES 运算。
    final memo = <String, NavicatDecodedPassword>{};
    final connections = <NavicatConnection>[
      for (final el in doc.rootElement.findElements('Connection'))
        () {
          final attrs = <String, String>{
            for (final a in el.attributes) a.name.local: a.value,
          };
          final saved = (attrs['SavePassword'] ?? '').toLowerCase() == 'true';
          // 键里带上 saved:空密文在「未保存密码」与「本就无需密码」两种状态下
          // 语义不同,不能复用同一条缓存
          final decoded = memo.putIfAbsent('$saved|${attrs['Password'] ?? ''}',
              () => decryptNavicatPassword(attrs['Password'] ?? '',
                  saved: saved));
          return NavicatConnection(
            attributes: attrs,
            passwordState: decoded.state,
            password: decoded.password,
          );
        }(),
    ];
    if (connections.isEmpty) {
      throw FormatException('文件里没有 <Connection> 条目,可能未导出任何连接');
    }
    return NavicatNcx(
      connections: connections,
      formatVersion: doc.rootElement.getAttribute('Ver') ?? '',
    );
  }
}

/// AES-128-CBC 解密 + PKCS#7 去填充后的明文。
class NavicatDecodedPassword {
  const NavicatDecodedPassword(this.state, [this.password = '']);
  final NavicatPasswordState state;
  final String password;
}

/// 解密 Navicat `Password` 属性(大写十六进制密文)。
///
/// [saved] 为 false 时直接判定「未保存密码」,不去猜密文;
/// 解不出(非十六进制、长度不是整块、填充非法、含控制字符)一律回
/// [NavicatPasswordState.undecryptable],不返回半成品明文。
NavicatDecodedPassword decryptNavicatPassword(String cipherHex, {bool saved = true}) {
  if (!saved) {
    // Navicat 里就没存密码:导出文件必然为空,交由用户手填
    return const NavicatDecodedPassword(NavicatPasswordState.notSaved);
  }
  if (cipherHex.isEmpty) {
    return const NavicatDecodedPassword(NavicatPasswordState.noPassword);
  }
  final cipher = _tryParseHex(cipherHex);
  if (cipher == null || cipher.isEmpty || cipher.length % 16 != 0) {
    return const NavicatDecodedPassword(NavicatPasswordState.undecryptable);
  }
  final Uint8List padded;
  try {
    padded = aesCbcDecrypt(_libccKeyBytes, _libccIvBytes, cipher);
  } on ArgumentError {
    return const NavicatDecodedPassword(NavicatPasswordState.undecryptable);
  }
  final plain = _stripPkcs7(padded);
  if (plain == null) {
    return const NavicatDecodedPassword(NavicatPasswordState.undecryptable);
  }
  final text = _decodePrintable(plain);
  if (text == null) {
    return const NavicatDecodedPassword(NavicatPasswordState.undecryptable);
  }
  return NavicatDecodedPassword(NavicatPasswordState.decrypted, text);
}

/// AES-128/192/256-CBC 解密(输入必须是整块长度的密文,不做去填充)。
Uint8List aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List cipher) {
  final cbc = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(cipher.length);
  var off = 0;
  while (off < cipher.length) {
    off += cbc.processBlock(cipher, off, out, off);
  }
  return out;
}

/// PKCS#7 在 16 字节块下需要补的字节数(明文恰为整块时补满一块)
int _pkcs7Pad(int len) => 16 - (len % 16);

/// AES-CBC 加密 + PKCS#7 填充。与 [aesCbcDecrypt] 成对,供往返自测使用。
Uint8List aesCbcEncrypt(Uint8List key, Uint8List iv, Uint8List plain) {
  final pad = _pkcs7Pad(plain.length);
  final padded = Uint8List(plain.length + pad)
    ..setRange(0, plain.length, plain)
    ..setRange(plain.length, plain.length + pad, List<int>.filled(pad, pad));
  final cbc = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(padded.length);
  var off = 0;
  while (off < padded.length) {
    off += cbc.processBlock(padded, off, out, off);
  }
  return out;
}

/// 校验并剥离 PKCS#7 填充;填充值与末尾字节不吻合时返回 null(视为解密失败)。
Uint8List? _stripPkcs7(Uint8List padded) {
  if (padded.isEmpty) return null;
  final n = padded.last;
  if (n < 1 || n > 16 || n > padded.length) return null;
  for (var i = padded.length - n; i < padded.length; i++) {
    if (padded[i] != n) return null;
  }
  return Uint8List.sublistView(padded, 0, padded.length - n);
}

/// Navicat 按 UTF-8(Encoding=65001)存密码字节。
/// 解出的字节必须能按 UTF-8 解码且不含控制字符,否则判定为解错。
String? _decodePrintable(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  for (final b in bytes) {
    if (b < 0x20 || b == 0x7f) return null;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// 严格十六进制解析:奇数长度、非 0-9a-fA-F 字符一律返回 null。
Uint8List? _tryParseHex(String text) {
  if (text.isEmpty || text.length.isOdd) return null;
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexDigit(text.codeUnitAt(i * 2));
    final lo = _hexDigit(text.codeUnitAt(i * 2 + 1));
    if (hi == null || lo == null) return null;
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int? _hexDigit(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  return null;
}
