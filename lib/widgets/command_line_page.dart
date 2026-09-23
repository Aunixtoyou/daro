import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/cli_console.dart';
import '../l10n/locale_config.dart';
import '../theme/app_theme.dart';

/// 出错行的中调红:与查询编辑页「消息」同一取值,命令行里的 ERROR 回显用它
const Color _errorColor = Color(0xffd93025);

/// 输出行配色:回显的语句用次要文字色,结果正文用前景色,
/// ERROR 用中调红,系统提示(取消续行等)用强调色
Color _lineColor(AppPalette t, CliLineKind kind) => switch (kind) {
      CliLineKind.input => t.mutedForeground,
      CliLineKind.output => t.foreground,
      CliLineKind.error => _errorColor,
      CliLineKind.info => t.accent,
    };

/// 命令列界面:一个绑定到「连接 + 库」的文本式 SQL 控制台。
///
/// 会话状态(输出行 / 续行缓冲 / 历史)存在 [AppState] 的 [CliConsole] 里,
/// 本页面只做渲染与输入装配 —— 切换标签会销毁页面,存这里才不会丢日志。
/// 语句经现有驱动逐条执行(不启外部 mysql / psql 进程),因此不需要本机安装
/// 对应客户端,也不额外要求补录一次密码。
class CommandLinePage extends StatefulWidget {
  const CommandLinePage({
    super.key,
    required this.connection,
    required this.database,
  });

  final String connection;
  final String database;

  @override
  State<CommandLinePage> createState() => _CommandLinePageState();
}

class _CommandLinePageState extends State<CommandLinePage> {
  final TextEditingController _input = TextEditingController();
  late final FocusNode _inputFocus;
  final ScrollController _scroll = ScrollController();

  /// 上一次渲染的输出行数:只在行数变化时滚到底,避免选字时被拽回去
  int _lastLineCount = 0;

  @override
  void initState() {
    super.initState();
    // ↑ / ↓ 翻输入历史。挂在 FocusNode 上而不是外层 Focus:节点自带的
    // onKeyEvent 先于 EditableText 的方向键处理执行,否则单行输入框会把
    // 上下键吃掉(光标挪到首尾,历史翻不出来)。
    _inputFocus = FocusNode(onKeyEvent: _onInputKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  CliConsole _console(AppState app) =>
      app.cliConsoleFor(widget.connection, widget.database);

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _recall(backwards: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _recall(backwards: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _recall({required bool backwards}) {
    final text = _console(context.read<AppState>()).recallHistory(
      backwards: backwards,
    );
    if (text == null) return;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _submit() {
    final console = _console(context.read<AppState>());
    // 上一条还在跑:保留输入框内容,不做「清空后又丢弃」
    if (console.busy) return;
    final raw = _input.text;
    _input.clear();
    // TextField 收到 done 动作会结束编辑并丢焦点:控制台要连着敲下一条,抢回来
    _inputFocus.requestFocus();
    // 不 await:长查询期间界面保持可交互,执行完由会话通知刷新
    console.submit(raw);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final console = _console(app);
    final t = Tokens.of(context);
    final mono = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['monospace'],
      fontSize: 12.5,
      height: 1.45,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w400,
    );

    return ColoredBox(
      color: t.background,
      child: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: console,
              builder: (context, _) {
                _scrollToBottom(console);
                return SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: console.lines.isEmpty
                      ? Text(
                          context.l10n.cliEmptyHint,
                          style: mono.copyWith(color: t.mutedForeground),
                        )
                      : SelectableText.rich(
                          TextSpan(
                            style: mono,
                            children: [
                              for (final line in console.lines)
                                TextSpan(
                                  text: '${line.text}\n',
                                  style: TextStyle(
                                      color: _lineColor(t, line.kind)),
                                ),
                            ],
                          ),
                        ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                ListenableBuilder(
                  listenable: console,
                  builder: (context, _) => Text(
                    console.awaitingContinuation
                        ? console.continuationPrompt
                        : console.prompt,
                    style: mono.copyWith(color: t.mutedForeground),
                  ),
                ),
                Expanded(
                  child: Input(
                    controller: _input,
                    focusNode: _inputFocus,
                    selectAllOnFocus: false,
                    hint: context.l10n.cliInputHint,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                ListenableBuilder(
                  listenable: console,
                  builder: (context, _) => console.busy
                      ? const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Spinner(size: 13),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 追加输出后滚到底(同结构同步日志区:一帧后再跳,此刻新行才有高度)
  void _scrollToBottom(CliConsole console) {
    final count = console.lines.length;
    if (count == _lastLineCount) return;
    _lastLineCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }
}
