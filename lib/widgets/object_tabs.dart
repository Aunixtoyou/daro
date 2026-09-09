import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../theme/app_theme.dart';

// 中部面板底部的对象路径标签:连接 > 数据库(高亮)。
// 路径来自 AppState.objectContext,由连接树单击库节点设置;
// 未选择数据库时显示提示文案。
class ObjectTabs extends StatelessWidget {
  const ObjectTabs({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final activeTabModel = context.select<AppState, OpenTab?>((a) => a.activeTabModel);
    // 表/查询/数据库标签打开时状态栏已展示上下文信息,面包屑隐藏
    if (activeTabModel != null) return const SizedBox.shrink();
    final (connection, database, schema) = context.select<AppState, (String?, String?, String?)>(
        (a) => (a.objectConnection, a.objectDatabase, a.objectSchema));

    return Container(
      height: 30,
      color: t.secondary,
      child: Row(
        children: [
          if (connection == null || database == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '未选择数据库',
                style: TextStyle(fontSize: 12.5, color: t.disabledForeground),
              ),
            )
          else ...[
            _tab(t, icon: Icons.dns, text: connection),
            _chevron(t),
            _tab(t, icon: Icons.storage, text: database, highlight: schema == null),
            if (schema != null) ...[
              _chevron(t),
              _tab(t, icon: Icons.folder_outlined, text: schema, highlight: true),
            ],
          ],
        ],
      ),
    );
  }

  Widget _tab(AppPalette t, {IconData? icon, required String text, bool highlight = false}) {
    final bg = highlight ? t.highlight : null;
    final borderColor = highlight ? t.highlight : t.border;
    return Container(
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          right: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: highlight ? t.accentForeground : t.mutedForeground),
            const SizedBox(width: 6),
          ],
          Text(text, style: TextStyle(fontSize: 12.5, color: highlight ? t.accentForeground : t.foreground)),
        ],
      ),
    );
  }

  Widget _chevron(AppPalette t) => Icon(Icons.chevron_right, size: 14, color: t.disabledForeground);
}
