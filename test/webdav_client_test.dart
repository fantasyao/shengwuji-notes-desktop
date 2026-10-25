import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/sync/webdav_client.dart';
import 'package:shengwuji_desktop/sync/webdav_request_counter.dart';

/// 模拟对父目录不存在时返回 409 的 WebDAV 服务（坚果云等）。
void main() {
  late HttpServer server;
  late WebDavClient client;
  late WebDavRequestCounter counter;
  final dirs = <String>{};
  final files = <String, List<int>>{};

  setUp(() async {
    dirs.clear();
    files.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final parent = path.substring(0, path.lastIndexOf('/'));
      switch (request.method) {
        case 'MKCOL':
          if (parent.isNotEmpty && !dirs.contains(parent)) {
            request.response.statusCode = 409;
          } else if (dirs.contains(path)) {
            request.response.statusCode = 405;
          } else {
            dirs.add(path);
            request.response.statusCode = 201;
          }
        case 'PUT':
          if (parent.isNotEmpty && !dirs.contains(parent)) {
            request.response.statusCode = 409;
          } else {
            files[path] = await request.fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
            request.response.statusCode = 201;
          }
        case 'GET':
          final data = files[path];
          if (data == null) {
            request.response.statusCode = 404;
          } else {
            request.response.add(data);
          }
        case 'PROPFIND':
          if (request.headers.value('Depth') == '0') {
            final data = files[path];
            if (data == null) {
              request.response.statusCode = 404;
              break;
            }
            request.response.statusCode = 207;
            request.response.headers.contentType = ContentType(
              'application',
              'xml',
              charset: 'utf-8',
            );
            request.response.write(
              '<?xml version="1.0"?>'
              '<d:multistatus xmlns:d="DAV:"><d:response>'
              '<d:href>$path</d:href><d:propstat><d:prop>'
              '<d:getetag>"v${data.length}"</d:getetag>'
              '<d:getlastmodified>Mon, 20 Oct 2026 10:00:00 GMT'
              '</d:getlastmodified>'
              '</d:prop></d:propstat></d:response></d:multistatus>',
            );
          } else {
            request.response.statusCode = 207;
            request.response.headers.contentType = ContentType(
              'application',
              'xml',
              charset: 'utf-8',
            );
            request.response.write(
              '<?xml version="1.0"?>'
              '<d:multistatus xmlns:d="DAV:"></d:multistatus>',
            );
          }
        default:
          request.response.statusCode = 405;
      }
      await request.response.close();
    });
    counter = WebDavRequestCounter(clock: () => DateTime(2026, 10, 25, 10));
    client = WebDavClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: 'u',
      password: 'p',
      remoteDir: '/shengwuji_sync',
      requestCounter: counter,
    );
  });

  tearDown(() async {
    await client.close();
    counter.dispose();
    await server.close(force: true);
  });

  test('每次 HTTP 请求都计入本机请求预算', () async {
    expect(counter.recentCount, 0);

    await client.ping();
    expect(counter.recentCount, 1);

    await client.stat('manifest.json');
    expect(counter.recentCount, 2);
  });

  test('写入嵌套路径时自动创建父目录', () async {
    await client.ensureDirectory();

    await client.write('v2/notes.json', utf8.encode('{"notes":[]}'));

    expect(files.containsKey('/shengwuji_sync/v2/notes.json'), isTrue);
    expect(
      utf8.decode(files['/shengwuji_sync/v2/notes.json']!),
      '{"notes":[]}',
    );
  });

  test('父目录被外部删除后写入会重建并重试', () async {
    await client.ensureDirectory();
    dirs.remove('/shengwuji_sync');

    await client.write('v2/notes.json', utf8.encode('{}'));

    expect(dirs, contains('/shengwuji_sync/v2'));
    expect(files.containsKey('/shengwuji_sync/v2/notes.json'), isTrue);
  });

  test('读取远端版本信息用于轮询，缺失文件返回 null', () async {
    await client.ensureDirectory();
    await client.write('manifest.json', utf8.encode('{}'));

    final stat = await client.stat('manifest.json');
    expect(stat, isNotNull);
    expect(stat!.etag, '"v2"');
    expect(stat.revision, 'etag:"v2"');
    expect(stat.lastModified, 'Mon, 20 Oct 2026 10:00:00 GMT');

    expect(await client.stat('missing.json'), isNull);
  });
}
