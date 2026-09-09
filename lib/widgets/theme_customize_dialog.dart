import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../theme/app_theme.dart';

/// 主题定制弹窗:在弹窗内切换明 / 暗主题,逐项修改 [AppPalette] 的全部 16 个
/// 通用语义色字段,确认后整窗重建生效并落盘到 [ThemeStore]。
///
/// Token 按抽象层级分组(底色 / 前景 / 交互 / 线条),不绑定具体组件,
/// 业务定制色(图标 / 头像 等 [AppColors])不出现在此对话框。
///
/// 编辑期间维护本地草稿 [_draftLight] / [_draftDark],不触发全局重建;
/// 点“确定”才一次性写入 [AppState.setCustomPalette]。
class ThemeCustomizeDialog extends StatefulWidget {
  const ThemeCustomizeDialog({super.key});

  @override
  State<ThemeCustomizeDialog> createState() => _ThemeCustomizeDialogState();
}

class _ThemeCustomizeDialogState extends State<ThemeCustomizeDialog> {
  /// DialogBox 正文固定高度(与 build 里的 height 参数同源,
  /// 供 _buildTabControl 约束 tab body 使用)。
  static const double _kBodyHeight = 480;

  /// TabControl chrome 高度:标签条 31(未选中头 28 + 选中加高 2 + 面板顶线 1)
  /// + 面板底边框 1。需配合 contentPadding: zero 计算。
  static const double _kTabChromeHeight = 32;

  late AppPalette _draftLight;
  late AppPalette _draftDark;
  late Brightness _current;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _draftLight = app.effectiveLight;
    _draftDark = app.effectiveDark;
    _current = _brightnessFor(app.themeMode);
  }

  Brightness _brightnessFor(ThemeMode mode) => switch (mode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  void _setDraft(AppPalette next) {
    setState(() {
      if (_current == Brightness.dark) {
        _draftDark = next;
      } else {
        _draftLight = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '主题定制',
      width: 720,
      // 固定正文高度:TabControl 内部 SingleChildScrollView 需要有界高度
      height: _kBodyHeight,
      onClose: () => Navigator.of(context).maybePop(),
      footer: _buildFooter(),
      child: _buildTabControl(t),
    );
  }

  // ── TabControl (明亮 / 暗黑) ─────────────────────────────────────────────

  Widget _buildTabControl(AppPalette t) {
    // TabControl 内部 Column(mainAxisSize: min) 不会给 tab body 提供有界高度,
    // 导致 SingleChildScrollView 无限撑开 → 布局/命中测试崩溃。
    // 因此用与 DialogBox 同源的固定高度约束 TabControl。
    // 不能用 LayoutBuilder 测量:它与 DialogBox 的 IntrinsicHeight 冲突,
    // 会触发 "LayoutBuilder does not support returning intrinsic dimensions"
    // 断言(同 ConnectionFormPage 内 ComboBox 的修复方式)。
    final bodyHeight = _kBodyHeight - _kTabChromeHeight;
    return SizedBox(
      height: _kBodyHeight,
      child: TabControl(
        initialIndex: _current == Brightness.dark ? 1 : 0,
        // 面板内边距由各 tab body 自带,这里置零才能用固定高度精确对齐
        contentPadding: EdgeInsets.zero,
        onChanged: (index) {
          // 延迟到下一帧再更新状态,避免鼠标事件处理期间触发 setState 导致断言错误
          // (TabControl 内部 _select 已经 setState,外部再同步 setState 会导致
          // MouseRegion 在设备更新中被重建/替换,触发 mouse_tracker 断言)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _current = index == 0 ? Brightness.light : Brightness.dark;
              });
            }
          });
        },
        tabs: [
          TabItem(
            label: '明亮主题',
            child: SizedBox(
              height: bodyHeight,
              child: _buildTabBody(t, Brightness.light),
            ),
          ),
          TabItem(
            label: '暗黑主题',
            child: SizedBox(
              height: bodyHeight,
              child: _buildTabBody(t, Brightness.dark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody(AppPalette t, Brightness which) {
    final palette = which == Brightness.dark ? _draftDark : _draftLight;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in _FieldGroups.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _FieldGroupView(
                title: group.title,
                fields: group.fields,
                palette: palette,
                onPick: (field) => _pickColor(field, which),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickColor(_Field field, Brightness which) async {
    // 事件回调中取色:用 read 避免 build 外 watch 断言
    final t = Tokens.read(context);
    final draft = which == Brightness.dark ? _draftDark : _draftLight;
    final result = await showDialog<Color>(
      context: context,
      builder: (dialogCtx) => ColorDialog(
        selectedColor: field.get(draft),
        tokens: t.toDesktopTokens(),
        onConfirm: (c) => Navigator.of(dialogCtx).pop(c),
        onCancel: () => Navigator.of(dialogCtx).pop(),
      ),
    );
    if (result != null) {
      _setDraft(field.set(draft, result));
    }
  }

  // ── Footer: 重置当前 / 重置全部 / 应用 / 取消 / 确定 ────────────────────────────

  Widget _buildFooter() {
    return Row(
      children: [
        Button(
          text: '重置当前',
          variant: ButtonVariant.ghost,
          onPressed: () {
            final app = context.read<AppState>();
            app.resetCustomPalette(_current);
            setState(() {
              if (_current == Brightness.dark) {
                _draftDark = AppTheme.dark;
              } else {
                _draftLight = AppTheme.light;
              }
            });
          },
        ),
        const SizedBox(width: 8),
        Button(
          text: '重置全部',
          variant: ButtonVariant.ghost,
          onPressed: () {
            final app = context.read<AppState>();
            app.resetCustomPalette(_current, all: true);
            setState(() {
              _draftLight = AppTheme.light;
              _draftDark = AppTheme.dark;
            });
          },
        ),
        const Spacer(),
        Button(
          text: '应用',
          onPressed: () {
            context
                .read<AppState>()
                .setCustomPalette(light: _draftLight, dark: _draftDark);
          },
        ),
        const SizedBox(width: 8),
        Button(
          text: '取消',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 8),
        Button(
          text: '确定',
          onPressed: () {
            context
                .read<AppState>()
                .setCustomPalette(light: _draftLight, dark: _draftDark);
            Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }
}

// ===========================================================================
// 字段表 + 分组(仅通用 token,不含业务定制色)
// ===========================================================================

class _Field {
  _Field(this.label, this.get, this.set);
  final String label;
  final Color Function(AppPalette) get;
  final AppPalette Function(AppPalette, Color) set;
}

class _FieldGroup {
  _FieldGroup(this.title, this.fields);
  final String title;
  final List<_Field> fields;
}

class _FieldGroups {
  static final all = <_FieldGroup>[
    _FieldGroup('底色', _backgrounds),
    _FieldGroup('前景', _foregrounds),
    _FieldGroup('交互', _interaction),
    _FieldGroup('线条', _lines),
  ];

  /// 背景色:按抽象层级划分,不绑定具体组件
  static final _backgrounds = <_Field>[
    _Field('窗口底色', (p) => p.background,
        (p, c) => p.copyWith(background: c)),
    _Field('面板底色', (p) => p.surface,
        (p, c) => p.copyWith(surface: c)),
    _Field('控件底色', (p) => p.control,
        (p, c) => p.copyWith(control: c)),
    _Field('次级底色', (p) => p.secondary,
        (p, c) => p.copyWith(secondary: c)),
    _Field('条带底色', (p) => p.statusBar,
        (p, c) => p.copyWith(statusBar: c)),
    _Field('浮动底色', (p) => p.popover,
        (p, c) => p.copyWith(popover: c)),
    _Field('柔和底色', (p) => p.muted,
        (p, c) => p.copyWith(muted: c)),
  ];

  /// 前景色:文字 / 图标颜色
  static final _foregrounds = <_Field>[
    _Field('主要前景', (p) => p.foreground,
        (p, c) => p.copyWith(foreground: c)),
    _Field('次要前景', (p) => p.mutedForeground,
        (p, c) => p.copyWith(mutedForeground: c)),
    _Field('禁用前景', (p) => p.disabledForeground,
        (p, c) => p.copyWith(disabledForeground: c)),
    _Field('强调前景', (p) => p.accentForeground,
        (p, c) => p.copyWith(accentForeground: c)),
  ];

  /// 交互色:选中 / 高亮状态
  static final _interaction = <_Field>[
    _Field('强调底色', (p) => p.accent, (p, c) => p.copyWith(accent: c)),
    _Field('高亮底色', (p) => p.highlight, (p, c) => p.copyWith(highlight: c)),
  ];

  /// 线条:边框 / 分隔 / 网格
  static final _lines = <_Field>[
    _Field('边框线', (p) => p.border, (p, c) => p.copyWith(border: c)),
    _Field('分隔线', (p) => p.divider, (p, c) => p.copyWith(divider: c)),
    _Field('网格线', (p) => p.gridLine, (p, c) => p.copyWith(gridLine: c)),
  ];
}

class _FieldGroupView extends StatelessWidget {
  const _FieldGroupView({
    required this.title,
    required this.fields,
    required this.palette,
    required this.onPick,
  });

  final String title;
  final List<_Field> fields;
  final AppPalette palette;
  final ValueChanged<_Field> onPick;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.mutedForeground,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: t.border, width: 1),
          ),
          child: Column(
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: t.divider),
                ListItem(
                  leading: _colorSwatch(t, fields[i].get(palette)),
                  title: fields[i].label,
                  trailing: Text(
                    _hex(fields[i].get(palette)),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: t.disabledForeground,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  height: 30,
                  borderRadius: BorderRadius.zero,
                  hoverBase: t.background,
                  onSelect: () => onPick(fields[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 字段色块:当前取色的小方块
  static Widget _colorSwatch(AppPalette t, Color color) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: t.border, width: 1),
        ),
      );

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

