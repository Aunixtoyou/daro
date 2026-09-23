import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../l10n/locale_config.dart';
import '../theme/app_theme.dart';

/// 打开「工具 → 选项…」弹窗。
Future<void> showOptionsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const OptionsDialog(),
  );
}

/// 「工具 → 选项…」对话框:左侧分类树 + 右侧设置页(Navicat 选项窗口的版面)。
///
/// 目前只有「常规」一页,放着界面语言。页内改动走**草稿态**:选好要点「确定」
/// 才写入 [AppState.setLanguageCode],「取消」/ 关闭 / Esc 一律丢弃。
class OptionsDialog extends StatefulWidget {
  const OptionsDialog({super.key});

  @override
  State<OptionsDialog> createState() => _OptionsDialogState();
}

class _OptionsDialogState extends State<OptionsDialog> {
  /// 正文固定高度:左树与右页都撑满它,窗口不随内容跳动。
  static const double _kBodyHeight = 340;
  static const double _kNavWidth = 148;

  /// 语言下拉的宽度:够放「システムに従う」这类长项,又不铺满整页。
  static const double _kFieldWidth = 240;

  /// 唯一的分类。只有一项也保留树的版面,后续加分类不必动布局。
  static const String _kGeneral = 'general';

  /// 语言草稿:null = 跟随系统,点「确定」才落到 [AppState]。
  String? _languageDraft;

  @override
  void initState() {
    super.initState();
    // initState 里用 read:watch 只允许在 build 期间注册依赖。
    _languageDraft = context.read<AppState>().languageCode;
  }

  /// 下拉项 = 「跟随系统」+ 各语言**自称名**。自称名刻意不翻译
  /// (见 [kLanguageEndonyms]),否则用户在不懂当前界面语言时反而找不到
  /// 自己看得懂的那一项。
  List<String> _languageItems(AppLocalizations l) => [
        l.langFollowSystem,
        for (final code in kSupportedLanguageCodes)
          kLanguageEndonyms[code] ?? code,
      ];

  /// 与 [_languageItems] 同序的语言码(null = 跟随系统)。
  static const List<String?> _languageCodes = [
    null,
    ...kSupportedLanguageCodes
  ];

  String _labelOf(AppLocalizations l, String? code) =>
      code == null ? l.langFollowSystem : (kLanguageEndonyms[code] ?? code);

  void _applyAndClose() {
    context.read<AppState>().setLanguageCode(_languageDraft);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = Tokens.of(context);
    final dt = t.desktopTokensFor(context);
    return DialogBox(
      title: l.optionsTitle,
      width: 620,
      height: _kBodyHeight,
      onClose: () => Navigator.of(context).maybePop(),
      footer: Row(
        children: [
          const Spacer(),
          Button(
            text: l.btnCancel,
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Button(text: l.btnOk, onPressed: _applyAndClose),
        ],
      ),
      child: SizedBox(
        height: _kBodyHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _kNavWidth,
              child: ColoredBox(
                color: t.surface,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: dt.compactSpacing,
                      vertical: dt.compactSpacing),
                  // framed:false:分类栏自己铺了底色,不需要树的边框与外框线
                  child: TreeView<String>(
                    framed: false,
                    tokens: dt,
                    nodes: [TreeNode(data: _kGeneral, label: l.optionsGeneral)],
                    selectedKey: _kGeneral.hashCode,
                  ),
                ),
              ),
            ),
            Container(width: dt.borderWidth, color: t.border),
            Expanded(
              child: ColoredBox(
                color: t.background,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TypeStyle.h4(l.optionsGeneral, tokens: dt),
                      SizedBox(height: dt.compactSpacing * 2),
                      SizedBox(
                        width: _kFieldWidth,
                        child: Field(
                          label: l.optionsLanguage,
                          description: l.optionsLanguageHint,
                          tokens: dt,
                          children: [
                            ComboBox<String>(
                              items: _languageItems(l),
                              value: _labelOf(l, _languageDraft),
                              tokens: dt,
                              onChanged: (v) {
                                if (v == null) return;
                                final i = _languageItems(l).indexOf(v);
                                if (i >= 0) {
                                  setState(
                                      () => _languageDraft = _languageCodes[i]);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
