
/// 连接配置模型(持久化单元)。
///
/// 连接由用户通过连接向导创建,经 [ConnectionStore] 持久化到本地,
/// 启动时由 `AppState` 加载进内存。
///
/// [isLive] 为 true 的连接走真实驱动([DatabaseDriver])加载元数据
class ConnectionInfo {
  const ConnectionInfo({
    required this.name,
    required this.typeId,
    required this.host,
    required this.port,
    required this.username,
    this.password = '',
    this.database = '',
    this.authMethod = '',
    this.isLive = false,
  });

  /// 显示名(连接名称)
  final String name;

  /// 数据库类型 id(见 [db_types.dart] 的 DbType.id)
  final String typeId;

  final String host;
  final String port;
  final String username;

  /// 密码(向导「保存密码」勾选时暂存于内存)
  final String password;

  /// 默认数据库(可为空,空则连接后先列出所有库)
  final String database;

  /// 验证方式(目前仅 SQL Server 使用:'sql' = SQL Server 身份验证,
  /// 'windows' = Windows 身份验证;空串等同于 'sql')
  final String authMethod;

  /// 是否为真实连接(通过连接向导创建),走真实驱动加载元数据
  final bool isLive;

  /// 拷贝一份配置,可覆盖任意字段(复制连接 / 编辑连接时用)
  ConnectionInfo copyWith({
    String? name,
    String? typeId,
    String? host,
    String? port,
    String? username,
    String? password,
    String? database,
    String? authMethod,
    bool? isLive,
  }) =>
      ConnectionInfo(
        name: name ?? this.name,
        typeId: typeId ?? this.typeId,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        database: database ?? this.database,
        authMethod: authMethod ?? this.authMethod,
        isLive: isLive ?? this.isLive,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'typeId': typeId,
        'host': host,
        'port': port,
        'username': username,
        // 未勾选「保存密码」时 password 为空串,不会落盘敏感信息
        'password': password,
        'database': database,
        'authMethod': authMethod,
        'isLive': isLive,
      };

  factory ConnectionInfo.fromJson(Map<String, dynamic> json) =>
      ConnectionInfo(
        name: json['name'] as String? ?? '',
        typeId: json['typeId'] as String? ?? '',
        host: json['host'] as String? ?? 'localhost',
        port: json['port'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        database: json['database'] as String? ?? '',
        authMethod: json['authMethod'] as String? ?? '',
        isLive: json['isLive'] as bool? ?? true,
      );
}
