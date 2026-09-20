import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mysql_client/exception.dart';

import 'package:daro/data/drivers/mysql_driver.dart';

/// 钉住 PR#6 review 结论:mysql_client 0.0.27 建连超时报的是 TimeoutException
/// (非 SocketException 子类),若落入 catch-all 会被误判「TLS 不可用」→
/// 明文重试再等满一轮超时(防火墙 drop 端口时总等待翻倍)。
void main() {
  group('mysqlTlsUnavailable 回退判定', () {
    test('超时不回退(TimeoutException 与主机不可达同理)', () {
      expect(
          mysqlTlsUnavailable(
              TimeoutException(null, const Duration(seconds: 10))),
          isFalse);
    });

    test('服务端明确应答不重试', () {
      expect(
          mysqlTlsUnavailable(
              const MySQLServerException('Access denied', 1045)),
          isFalse);
    });

    test('RST 类主机不可达不重试', () {
      expect(
          mysqlTlsUnavailable(SocketException(
              'Connection refused', address: InternetAddress.loopbackIPv4)),
          isFalse);
    });

    test('认证插件不匹配不重试(换明文解决不了)', () {
      expect(
          mysqlTlsUnavailable(const MySQLClientException(
              'Auth plugin caching_sha2_password is supported only '
              'with secure connections')),
          isFalse);
      expect(
          mysqlTlsUnavailable(const MySQLClientException(
              'Unsupported auth plugin name client_ed25519')),
          isFalse);
    });

    test('「Server does not support SSL」等库内客户端错误允许回退', () {
      expect(
          mysqlTlsUnavailable(
              const MySQLClientException('Server does not support SSL '
                  'connection, but ssl is requested')),
          isTrue);
    });

    test('TLS 握手 / 连接重置类 IO 异常按 TLS 不可用处理', () {
      expect(
          mysqlTlsUnavailable(const HandshakeException(
              'Handshake error in client', OSError('bad record mac', 0))),
          isTrue);
      // 握手期服务端直接断开:ConnectionResetException extends IOException,
      // 不是 SocketException 子类,走 catch-all 回退
      expect(
          mysqlTlsUnavailable(const FileSystemException(
              'Connection reset by peer')), // IOException 兜底代表
          isTrue);
    });
  });
}
