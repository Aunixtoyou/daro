import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';

/// 通用 UI 色板:与 base-ui-flutter 的 [DesktopTokens] 命名对齐,
/// 各 widget 不硬编码颜色,统一通过 [Tokens.of] 取色。
///
/// 设计原则:按抽象语义层级命名(底色 / 前景 / 交互 / 线条),
/// 不绑定具体组件(如“工具栏”“状态栏”),仅包含通用 UI 结构色。
/// 业务定制色(图标 / 头像 等)由 [AppColors] 独立管理,
/// 不出现在主题定制对话框中。
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.control,
    required this.secondary,
    required this.statusBar,
    required this.popover,
    required this.foreground,
    required this.mutedForeground,
    required this.disabledForeground,
    required this.accentForeground,
    required this.accent,
    required this.highlight,
    required this.border,
    required this.divider,
    required this.gridLine,
    required this.muted,
  });

  /// 窗口 / 主面板底色 (→ backgroundColor)
  final Color background;

  /// 面板 / 次级区域底色 (→ surfaceColor)
  final Color surface;

  /// 控件 / 交互元素底色 (→ controlColor)
  final Color control;

  /// 次级 / 内嵌区域底色 (→ secondaryColor)
  final Color secondary;

  /// 条带区域底色
  final Color statusBar;

  /// 浮动层 / 弹出内容底色 (→ popoverColor)
  final Color popover;

  /// 主要前景色 (→ foregroundColor)
  final Color foreground;

  /// 次要前景色 (→ mutedForegroundColor)
  final Color mutedForeground;

  /// 禁用前景色 (→ disabledForegroundColor)
  final Color disabledForeground;

  /// 强调背景上的前景色 (→ accentForegroundColor)
  final Color accentForeground;

  /// 强调 / 选中态底色 (→ accentColor / primaryColor)
  final Color accent;

  /// 高亮态底色
  final Color highlight;

  /// 主边框线 (→ borderColor)
  final Color border;

  /// 次级分隔线
  final Color divider;

  /// 网格线
  final Color gridLine;

  /// 柔和底色 / 槽位背景 (→ mutedColor)
  final Color muted;

  /// 连接树节点选中背景:[accent] 低透明度混合 [background],
  /// 明暗自适应地得到淡蓝(文字仍用 [foreground],不再反白)
  Color get treeSelectedBg =>
      Color.alphaBlend(accent.withValues(alpha: 0.15), background);

  /// 拷贝并覆盖指定字段,用于主题定制时逐项修改。
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? control,
    Color? secondary,
    Color? statusBar,
    Color? popover,
    Color? foreground,
    Color? mutedForeground,
    Color? disabledForeground,
    Color? accentForeground,
    Color? accent,
    Color? highlight,
    Color? border,
    Color? divider,
    Color? gridLine,
    Color? muted,
  }) =>
      AppPalette(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        control: control ?? this.control,
        secondary: secondary ?? this.secondary,
        statusBar: statusBar ?? this.statusBar,
        popover: popover ?? this.popover,
        foreground: foreground ?? this.foreground,
        mutedForeground: mutedForeground ?? this.mutedForeground,
        disabledForeground: disabledForeground ?? this.disabledForeground,
        accentForeground: accentForeground ?? this.accentForeground,
        accent: accent ?? this.accent,
        highlight: highlight ?? this.highlight,
        border: border ?? this.border,
        divider: divider ?? this.divider,
        gridLine: gridLine ?? this.gridLine,
        muted: muted ?? this.muted,
      );

  /// 序列化为 字段名 -> #RRGGBB 的映射,用于本地持久化。
  Map<String, String> toJson() => {
        'background': _hex(background),
        'surface': _hex(surface),
        'control': _hex(control),
        'secondary': _hex(secondary),
        'statusBar': _hex(statusBar),
        'popover': _hex(popover),
        'foreground': _hex(foreground),
        'mutedForeground': _hex(mutedForeground),
        'disabledForeground': _hex(disabledForeground),
        'accentForeground': _hex(accentForeground),
        'accent': _hex(accent),
        'highlight': _hex(highlight),
        'border': _hex(border),
        'divider': _hex(divider),
        'gridLine': _hex(gridLine),
        'muted': _hex(muted),
      };

  /// 从持久化的字段映射还原色板;缺失 / 非法字段回退到 [AppTheme.light] 默认值。
  ///
  /// 兼容旧版键名:检测到旧格式(含 menuBar / textPrimary 等已废弃键)时
  /// 先映射到新键名再解析,确保用户历史定制不丢失。
  static AppPalette fromJson(Map<String, dynamic> json) {
    // 旧格式检测:只要含任一旧键名就走迁移分支
    const oldKeys = {
      'menuBar', 'ribbonBar', 'tabBar', 'popupBg',
      'textPrimary', 'textSecondary', 'textMuted', 'textOnSelected',
      'selectedBg', 'highlightBg', 'gutterBg',
    };
    final isLegacy = oldKeys.any(json.containsKey);
    if (isLegacy) {
      return AppTheme.light.copyWith(
        background: _colOrNull(json['surface']),
        surface: _colOrNull(json['menuBar']),
        control: _colOrNull(json['ribbonBar']),
        secondary: _colOrNull(json['tabBar']),
        statusBar: _colOrNull(json['statusBar']),
        popover: _colOrNull(json['popupBg']),
        foreground: _colOrNull(json['textPrimary']),
        mutedForeground: _colOrNull(json['textSecondary']),
        disabledForeground: _colOrNull(json['textMuted']),
        accentForeground: _colOrNull(json['textOnSelected']),
        accent: _colOrNull(json['selectedBg']),
        highlight: _colOrNull(json['highlightBg']),
        border: _colOrNull(json['border']),
        divider: _colOrNull(json['divider']),
        gridLine: _colOrNull(json['gridLine']),
        muted: _colOrNull(json['gutterBg']),
      );
    }
    return AppTheme.light.copyWith(
      background: _colOrNull(json['background']),
      surface: _colOrNull(json['surface']),
      control: _colOrNull(json['control']),
      secondary: _colOrNull(json['secondary']),
      statusBar: _colOrNull(json['statusBar']),
      popover: _colOrNull(json['popover']),
      foreground: _colOrNull(json['foreground']),
      mutedForeground: _colOrNull(json['mutedForeground']),
      disabledForeground: _colOrNull(json['disabledForeground']),
      accentForeground: _colOrNull(json['accentForeground']),
      accent: _colOrNull(json['accent']),
      highlight: _colOrNull(json['highlight']),
      border: _colOrNull(json['border']),
      divider: _colOrNull(json['divider']),
      gridLine: _colOrNull(json['gridLine']),
      muted: _colOrNull(json['muted']),
    );
  }

  /// 颜色 -> #RRGGBB(应用主题色均为不透明,丢弃 alpha 段)
  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  /// #RRGGBB / #AARRGGBB -> Color;格式非法返回 null(调用方据此回退默认)
  static Color? _colOrNull(dynamic s) {
    if (s is! String) return null;
    var h = s.replaceAll('#', '').replaceAll('0x', '').trim();
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }

  /// 将本应用语义色板桥接到 [DesktopTokens],
  /// 使 base_ui_flutter 组件自动跟随当前明 / 暗主题。
  DesktopTokens toDesktopTokens() => DesktopTokens.winForm.copyWith(
        primaryColor: accent,
        backgroundColor: background,
        foregroundColor: foreground,
        borderColor: border,
        surfaceColor: background,
        controlColor: control,
        controlHoverColor: _blend(control, const Color(0x14000000)),
        controlPressedColor: _blend(control, const Color(0x1F000000)),
        controlDisabledColor: surface,
        disabledForegroundColor: disabledForeground,
        mutedColor: muted,
        mutedForegroundColor: mutedForeground,
        secondaryColor: secondary,
        secondaryForegroundColor: foreground,
        accentColor: accent,
        accentForegroundColor: accentForeground,
        cardColor: background,
        cardForegroundColor: foreground,
        popoverColor: popover,
        popoverForegroundColor: foreground,
        ringColor: accent,
        // hover / pressed 叠加色必须明暗自适应:暗色提亮、亮色加深,
        // 否则 base-ui 组件(按钮 / 列表行等)在暗色主题下 hover 不可见
        hoverOverlayColor: background.computeLuminance() > 0.5
            ? const Color(0x0F000000)
            : const Color(0x14FFFFFF),
        pressedOverlayColor: background.computeLuminance() > 0.5
            ? const Color(0x1F000000)
            : const Color(0x24FFFFFF),
      );

  /// Alpha-blend [overlay] onto [base].
  static Color _blend(Color base, Color overlay) =>
      Color.alphaBlend(overlay, base);
}

/// 业务定制色:图标 / 头像等应用特有颜色,不暴露给主题定制对话框。
///
/// 命名采用语义泛称,不绑定具体业务实体:
/// - [iconPrimary]   — 主图标色(表 / 函数)
/// - [iconInfo]      — 信息图标色(连接)
/// - [iconSuccess]   — 成功图标色(数据库)
/// - [iconSecondary] — 次级图标色(模式 / 用户)
/// - [iconWarning]   — 警告图标色(文件夹)
/// - [avatarSurface] — 头像背景
/// - [avatarForeground] — 头像前景
class AppColors {
  const AppColors({
    required this.iconPrimary,
    required this.iconInfo,
    required this.iconSuccess,
    required this.iconSecondary,
    required this.iconWarning,
    required this.avatarSurface,
    required this.avatarForeground,
  });

  /// 主图标色(表 / 函数)
  final Color iconPrimary;

  /// 信息图标色(连接)
  final Color iconInfo;

  /// 成功图标色(数据库)
  final Color iconSuccess;

  /// 次级图标色(模式 / 用户)
  final Color iconSecondary;

  /// 警告图标色(文件夹)
  final Color iconWarning;

  /// 头像背景
  final Color avatarSurface;

  /// 头像前景
  final Color avatarForeground;

  /// 明亮主题业务色默认值
  static const light = AppColors(
    iconPrimary: Color(0xff1565c0),
    iconInfo: Color(0xff1f6feb),
    iconSuccess: Color(0xff2e9e4f),
    iconSecondary: Color(0xff1e8e3e),
    iconWarning: Color(0xffb58a00),
    avatarSurface: Color(0xffc9ccd1),
    avatarForeground: Color(0xff3c4043),
  );

  /// 暗黑主题业务色默认值
  static const dark = AppColors(
    iconPrimary: Color(0xff6cb6ff),
    iconInfo: Color(0xff7ec1ff),
    iconSuccess: Color(0xff8fd48f),
    iconSecondary: Color(0xff57c25a),
    iconWarning: Color(0xffe9c46a),
    avatarSurface: Color(0xff8e98a5),
    avatarForeground: Color(0xffe9edf2),
  );

  /// 从 Provider 取业务色;未注入时回退明 / 暗默认值
  static AppColors of(BuildContext context) {
    try {
      return Provider.of<AppColors>(context, listen: true);
    } catch (_) {
      final brightness = Theme.of(context).brightness;
      return brightness == Brightness.dark ? dark : light;
    }
  }
}

/// 明暗双主题色板定义
class AppTheme {
  /// 明亮主题:接近 VS Code Light 的浅色配色
  static const light = AppPalette(
    background: Color(0xffffffff),
    surface: Color(0xfff3f3f3),
    control: Color(0xfff3f3f3),
    secondary: Color(0xffececec),
    statusBar: Color(0xffe7e7e7),
    popover: Color(0xffffffff),
    foreground: Color(0xff1f1f1f),
    mutedForeground: Color(0xff5f6368),
    disabledForeground: Color(0xff80868b),
    accentForeground: Color(0xffffffff),
    accent: Color(0xff2196F3),
    highlight: Color(0xff42A5F5),
    border: Color(0xffe0e0e0),
    divider: Color(0xffe0e0e0),
    gridLine: Color(0xffe3e3e3),
    muted: Color(0xfff3f3f3),
  );

  /// 暗黑主题:沿用原版深色配色,与设计稿一致
  static const dark = AppPalette(
    background: Color(0xff252526),
    // 与 control 同色:标题栏与下方工具栏背景统一,
    // 与明亮主题下 surface == control 的行为保持一致
    surface: Color(0xff383838),
    control: Color(0xff383838),
    secondary: Color(0xff2d2d2d),
    statusBar: Color(0xff303030),
    popover: Color(0xff2d2d2d),
    foreground: Color(0xffc8cdd4),
    mutedForeground: Color(0xff9aa0a6),
    disabledForeground: Color(0xff6f7479),
    accentForeground: Color(0xffffffff),
    accent: Color(0xff2196F3),
    highlight: Color(0xff42A5F5),
    // 边框色需比背景(background 0xff252526)亮,否则暗色下控件边框不可见
    border: Color(0xff3c3c3c),
    divider: Color(0xff4a4a4a),
    gridLine: Color(0xff3c3c3c),
    muted: Color(0xff2a2a2a),
  );
}

/// 取色辅助:返回当前主题亮度对应的语义色板。
///
/// [of] 直接从 [AppState] 读取当前生效的色板(可能是用户定制后的),
/// 通过 context.watch 注册依赖,确保主题变化时依赖组件自动重建;
/// 仅允许在 build 期间调用。事件回调中取色请用 [read]。
class Tokens {
  const Tokens._();

  /// build 期间取色:注册对 [AppState] 的依赖,主题变化时自动重建。
  static AppPalette of(BuildContext context) {
    final app = context.watch<AppState>();
    return _paletteOf(app);
  }

  /// 事件回调 / build 之外取色:不注册依赖,不会因 watch 时机触发断言。
  static AppPalette read(BuildContext context) {
    final app = context.read<AppState>();
    return _paletteOf(app);
  }

  static AppPalette _paletteOf(AppState app) {
    final mode = app.themeMode;
    final brightness = mode == ThemeMode.system
        ? WidgetsBinding.instance.platformDispatcher.platformBrightness
        : (mode == ThemeMode.dark ? Brightness.dark : Brightness.light);
    return brightness == Brightness.dark ? app.effectiveDark : app.effectiveLight;
  }
}
