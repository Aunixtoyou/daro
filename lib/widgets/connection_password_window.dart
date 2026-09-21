import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/sub_window.dart';
import '../data/db_data.dart';
import '../theme/app_theme.dart';
import 'connection_password_dialog.dart';

/// 子窗口入口参数里的类型标识(见 [buildSubWindowApp])
const String kConnectionPasswordWindowType = 'connectionPassword';

/// 「连接密码」补录:桌面端开独立的系统窗口(带原生标题栏),
/// 其余环境(widget 测试里插件通道会挂起、非桌面平台)回落到应用内弹窗。
///
/// 取消 / 直接关掉窗口都返回 null。
Future<ConnectionPasswordResult?> showConnectionPasswordDialog(
  BuildContext context, {
  required ConnectionInfo conn,
}) async {
  if (!canUseSubWindow) {
    return showDialog<ConnectionPasswordResult>(
      context: context,
      builder: (_) => ConnectionPasswordDialog(conn: conn),
    );
  }
  final palette = Tokens.read(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  try {
    return await openSubWindow<ConnectionPasswordResult>(
      channelPrefix: 'daro/connection_password',
      args: (channelName) => encodeConnectionPasswordWindowArgs(
        conn: conn,
        palette: palette,
        dark: dark,
        channelName: channelName,
      ),
      onSubmit: (call) {
        final a = call.arguments as Map;
        return ConnectionPasswordResult(
          a['password'] as String? ?? '',
          save: a['save'] == true,
        );
      },
    );
  } on MissingPluginException {
    return showDialog<ConnectionPasswordResult>(
      context: context,
      builder: (_) => ConnectionPasswordDialog(conn: conn),
    );
  }
}

/// 子窗口入口参数(父侧写 / 子侧读的唯一契约,见 [buildSubWindowApp])。
///
/// [channelName] 由 [openSubWindow] 生成,子窗口凭它回话。
Map<String, dynamic> encodeConnectionPasswordWindowArgs({
  required ConnectionInfo conn,
  required AppPalette palette,
  required bool dark,
  required String channelName,
}) =>
    {
      'type': kConnectionPasswordWindowType,
      'channel': channelName,
      'dark': dark,
      'palette': palette.toJson(),
      'conn': conn.toJson(),
    };

/// 按入口参数构建「连接密码」子窗口(参数非法时返回 null)
Widget? buildConnectionPasswordWindowApp(Map<String, dynamic> payload) {
  final dynamic conn = payload['conn'];
  final dynamic palette = payload['palette'];
  final channelName = payload['channel'];
  if (conn is! Map || palette is! Map || channelName is! String) return null;
  return ConnectionPasswordWindowApp(
    conn: ConnectionInfo.fromJson(Map<String, dynamic>.from(conn)),
    palette: AppPalette.fromJson(Map<String, dynamic>.from(palette)),
    dark: payload['dark'] == true,
    channelName: channelName,
  );
}

/// 「连接密码」独立窗口的 App 根:自带主题与 TokenScope,
/// 原生标题栏承担标题与关闭,内容区只有表单。
class ConnectionPasswordWindowApp extends StatelessWidget {
  const ConnectionPasswordWindowApp({
    super.key,
    required this.conn,
    required this.palette,
    required this.dark,
    required this.channelName,
  });

  final ConnectionInfo conn;
  final AppPalette palette;
  final bool dark;
  final String channelName;

  @override
  Widget build(BuildContext context) {
    return buildSubWindowAppRoot(
      context: context,
      title: connectionPasswordTitle(conn),
      palette: palette,
      dark: dark,
      child: _PasswordWindow(
        conn: conn,
        palette: palette,
        dark: dark,
        channelName: channelName,
      ),
    );
  }
}

class _PasswordWindow extends StatefulWidget {
  const _PasswordWindow({
    required this.conn,
    required this.palette,
    required this.dark,
    required this.channelName,
  });

  final ConnectionInfo conn;
  final AppPalette palette;
  final bool dark;
  final String channelName;

  @override
  State<_PasswordWindow> createState() => _PasswordWindowState();
}

class _PasswordWindowState extends State<_PasswordWindow> {
  /// 量表单自然尺寸用:窗口要撑到刚好装下它
  final GlobalKey _formKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _configureWindow());
  }

  Future<void> _configureWindow() => configureSubWindow(
        channelName: widget.channelName,
        title: connectionPasswordTitle(widget.conn),
        palette: widget.palette,
        dark: widget.dark,
        contentSize: () => _formSize,
      );

  /// 表单的自然尺寸:高度只能运行时量,写死常量会随字体与文字缩放失准
  Size get _formSize {
    final box = _formKey.currentContext?.findRenderObject();
    if (box is! RenderBox || box.size.isEmpty) {
      throw StateError('密码表单尚未完成布局');
    }
    return box.size;
  }

  Future<void> _finish(ConnectionPasswordResult? result) => finishSubWindow(
        widget.channelName,
        result: result == null
            ? null
            : {'password': result.password, 'save': result.save},
      );

  @override
  Widget build(BuildContext context) {
    // 固定成表单宽度再量自然高度;外层可滚动,窗口尺寸差一两个像素时
    // 余量落在底部背景上,不会再撑出 RenderFlex 溢出。
    // Align 是必需的:滚动视口会把子项横向拉成视口宽,固定宽度就失效了。
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: _formKey,
          width: kConnectionPasswordFormWidth,
          child: ConnectionPasswordForm(
            conn: widget.conn,
            onSubmitted: _finish,
            onCancelled: () => _finish(null),
          ),
        ),
      ),
    );
  }
}
