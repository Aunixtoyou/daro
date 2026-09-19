import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/version.g.dart';
import '../theme/app_theme.dart';

/// 项目主页与问题反馈地址(与 top_menu「帮助 → 问题反馈」指向同一仓库)。
const String kProjectHomeUrl = 'https://github.com/SpringHgui/daro';
const String kIssuesUrl = '$kProjectHomeUrl/issues';

/// 打开「帮助 → 关于…」弹窗。
Future<void> showDaroAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const DaroAboutDialog(),
  );
}

/// 「关于」弹窗:启动画面式版面(居中 Logo + 名称 + 副标题 + 版本 + 版权),
/// 面板底色与文字均取当前主题中性色板,明暗双主题自适应。
///
/// 版本号取自 pubspec.yaml 生成的 [kAppVersion] / [kAppBuild],勿在此硬编码。
class DaroAboutDialog extends StatelessWidget {
  const DaroAboutDialog({super.key});

  static const double _kWidth = 400;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final dt = t.toDesktopTokens();

    return DialogBox(
      title: '关于 daro',
      width: _kWidth,
      onClose: () => Navigator.of(context).maybePop(),
      child: Container(
        color: t.background,
        padding: const EdgeInsets.fromLTRB(28, 34, 28, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildLogo(t),
            const SizedBox(height: 22),
            _buildTitle(dt, t),
            const SizedBox(height: 34),
            _buildLinks(context, dt),
            const SizedBox(height: 26),
            _buildFooter(dt, t),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo(AppPalette t) {
    return Center(
      child: Container(
        width: 108,
        height: 108,
        decoration: BoxDecoration(
          color: t.muted,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: t.border),
        ),
        padding: const EdgeInsets.all(16),
        child: SvgPicture.asset('assets/icons/app_logo.svg'),
      ),
    );
  }

  Widget _buildTitle(DesktopTokens dt, AppPalette t) {
    return Column(
      children: [
        Text(
          'daro',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: dt.fontFamily,
            fontSize: 38,
            height: 1.1,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: t.foreground,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '桌面数据库管理工具',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: dt.fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            letterSpacing: 3,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '版本 $kAppVersion（构建 $kAppBuild）',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: dt.fontFamily,
            fontSize: dt.fontSize,
            fontWeight: FontWeight.w400,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }

  Widget _buildLinks(BuildContext context, DesktopTokens dt) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Button(
          text: '项目主页',
          tokens: dt,
          onPressed: () => _openUrl(context, kProjectHomeUrl),
        ),
        const SizedBox(width: 10),
        Button(
          text: '问题反馈',
          tokens: dt,
          onPressed: () => _openUrl(context, kIssuesUrl),
        ),
      ],
    );
  }

  Widget _buildFooter(DesktopTokens dt, AppPalette t) {
    return Text(
      'Copyright © ${DateTime.now().year} daro. 保留所有权利.',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: dt.fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: t.mutedForeground,
        decoration: TextDecoration.none,
      ),
    );
  }

  /// 用系统默认浏览器打开链接;失败时退化为弹窗展示 URL,避免点击无反馈。
  Future<void> _openUrl(BuildContext context, String url) async {
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[about_dialog] launchUrl failed: $e');
      opened = false;
    }
    if (opened || !context.mounted) return;
    MessageBox.show(
      context,
      title: '无法打开浏览器',
      message: '请在浏览器中访问:\n$url',
      buttons: MessageBoxButtons.ok,
      tokens: Tokens.read(context).toDesktopTokens(),
    );
  }
}
