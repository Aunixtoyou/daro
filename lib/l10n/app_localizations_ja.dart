// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get langFollowSystem => 'システムに従う';

  @override
  String get optionsTitle => 'オプション';

  @override
  String get optionsGeneral => '一般';

  @override
  String get optionsLanguage => '言語';

  @override
  String get optionsLanguageHint => '切り替えは即時反映され、表示中の画面も一緒に切り替わります。';

  @override
  String get themeMenuTitle => 'テーマ';

  @override
  String get themeFollowSystem => 'システムに従う';

  @override
  String get themeLight => 'ライト';

  @override
  String get themeDark => 'ダーク';

  @override
  String themeSwitchTooltip(String mode) {
    return 'テーマ：$mode（クリックで切替）';
  }

  @override
  String get menuFile => 'ファイル';

  @override
  String get menuNewConnection => '新しい接続...';

  @override
  String get menuNewQuery => '新しいクエリ';

  @override
  String get menuImportConnections => '接続のインポート';

  @override
  String get menuExportConnections => '接続のエクスポート';

  @override
  String get menuExit => '終了';

  @override
  String get menuView => '表示';

  @override
  String get menuRefresh => '更新';

  @override
  String get menuThemeCustomize => 'テーマのカスタマイズ...';

  @override
  String get menuLargeIcons => '大きいアイコン';

  @override
  String get menuSmallIcons => '小さいアイコン';

  @override
  String get menuList => '一覧';

  @override
  String get menuDetails => '詳細情報';

  @override
  String get menuTools => 'ツール';

  @override
  String get menuCommandLine => 'コマンドライン...';

  @override
  String get menuDataTransfer => 'データ転送...';

  @override
  String get menuDataSync => 'データ同期...';

  @override
  String get menuSchemaSync => '構造同期...';

  @override
  String get menuBackup => 'バックアップ...';

  @override
  String get menuRestoreBackup => 'バックアップの復元...';

  @override
  String get menuMcpService => 'MCP サービス...';

  @override
  String get menuOptions => 'オプション...';

  @override
  String get menuHelp => 'ヘルプ';

  @override
  String get menuIssueTracker => '問題の報告';

  @override
  String get menuAbout => '情報表示...';

  @override
  String get catTable => 'テーブル';

  @override
  String get catView => 'ビュー';

  @override
  String get catMaterializedView => 'マテリアライズドビュー';

  @override
  String get catFunction => '関数';

  @override
  String get catProcedure => 'ストアドプロシージャ';

  @override
  String get catRole => 'ロール';

  @override
  String get catQuery => 'クエリ';

  @override
  String get catBackup => 'バックアップ';

  @override
  String get importDoneTitle => 'インポート完了';

  @override
  String importDoneMessage(String count) {
    return '$count 件の接続をインポートしました。左の接続ツリーで確認できます。';
  }

  @override
  String importDoneManualPassword(String count) {
    return 'そのうち $count 件はパスワードを引き継げませんでした（Navicat 側に保存されていないか、古い暗号化方式です）。対象の接続を右クリック →「接続の編集」で補入力してください。';
  }

  @override
  String importDoneNewGroups(String count, String names) {
    return 'ローカルに存在しないグループ $count 件を作成しました：$names。';
  }

  @override
  String get exportDoneTitle => 'エクスポート完了';

  @override
  String exportDoneMessage(String count, String path) {
    return '$count 件の接続を\n$path\nにエクスポートしました。Navicat で「ファイル → 接続設定のインポート…」からこのファイルを選んでください。';
  }

  @override
  String exportDoneSkipped(String names) {
    return '対応する種類の接続がないためエクスポートされませんでした：$names。';
  }

  @override
  String listEllipsisMore(String count) {
    return ' など $count 件';
  }

  @override
  String get listEllipsis => ' など';

  @override
  String get listSeparator => '、';

  @override
  String get issueTrackerTitle => '問題の報告';

  @override
  String issueTrackerOpenFailed(String url) {
    return 'ブラウザを自動的に開けませんでした。次に手動でアクセスしてください：\n$url';
  }

  @override
  String get ribbonConnection => '接続';

  @override
  String get ribbonNewQuery => '新しいクエリ';

  @override
  String get tabObjects => 'オブジェクト';

  @override
  String get tabDesignSuffix => '（設計）';

  @override
  String get tabNewSuffix => '（新規）';

  @override
  String get tabCommandLine => 'コマンドライン';

  @override
  String get tabCtxClose => '閉じる';

  @override
  String get tabCtxCloseOthers => '他のタブを閉じる';

  @override
  String get tabCtxCloseRight => '右側のタブを閉じる';

  @override
  String get tabCtxCloseAll => 'すべて閉じる';

  @override
  String get statusNoDatabase => 'データベースが選択されていません';

  @override
  String statusRecordPosition(String current, String total, String page) {
    return 'レコード $current / 全 $total 件、$page ページ目';
  }

  @override
  String statusSelectedRows(String count, String total, String page) {
    return '$count 行を選択中（全 $total 件、$page ページ目）';
  }

  @override
  String statusObjectsSelected(String count) {
    return '$count 項目を選択中';
  }

  @override
  String get tipDetailedLayout => '詳細レイアウト';

  @override
  String get tipListLayout => '一覧';

  @override
  String get tipLeftPanel => '左パネル';

  @override
  String get tipRightPanel => '右パネル';

  @override
  String sqlHistoryTitle(String count) {
    return 'SQL 実行履歴（$count）';
  }

  @override
  String get sqlHistoryLatest => '最新';

  @override
  String get mcpTipDisabled => 'MCP サービスは無効です（クリックして設定を開く）';

  @override
  String get mcpTipCorrupted => 'MCP ポリシーの読み込みに失敗しました（クリックして詳細を表示）';

  @override
  String get mcpTipIdle => 'MCP サービスは有効ですが待機していません（クリックして設定を開く）';

  @override
  String get mcpTipRunning => 'MCP サービスは実行中です（クリックして設定を開く）';

  @override
  String mcpTipRunningCalls(String count) {
    return 'MCP 実行中（$count 件の呼び出し）';
  }

  @override
  String get infoPickNode => '左の接続ツリーでノードを選択すると詳細が表示されます';

  @override
  String get infoSectionDatabase => 'データベース';

  @override
  String get infoSectionConnection => '接続';

  @override
  String get infoSectionSchema => 'スキーマ';

  @override
  String get infoSectionConnGroup => '接続グループ';

  @override
  String get infoSectionTable => 'テーブル';

  @override
  String get fieldConnection => '接続';

  @override
  String get fieldType => 'タイプ';

  @override
  String get fieldHost => 'ホスト';

  @override
  String get fieldUser => 'ユーザー';

  @override
  String get fieldDatabase => 'データベース';

  @override
  String get fieldSchema => 'スキーマ';

  @override
  String get fieldConnCount => '接続数';

  @override
  String get infoGroupEmpty =>
      'グループは空です。接続を右クリック →「グループへ移動」で追加するか、このグループを削除してください。';

  @override
  String get infoTableDoubleClickHint => 'テーブルをダブルクリックすると先頭 100 行を表示します';

  @override
  String get fieldCharset => '文字セット';

  @override
  String get fieldCollation => '照合順序';

  @override
  String get fieldRows => '行数';

  @override
  String get fieldEngine => 'エンジン';

  @override
  String get fieldAutoIncrement => '自動採番';

  @override
  String get fieldRowFormat => '行フォーマット';

  @override
  String get fieldCreateTime => '作成日';

  @override
  String get fieldUpdateTime => '更新日';

  @override
  String get fieldCheckTime => 'チェック日時';

  @override
  String get fieldDataLength => 'データ長';

  @override
  String get fieldIndexLength => 'インデックス長';

  @override
  String get fieldMaxDataLength => '最大データ長';

  @override
  String get fieldDataFree => '空き領域';

  @override
  String get fieldCreateOptions => '作成オプション';

  @override
  String get fieldComment => 'コメント';

  @override
  String infoRowCountEstimate(String count) {
    return '$count (概算)';
  }

  @override
  String get infoFetchRowCount => '行数を取得';

  @override
  String get infoFetchingRowCount => '集計中...';

  @override
  String infoRowCountFailed(String error) {
    return '集計に失敗しました: $error';
  }

  @override
  String get infoShare => '共有';

  @override
  String get infoShareTooltip => 'このオブジェクトの参照テキストをクリップボードにコピー';

  @override
  String get infoShareCopied => 'コピーしました';

  @override
  String get infoPageInfo => '情報';

  @override
  String get infoPageDdl => 'DDL';

  @override
  String get fieldOid => 'OID';

  @override
  String get fieldOwner => 'オーナー';

  @override
  String get fieldTablespace => 'テーブル空間';

  @override
  String get fieldEncoding => 'エンコーディング';

  @override
  String get fieldLcCollate => '照合順序';

  @override
  String get fieldConnectionLimit => '接続制限';

  @override
  String get infoValueNoLimit => '無制限';

  @override
  String get fieldTableType => 'Table Type';

  @override
  String get tableTypeRegular => '通常';

  @override
  String get tableTypePartitioned => 'パーティションテーブル';

  @override
  String get tableTypeView => 'ビュー';

  @override
  String get tableTypeMatView => 'マテリアライズドビュー';

  @override
  String get tableTypeForeign => '外部テーブル';

  @override
  String get fieldPartitionOf => 'パーティション所属';

  @override
  String get fieldInheritsFrom => 'Inherits From';

  @override
  String get fieldHasOids => 'Has OIDs';

  @override
  String get fieldFillFactor => 'フィルファクタ';

  @override
  String get fieldAcl => 'ACL';

  @override
  String get infoValueYes => 'はい';

  @override
  String get infoValueNo => 'いいえ';

  @override
  String get infoPageUses => '使用';

  @override
  String get infoPageUsedBy => '使用元';

  @override
  String get infoPageUsesTooltip => 'このテーブルが参照するオブジェクト';

  @override
  String get infoPageUsedByTooltip => 'このテーブルを参照するオブジェクト';

  @override
  String get infoDepsLoading => '依存関係を読み込み中…';

  @override
  String get infoDepsEmpty => '依存オブジェクトはありません';

  @override
  String infoDepsFailed(String error) {
    return '依存関係の読み取りに失敗:$error';
  }

  @override
  String get infoMaximizePanel => '詳細パネルを広げる';

  @override
  String get infoRestorePanel => 'パネル幅に戻す';

  @override
  String infoDetailFailed(String error) {
    return '詳細を取得できません: $error';
  }

  @override
  String get infoDdlLoading => '定義を読み込み中...';

  @override
  String get infoDdlUnsupported => 'このデータベース種別は CREATE 文を表示できません。';

  @override
  String infoDdlFailed(String error) {
    return 'DDL を取得できません: $error';
  }

  @override
  String get infoCopyDdl => 'CREATE 文をコピー';

  @override
  String actionOpen(String label) {
    return '$labelを開く';
  }

  @override
  String actionDesign(String label) {
    return '$labelを設計';
  }

  @override
  String actionNew(String label) {
    return '$labelを新規作成';
  }

  @override
  String actionDelete(String label) {
    return '$labelを削除';
  }

  @override
  String get tableKindRegular => '通常';

  @override
  String get tableKindExternal => '外部';

  @override
  String get tableKindPartition => 'パーティション';

  @override
  String get importWizard => 'インポートウィザード';

  @override
  String get exportWizard => 'エクスポートウィザード';

  @override
  String actionClear(String label) {
    return '$labelをクリア';
  }

  @override
  String clearConfirmOne(String label, String name) {
    return '$label「$name」をクリアしますか?\nすべての行が削除されます(構造は保持され)、元に戻せません。';
  }

  @override
  String clearFailedDetail(String error) {
    return 'クリアできませんでした:\n$error';
  }

  @override
  String get btnClear => 'クリア';

  @override
  String get ctxCopyRename => 'コピー / 名前変更';

  @override
  String get btnGotIt => 'OK';

  @override
  String get btnDelete => '削除';

  @override
  String get btnPaste => '貼り付け';

  @override
  String get btnRetry => '再試行';

  @override
  String stubWip(String action) {
    return '$actionは現在開発中です';
  }

  @override
  String get deleteQueryTitle => 'クエリを削除';

  @override
  String deleteQueryConfirmOne(String name) {
    return 'クエリ「$name」を削除しますか?\n後に再保存できますが開いているクエリページには影響しません。';
  }

  @override
  String deleteQueryConfirmMany(String count) {
    return '$count 個の選択したクエリを削除しますか?';
  }

  @override
  String deleteObjectConfirmOne(String label, String name) {
    return '$label「$name」を削除しますか?\nこの操作は取り消せず、オブジェクトは完全に削除されます。';
  }

  @override
  String deleteObjectConfirmMany(String count, String label) {
    return '選択した $count 個の$labelを削除しますか?\nこの操作は取り消せず、オブジェクトは完全に削除されます。';
  }

  @override
  String deleteFailedDetail(String error) {
    return '削除できません:\n$error';
  }

  @override
  String loadingObjectsTitle(String database) {
    return '$database のオブジェクト一覧を読み込んでいます ...';
  }

  @override
  String openDatabaseFailedTitle(String database) {
    return '$database を開けません';
  }

  @override
  String categoryListFailedTitle(String label) {
    return '$label一覧を取得できません';
  }

  @override
  String get colName => '名前';

  @override
  String get colRowsEstimated => '行数（推定）';

  @override
  String get colComment => 'コメント';

  @override
  String rowsApprox(String value, String unit) {
    return '約$value$unit';
  }

  @override
  String get rowsUnitSmall => '万';

  @override
  String get rowsUnitLarge => '億';

  @override
  String get renameTableTitle => 'テーブルの名前変更';

  @override
  String renameFailedDetail(String error) {
    return '名前を変更できません:\n$error';
  }

  @override
  String copiedTables(String count) {
    return '$count 個のテーブルをコピーしました。Ctrl+V でコピーを貼り付け';
  }

  @override
  String pasteNeedOpenConnection(String connection) {
    return '貼り付けの前に接続「$connection」を開いてください。';
  }

  @override
  String pasteWrongContext(String context) {
    return '貼り付けはコピー元と同じ接続 / データベース / スキーマにのみ可能です:\n$context';
  }

  @override
  String get pasteTableTitle => 'テーブルの貼り付け';

  @override
  String pasteConfirmDetail(String count, String plan) {
    return '$count 個のテーブル(構造 + データ)を作成します:\n$plan';
  }

  @override
  String pastedTables(String count) {
    return '$count 個のテーブルを貼り付けました';
  }

  @override
  String pasteFailedDetail(String detail) {
    return '貼り付けに失敗しました:\n$detail';
  }

  @override
  String get catTablePlural => 'テーブル';

  @override
  String get catViewPlural => 'ビュー';

  @override
  String get catMaterializedViewPlural => 'マテリアライズドビュー';

  @override
  String get catFunctionPlural => '関数';

  @override
  String get catProcedurePlural => 'プロシージャ';

  @override
  String get newExternalTable => '外部テーブルを新規作成';

  @override
  String get newPartitionTable => 'パーティションテーブルを新規作成';

  @override
  String openedConnection(String name) {
    return '接続「$name」を開きました';
  }

  @override
  String openedDatabase(String name) {
    return 'データベース「$name」を開きました';
  }

  @override
  String openedSchema(String name) {
    return 'スキーマ「$name」を開きました';
  }

  @override
  String get openedBare => '開きました';

  @override
  String get closedBare => '閉じました';

  @override
  String closedConnection(String name) {
    return '接続「$name」を閉じました';
  }

  @override
  String closedSchema(String name) {
    return 'スキーマ「$name」を閉じました';
  }

  @override
  String closedDatabase(String name) {
    return 'データベース「$name」を閉じました';
  }

  @override
  String openedNamed(String name) {
    return '「$name」を開きました';
  }

  @override
  String closedNamed(String name) {
    return '「$name」を閉じました';
  }

  @override
  String renamedConnection(String newName, String oldName) {
    return '接続「$oldName」を「$newName」に名前変更しました';
  }

  @override
  String renamedTable(String newName, String oldName) {
    return 'テーブル「$oldName」を「$newName」に名前変更しました';
  }

  @override
  String movedConnectionToUngrouped(String name) {
    return '接続「$name」を無グループへ移動しました';
  }

  @override
  String movedConnectionToGroup(String group, String name) {
    return '接続「$name」をグループ「$group」に入れました';
  }

  @override
  String get unnamedGroup => '無題グループ';

  @override
  String unnamedGroupNumbered(String index) {
    return '無題グループ $index';
  }

  @override
  String get renameGroupTitle => 'グループ名の変更';

  @override
  String groupAlreadyExists(String name) {
    return '「$name」というグループは既にあります(大文字小文字は区別しません)。';
  }

  @override
  String get ctxOpenConnection => '接続を開く';

  @override
  String get ctxCloseConnection => '接続を閉じる';

  @override
  String get ctxOpen => '開く';

  @override
  String get ctxClose => '閉じる';

  @override
  String get ctxRefresh => '更新';

  @override
  String get ctxNewDatabase => 'データベースを新規作成';

  @override
  String get ctxEditConnection => '接続を編集';

  @override
  String get ctxCopyConnection => '接続をコピー';

  @override
  String get ctxMoveToGroup => 'グループへ移動';

  @override
  String get ctxUngrouped => '無グループ';

  @override
  String get ctxNewGroup => 'グループを新規作成';

  @override
  String get ctxDeleteConnection => '接続を削除';

  @override
  String get ctxNewConnectionEllipsis => '新規接続…';

  @override
  String get ctxRenameGroup => 'グループ名の変更';

  @override
  String get ctxDeleteGroup => 'グループを削除';

  @override
  String ctxDeleteGroupWith(String count) {
    return 'グループを削除（接続 $count 件）';
  }

  @override
  String deleteGroupConfirm(String count, String group) {
    return 'グループ「$group」を削除しても接続 $count 件は削除されず、無グループに戻ります。続行しますか?';
  }

  @override
  String get btnCancel => 'キャンセル';

  @override
  String get btnSave => '保存';

  @override
  String get ctxNewSchema => 'スキーマを新規作成';

  @override
  String get ctxDelete => '削除';

  @override
  String get ctxEditDatabase => 'データベースを編集';

  @override
  String get ctxNewQuery => 'クエリを新規作成';

  @override
  String get ctxDumpSql => 'SQL ファイルにエクスポート';

  @override
  String get ctxStructureOnly => '構造のみ';

  @override
  String get ctxRunSql => 'SQL ファイルを実行';

  @override
  String get ctxCloseSchema => 'スキーマを閉じる';

  @override
  String get ctxOpenSchema => 'スキーマを開く';

  @override
  String get ctxEditSchema => 'スキーマを編集';

  @override
  String get ctxDeleteSchema => 'スキーマを削除';

  @override
  String deleteSchemaConfirm(String name) {
    return 'スキーマ「$name」を削除しますか?\nこのスキーマとその全オブジェクトが完全に削除され、元に戻せません。';
  }

  @override
  String get ctxNewTable => 'テーブルを新規作成';

  @override
  String get ctxNewFunction => '関数を新規作成';

  @override
  String get ctxNewProcedure => 'プロシージャを新規作成';

  @override
  String get deleteDatabaseTitle => 'データベースを削除';

  @override
  String deleteDatabaseConfirm(String name) {
    return 'データベース「$name」を削除しますか?\nこのデータベースとその全データが完全に削除され、元に戻せません。';
  }

  @override
  String get sqlFileTypeLabel => 'SQL ファイル';

  @override
  String get dumpStructureReadFailed =>
      '構造の読み取りに失敗しました:\nデータベースが使用できないか接続が閉じられています。接続を開いて再試行してください。';

  @override
  String dumpWriteFailed(String error) {
    return 'ファイルの書き込みに失敗しました:\n$error';
  }

  @override
  String dumpDatabaseDone(String name, String path) {
    return '「$name」の構造（構造のみ、データなし）を出力しました:\n$path';
  }

  @override
  String dumpSchemaDone(String name, String path) {
    return 'スキーマ「$name」の構造（構造のみ、データなし）を出力しました:\n$path';
  }

  @override
  String openConnectionUnsupported(String name, String type) {
    return '接続「$name」のデータベースタイプ（$type）には未対応のため開けません。';
  }

  @override
  String openConnectionFailed(String error, String name) {
    return '接続「$name」に失敗しました:\n$error';
  }

  @override
  String deleteConnectionConfirm(String name) {
    return '接続「$name」を削除しますか?\nこの接続のタブは残りますが、引き続き利用できません。';
  }

  @override
  String get noMatchingConnections => '一致する接続がありません';

  @override
  String get noConnectionsYet => '接続はまだありません';

  @override
  String get clickToolbarNewConnection => 'ツールバーの「接続」ボタンで新規作成できます';

  @override
  String get dropToUngroup => '離すと無グループに移動';

  @override
  String get driverNotImplemented => 'このタイプは未対応です(実装待ち)';

  @override
  String loadFailedDetail(String error) {
    return '読み込みに失敗しました: $error';
  }

  @override
  String get readFailed => '読み取り失敗';

  @override
  String get clickToRetry => 'クリックで再試行';

  @override
  String get searchConnectionsHint => '接続を検索...';

  @override
  String get dbTypeFilter => 'データベースタイプで絞り込み';

  @override
  String get notImplemented => '未実装';

  @override
  String get clearAllFilters => 'すべてクリア';

  @override
  String get collapseAll => 'すべて折りたたむ';

  @override
  String get cellEditorPickCell => 'まずセルを選択してください';

  @override
  String get btnCommitChanges => '変更を確定';

  @override
  String rowsCopiedToClipboard(String count) {
    return '$count 行をクリップボードにコピーしました';
  }

  @override
  String cellMenuSetNull(String count) {
    return '$count 個のセルを NULL に設定';
  }

  @override
  String cellMenuCopy(String count) {
    return '$count 個のセルをコピー';
  }

  @override
  String cellsCopiedToClipboard(String count) {
    return '$count 個のセルをクリップボードにコピーしました';
  }

  @override
  String cellsClearedToNull(String count, String action) {
    return '$count 個のセルを NULL に設定しました。「$action」または Ctrl+S で保存';
  }

  @override
  String get filterSourceBuilder => 'ビルダー';

  @override
  String get filterSourceText => 'テキスト';

  @override
  String get toolPanelFilter => '絞り込みと並び替え';

  @override
  String get toolPanelColumns => '列';

  @override
  String get toolPanelCellEditor => 'セルエディター';

  @override
  String get btnOk => 'OK';

  @override
  String get dtpTime => '時刻';

  @override
  String get dtpSelectTime => '時刻を選択';

  @override
  String get dtpHour => '時';

  @override
  String get dtpMinute => '分';

  @override
  String get dtpSecond => '秒';

  @override
  String get dtpWeekdayMon => '月';

  @override
  String get dtpWeekdayTue => '火';

  @override
  String get dtpWeekdayWed => '水';

  @override
  String get dtpWeekdayThu => '木';

  @override
  String get dtpWeekdayFri => '金';

  @override
  String get dtpWeekdaySat => '土';

  @override
  String get dtpWeekdaySun => '日';

  @override
  String get catRecord => 'レコード';

  @override
  String gridPagingFailed(String error) {
    return 'ページの読み込みに失敗しました: $error';
  }

  @override
  String get gridAlreadyLastPage => 'すでに最終ページです';

  @override
  String gridPageMissing(String page) {
    return '$page ページは存在しません';
  }

  @override
  String get gridDiscardTitle => '未保存の変更を破棄';

  @override
  String get gridDiscardConfirm => '未保存の変更があります。続行すると破棄されます。\n続行しますか?';

  @override
  String gridDeleteRowConfirm(String row) {
    return '$row 行目のレコードを削除しますか?\n';
  }

  @override
  String gridDeleteRowsConfirm(String count, String preview) {
    return '選択した $count 行を削除しますか?($preview)\n';
  }

  @override
  String get gridDeletePendingHint => '「変更を確定」または Ctrl+S で初めてデータベースに書き込まれます。';

  @override
  String get gridNothingToSave => '保存する変更はありません';

  @override
  String gridConnectionMissing(String connection) {
    return '接続 \"$connection\" が存在しません';
  }

  @override
  String gridDeleteRowError(String row, String error) {
    return '$row 行目の削除: $error';
  }

  @override
  String gridInsertRowError(String error) {
    return '行の追加: $error';
  }

  @override
  String gridUpdateRowError(String row, String error) {
    return '$row 行目の更新: $error';
  }

  @override
  String gridSavedRows(String count) {
    return '$count 行を保存しました';
  }

  @override
  String gridSaveFailed(String errors) {
    return '保存失敗: $errors';
  }

  @override
  String get gridSaveFailedTitle => '保存失敗';

  @override
  String get gridSortMethod => '並び替え方式';

  @override
  String get gridAddSortCriterion => '並び替え条件を追加';

  @override
  String get gridSortEmptyHint => '+ をクリックして並び替え条件を追加';

  @override
  String get gridReadingColumns => '列情報を読み込んでいます…';

  @override
  String get gridFilterEmptyHint =>
      '+ をクリックして絞り込み条件を追加。行を選択すると、行末に同級の条件(+)または括弧グループ(O+)を追加できます。';

  @override
  String get gridFilter => '絞り込み';

  @override
  String get gridAddFilterCriterion => '絞り込み条件を追加';

  @override
  String get gridMoveCriterionUp => '選択した条件を上に移動';

  @override
  String get gridMoveCriterionDown => '選択した条件を下に移動';

  @override
  String get gridNoValueNeeded => '(値不要)';

  @override
  String get gridAddSibling => 'この条件の後に同級の条件を追加';

  @override
  String get gridAddGroup => 'この条件の後に括弧グループを追加';

  @override
  String get gridDeleteFilterGroup => 'グループを削除';

  @override
  String get gridDeleteCriterion => '条件を削除';

  @override
  String get gridWhereHint =>
      'WHERE 句を除いて入力。例:id > 100 AND name LIKE \'Acme%\'';

  @override
  String get gridApplyFilterSort => '絞り込みと並び替えを適用';

  @override
  String get gridCriterionEdited => '条件を編集しました';

  @override
  String get gridAsc => '昇順';

  @override
  String get gridDesc => '降順';

  @override
  String get gridDeleteSortCriterion => '並び替え条件を削除';

  @override
  String gridColumnsCount(String visible, String total) {
    return '列 ($visible/$total)';
  }

  @override
  String get gridShowAllColumns => 'すべての列を表示';

  @override
  String get gridKeepFirstColumnOnly => '最初の列のみ保持';

  @override
  String get gridLoadingColumns => '列情報を読み込んでいます...';

  @override
  String get gridSearch => '検索';

  @override
  String get gridColumnName => '列名';

  @override
  String get cellNoneSelected => 'セルが選択されていません';

  @override
  String cellColumnIndex(String col) {
    return '$col 列目';
  }

  @override
  String cellRowIndex(String row) {
    return '  ·  $row 行目';
  }

  @override
  String cellEditorTitle(String title) {
    return 'セルエディター · $title';
  }

  @override
  String get btnApply => '適用';

  @override
  String get btnUndo => '元に戻す';

  @override
  String get cellEmptyValue => 'セルは空です';

  @override
  String get cellNotBase64Image => 'このセルは認識できる base64 画像データではありません';

  @override
  String get cellNotHtml => 'このセルの内容は HTML ソースコードではありません';

  @override
  String cellWrittenBack(String action) {
    return 'セルに書き戻しました。「$action」または Ctrl+S で保存';
  }

  @override
  String get cellMenuSetBlank => '空白文字列に設定';

  @override
  String get cellMenuSetNullCell => 'NULL に設定';

  @override
  String get gridSort => '並び替え';

  @override
  String gridSortAscBy(String column) {
    return '昇順($column)';
  }

  @override
  String gridSortDescBy(String column) {
    return '降順($column)';
  }

  @override
  String get gridClearSort => '並び替えを解除';

  @override
  String get gridMoreSorting => 'その他の並び替え...';

  @override
  String gridHideColumn(String column) {
    return '「$column」を非表示';
  }

  @override
  String get gridColumnsPanel => '列パネル...';

  @override
  String get gridMoreFilters => 'その他の絞り込み...';

  @override
  String get gridClearFilter => '絞り込みをクリア';

  @override
  String get gridRemoveAllSortFilter => 'すべての並び替えと絞り込みを削除';

  @override
  String get gridShow => '表示';

  @override
  String get gridShowAll => 'すべてのレコード';

  @override
  String get gridShowNullOnly => 'NULL の値のみ';

  @override
  String get gridShowNotNullOnly => 'NULL 以外の値のみ';

  @override
  String get gridClipboardEmpty => 'クリップボードは空です';

  @override
  String get gridClipboardNoRecords => 'クリップボードに貼り付け可能なレコードがありません';

  @override
  String gridPastedRows(String count) {
    return '$count 行を新規レコードとして貼り付けました(未保存)';
  }

  @override
  String get gridRowCountUnknown => '  ·  行数不明';

  @override
  String gridRowCount(String total) {
    return '  ·  $total 行';
  }

  @override
  String gridLoadingTable(String table) {
    return '$table を読み込んでいます...';
  }

  @override
  String gridReadTableFailed(String table) {
    return '$table の読み込みに失敗';
  }

  @override
  String get gridFilterDirty => '絞り込み / 並び替えに未適用の変更があります';

  @override
  String get gridFilterApplied => '絞り込み / 並び替えを適用しました';

  @override
  String get gridAddRecord => 'レコード追加';

  @override
  String get gridDeleteSelectedRecords => '選択したレコードを削除';

  @override
  String get gridSaving => '保存中...';

  @override
  String get gridRevertChanges => '変更取消';

  @override
  String get gridStop => '停止';

  @override
  String gridPagerRange(String from, String to, String total) {
    return '$from-$to / 全 $total 件';
  }

  @override
  String get gridPageSize => 'ページサイズ';

  @override
  String gridRowsPerPage(String size) {
    return '$size 行/ページ';
  }

  @override
  String get cliEmptyHint =>
      'SQL を入力して Enter キーで実行します。文の終わりはセミコロン。未完成ならそのまま続きを入力、↑ / ↓ で履歴を参照します。';

  @override
  String get cliInputHint => 'SQL 文を入力';
}
