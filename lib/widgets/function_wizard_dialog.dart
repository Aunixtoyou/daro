import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import '../app/app_state.dart';
import '../data/routine_sql.dart';
import '../l10n/locale_config.dart';
import '../theme/app_theme.dart';

/// 函数向导完成结果(由 [FunctionWizardDialog] 返回)
class RoutineWizardResult {
  const RoutineWizardResult({
    required this.category,
    required this.name,
    required this.params,
  });

  /// 例程分类:过程 / 函数
  final ObjectCategory category;

  /// 例程名称
  final String name;

  /// 参数列表(向导第 2 步采集)
  final List<RoutineParam> params;
}

/// 新建函数 / 过程的统一入口。
///
/// 未勾选「下次显示向导」时弹出两步向导(类型 + 名称 → 参数),
/// 完成后打开对应分类的例程设计页(新建模式);
/// 勾选「下次显示向导」后本会话内直接打开设计页(使用自增默认名)。
Future<void> showFunctionWizard(
  BuildContext context, {
  required AppState app,
  required String connection,
  required String database,
  String? schema,
  ObjectCategory initialCategory = ObjectCategory.function,
}) async {
  final conn = app.connectionByName(connection);
  final typeId = conn?.typeId ?? '';

  RoutineWizardResult result;
  if (FunctionWizardDialog.skipNext) {
    // 跳过向导:使用自增默认名直接打开设计页
    result = RoutineWizardResult(
      category: initialCategory,
      name: _defaultRoutineName(initialCategory),
      params: const [],
    );
  } else {
    final picked = await showDialog<RoutineWizardResult>(
      context: context,
      builder: (_) => FunctionWizardDialog(
        connection: connection,
        database: database,
        typeId: typeId,
        initialCategory: initialCategory,
      ),
    );
    if (picked == null) return; // 用户取消
    result = picked;
  }

  // 同步对象浏览上下文到新建的分类,并打开新建设计页
  app.setObjectContext(connection, database,
      category: result.category, schema: schema);
  app.designRoutine(
    result.name,
    connection: connection,
    database: database,
    category: result.category,
    schema: schema,
    isNew: true,
    params: RoutineSql.signature(typeId, result.params),
  );
}

int _routineNameCounter = 0;

String _defaultRoutineName(ObjectCategory category) {
  _routineNameCounter++;
  return category == ObjectCategory.procedure
      ? 'procedure_$_routineNameCounter'
      : 'function_$_routineNameCounter';
}

/// 「函数向导」两步对话框:
/// 第 1 步:选择例程类型(过程 / 函数)+ 输入名称;
/// 第 2 步:编辑参数列表(模式 / 名称 / 数据类型,可增删)。
/// 底部为 上一步 / 下一步 / 完成 / 取消,左下角「下次显示向导」复选。
class FunctionWizardDialog extends StatefulWidget {
  const FunctionWizardDialog({
    super.key,
    required this.connection,
    required this.database,
    required this.typeId,
    this.initialCategory = ObjectCategory.function,
  });

  /// 所属连接名(仅用于对话框副标题展示)
  final String connection;

  /// 所属数据库
  final String database;

  /// 数据库类型 id(决定参数模式候选与模板方言)
  final String typeId;

  /// 初始选中的例程类型(入口按钮决定,用户可改)
  final ObjectCategory initialCategory;

  /// 「下次显示向导」标记:勾选后本会话内新建入口跳过向导直接打开设计页。
  /// (未持久化,重启后恢复默认显示向导)
  static bool skipNext = false;

  @override
  State<FunctionWizardDialog> createState() => _FunctionWizardDialogState();
}

class _FunctionWizardDialogState extends State<FunctionWizardDialog> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  /// 当前步骤(0 = 类型与名称,1 = 参数)
  int _step = 0;

  /// 选中的例程类型(默认随入口,用户可切换)
  ObjectCategory _category = ObjectCategory.function;

  /// 参数列表(第 2 步编辑)
  final List<RoutineParam> _params = [];

  /// 「下次显示向导」勾选态
  bool _skipNext = false;

  List<String> get _modes => RoutineSql.modesOf(widget.typeId);

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    // 类型不支持过程时回退到函数
    if (_category == ObjectCategory.procedure &&
        !RoutineSql.supportsProcedure(widget.typeId)) {
      _category = ObjectCategory.function;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String get _name => _nameController.text.trim();

  bool get _canFinish => _name.isNotEmpty;

  void _finish() {
    if (!_canFinish) return;
    FunctionWizardDialog.skipNext = _skipNext;
    Navigator.of(context).pop(RoutineWizardResult(
      category: _category,
      name: _name,
      params: List<RoutineParam>.from(_params),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '函数向导',
      width: 560,
      height: _step == 0 ? null : 380,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          CheckBox(
            value: _skipNext,
            onChanged: (v) => setState(() => _skipNext = v ?? false),
            label: '下次显示向导',
          ),
          const Spacer(),
          Button(
            text: '< 上一步',
            onPressed: _step > 0 ? () => setState(() => _step = 0) : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '下一步 >',
            onPressed: _step == 0
                ? () => setState(() => _step = 1)
                : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '完成',
            onPressed: _canFinish ? _finish : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '取消',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
        child: _step == 0 ? _stepType(t) : _stepParams(t),
      ),
    );
  }

  // ── 第 1 步:类型与名称 ──────────────────────────────────

  Widget _stepType(AppPalette t) {
    final canProcedure = RoutineSql.supportsProcedure(widget.typeId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '请选择你要创建的例程类型',
          style: TextStyle(
            fontSize: 13,
            color: t.accent,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 16),
        FieldRow(
          label: '名称:',
          child: SizedBox(
            width: 320,
            child: Input(
              controller: _nameController,
              focusNode: _nameFocus,
              hint: '例程名称',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canFinish) _finish();
              },
              textInputAction: TextInputAction.done,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            children: [
              RadioButton<ObjectCategory>(
                value: ObjectCategory.procedure,
                groupValue: _category,
                enabled: canProcedure,
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
                label: '过程',
              ),
              const SizedBox(width: 24),
              RadioButton<ObjectCategory>(
                value: ObjectCategory.function,
                groupValue: _category,
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
                label: '函数',
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (!canProcedure)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '当前数据库类型(${widget.typeId})不支持存储过程',
              style: TextStyle(fontSize: 11, color: t.mutedForeground),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '创建位置:${widget.connection} · ${widget.database}',
          style: TextStyle(fontSize: 11.5, color: t.mutedForeground),
        ),
      ],
    );
  }

  // ── 第 2 步:参数列表 ────────────────────────────────────

  Widget _stepParams(AppPalette t) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '编辑 ${_category.labelOf(context.l10n)} ${_name.isNotEmpty ? '«$_name»' : ''} 的参数列表',
          style: TextStyle(
            fontSize: 13,
            color: t.accent,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        // 表头
        Row(
          children: [
            SizedBox(width: 96, child: _headCell(t, '模式')),
            SizedBox(width: 150, child: _headCell(t, '名称')),
            SizedBox(width: 170, child: _headCell(t, '数据类型')),
            const SizedBox(width: 40),
          ],
        ),
        const SizedBox(height: 4),
        // 参数行
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < _params.length; i++)
                  _paramRow(t, i),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Button(
          text: '添加参数',
          onPressed: () => setState(() {
            _params.add(RoutineParam(mode: _modes.first));
          }),
        ),
      ],
    );
  }

  Widget _headCell(AppPalette t, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
          ),
        ),
      );

  Widget _paramRow(AppPalette t, int index) {
    final p = _params[index];
    return _ParamRow(
      key: ValueKey(p),
      param: p,
      modes: _modes,
      nameHint: _nameHint,
      onDelete: () => setState(() => _params.removeAt(index)),
    );
  }

  String get _nameHint => widget.typeId == 'sqlserver' ? '@参数名' : '参数名';
}

/// 单行参数编辑:自持 controller(仅创建一次),修改实时写回 [param]。
/// 以参数实例身份作为 [Key]:删除中间行不会错位复用其它行的输入状态。
class _ParamRow extends StatefulWidget {
  const _ParamRow({
    super.key,
    required this.param,
    required this.modes,
    required this.nameHint,
    required this.onDelete,
  });

  final RoutineParam param;
  final List<String> modes;
  final String nameHint;
  final VoidCallback onDelete;

  @override
  State<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends State<_ParamRow> {
  late final TextEditingController _nameController;
  late final TextEditingController _typeController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.param.name);
    _typeController = TextEditingController(text: widget.param.type);
    // 写入时同步回参数对象(父级重建时以参数为准)
    _nameController.addListener(() => widget.param.name = _nameController.text);
    _typeController.addListener(() => widget.param.type = _typeController.text);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _typeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: ComboBox<String>(
              items: widget.modes,
              value: widget.param.mode,
              itemToString: (v) => v.isEmpty ? '普通' : v,
              onChanged: (v) {
                if (v == null) return;
                setState(() => widget.param.mode = v);
              },
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 150,
            child: Input(
              controller: _nameController,
              hint: widget.nameHint,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 170,
            child: Input(
              controller: _typeController,
              hint: '如 INT / VARCHAR(50)',
            ),
          ),
          const SizedBox(width: 4),
          IconBtn(
            icon: Icons.delete_outline,
            iconSize: 15,
            color: const Color(0xffd93025),
            tooltip: '删除参数',
            onTap: widget.onDelete,
          ),
        ],
      ),
    );
  }
}
