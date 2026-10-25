import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'sync_exception.dart';
import 'webdav_request_counter.dart';

/// 远端文件内容与可用于判断“是否变过”的版本信息。
class RemoteFile {
  const RemoteFile({required this.bytes, this.etag, this.lastModified});

  final Uint8List bytes;
  final String? etag;
  final String? lastModified;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// 文件元信息；[revision] 可直接用来判断文件是否被外部改过。
class RemoteStat {
  const RemoteStat({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;

  String? get revision {
    final tag = etag;
    if (tag != null && tag.isNotEmpty) return 'etag:$tag';
    final modified = lastModified;
    if (modified != null && modified.isNotEmpty) return 'modified:$modified';
    return null;
  }
}

/// 同步层依赖的最小远端能力；测试用内存实现替换。
abstract class CloudStorage {
  /// 确认远端目录可用，不存在则创建。
  Future<void> ensureDirectory();

  /// 读文件；404 返回 null。
  Future<RemoteFile?> read(String path);

  /// 只读元信息（PROPFIND Depth 0），用于判断远端是否变过；404 返回 null。
  /// 服务端不支持 PROPFIND 时抛 [UnsupportedError]，调用方退回完整同步。
  Future<RemoteStat?> stat(String path);

  Future<void> write(
    String path,
    List<int> bytes, {
    String contentType = 'application/json; charset=utf-8',
  });

  Future<void> delete(String path);

  /// 列目录下的文件名；服务端不支持 PROPFIND 时返回 null。
  Future<Set<String>?> list(String path);

  /// 用一次轻量请求验证地址、账号与密码。
  Future<void> ping();

  Future<void> close();
}

/// WebDAV 实现。路径一律相对 [remoteDir]，由客户端负责拼接与编码。
class WebDavClient implements CloudStorage {
  WebDavClient({
    required String baseUrl,
    required this.username,
    required this.password,
    required String remoteDir,
    Dio? dio,
    this.requestCounter,
  }) : _baseUri = _parseBase(baseUrl),
       remoteDir = _normalizeDir(remoteDir),
       _dio = dio ?? Dio() {
    _dio.options = _dio.options.copyWith(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 120),
      receiveTimeout: const Duration(seconds: 120),
      validateStatus: (_) => true,
      headers: {
        'User-Agent': 'ShengwujiDesktop/0.1 WebDAV',
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      },
    );
  }

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getetag/><d:getlastmodified/>'
      '</d:prop></d:propfind>';

  final Uri _baseUri;
  final String username;
  final String password;
  final String remoteDir;
  final Dio _dio;

  /// 统计本机请求次数；为 null 时不计数。
  final WebDavRequestCounter? requestCounter;

  /// 本次连接已确认存在的目录（相对远端根），避免重复 MKCOL。
  final Set<String> _ensuredDirs = {};

  @override
  Future<void> ensureDirectory() async {
    await _ensureDir(_dirSegments());
  }

  /// 逐级创建 [segments]，已存在的目录（405 等）视为成功。
  ///
  /// 缓存的父目录可能已被外部删除，此时 MKCOL 会返回 409；清空缓存后重试一次。
  Future<void> _ensureDir(List<String> segments, {bool retry = true}) async {
    var prefix = <String>[];
    for (final segment in segments) {
      prefix = [...prefix, segment];
      final key = prefix.join('/');
      if (_ensuredDirs.contains(key)) continue;
      final response = await _request(
        'MKCOL',
        _uri(prefix),
        options: Options(
          headers: {'Content-Type': 'application/xml; charset=utf-8'},
        ),
      );
      final code = response.statusCode ?? 0;
      // 405 = 已经存在；301/302 交给 dio 跟随，最终也会落到存在或失败。
      if (code == 200 ||
          code == 201 ||
          code == 204 ||
          code == 301 ||
          code == 302 ||
          code == 405) {
        _ensuredDirs.add(key);
        continue;
      }
      if (code == 409 && retry) {
        _ensuredDirs.clear();
        return _ensureDir(segments, retry: false);
      }
      if (code == 409) {
        throw const SyncException('远端目录不存在，且无法自动创建');
      }
      throw _errorFor(code, '创建远端目录失败');
    }
  }

  @override
  Future<RemoteFile?> read(String path) async {
    final response = await _request(
      'GET',
      _uri([..._dirSegments(), ..._split(path)]),
      options: Options(responseType: ResponseType.bytes),
    );
    final code = response.statusCode ?? 0;
    if (code == 404) return null;
    if (code < 200 || code >= 300) {
      throw _errorFor(code, '读取远端文件失败');
    }
    final data = response.data;
    final bytes = data is Uint8List
        ? data
        : data is List<int>
        ? Uint8List.fromList(data)
        : Uint8List(0);
    return RemoteFile(
      bytes: bytes,
      etag: _header(response, 'etag'),
      lastModified: _header(response, 'last-modified'),
    );
  }

  @override
  Future<RemoteStat?> stat(String path) async {
    final response = await _request(
      'PROPFIND',
      _uri([..._dirSegments(), ..._split(path)]),
      data: _propfindBody,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 404) return null;
    if (code == 405 || code == 501) {
      throw UnsupportedError('服务端不支持 PROPFIND');
    }
    if (code != 207 && (code < 200 || code >= 300)) {
      throw _errorFor(code, '读取远端文件信息失败');
    }
    final text = response.data is List<int>
        ? utf8.decode(response.data as List<int>, allowMalformed: true)
        : '${response.data ?? ''}';
    return RemoteStat(
      etag: _xmlProp(text, 'getetag'),
      lastModified: _xmlProp(text, 'getlastmodified'),
    );
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    String contentType = 'application/json; charset=utf-8',
  }) async {
    final segments = [..._dirSegments(), ..._split(path)];
    final parent = segments.sublist(0, segments.length - 1);
    await _ensureDir(parent);

    var response = await _put(segments, bytes, contentType);
    var code = response.statusCode ?? 0;
    if (code == 409) {
      // 目录可能是刚被外部删掉或服务端未及时生效，重建父目录后重试一次。
      _ensuredDirs.clear();
      await _ensureDir(parent);
      response = await _put(segments, bytes, contentType);
      code = response.statusCode ?? 0;
    }
    if (code >= 200 && code < 300) return;
    throw _errorFor(code, '上传远端文件失败');
  }

  Future<Response<dynamic>> _put(
    List<String> segments,
    List<int> bytes,
    String contentType,
  ) {
    return _request(
      'PUT',
      _uri(segments),
      data: bytes,
      options: Options(headers: {'Content-Type': contentType}),
    );
  }

  @override
  Future<void> delete(String path) async {
    final response = await _request(
      'DELETE',
      _uri([..._dirSegments(), ..._split(path)]),
    );
    final code = response.statusCode ?? 0;
    if (code == 404 || (code >= 200 && code < 300)) return;
    throw _errorFor(code, '删除远端文件失败');
  }

  @override
  Future<Set<String>?> list(String path) async {
    final response = await _request(
      'PROPFIND',
      _uri([..._dirSegments(), ..._split(path)], directory: true),
      data: _propfindBody,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 404) return null;
    if (code == 405 || code == 501) return null;
    if (code != 207 && (code < 200 || code >= 300)) {
      throw _errorFor(code, '读取远端目录失败');
    }
    final text = response.data is List<int>
        ? utf8.decode(response.data as List<int>, allowMalformed: true)
        : '${response.data ?? ''}';
    final names = <String>{};
    for (final match in RegExp(
      r'<[^>]*href[^>]*>(.*?)</[^>]*href>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(text)) {
      final raw = _decodeXml(match.group(1) ?? '').trim();
      if (raw.isEmpty) continue;
      final name = Uri.tryParse(raw)?.pathSegments.lastOrNull;
      if (name == null || name.isEmpty) continue;
      names.add(Uri.decodeComponent(name));
    }
    // 去掉目录自身。
    final selfName = _split(path).lastOrNull;
    names.removeWhere(
      (name) => name.isEmpty || name == '.' || name == selfName,
    );
    return names;
  }

  @override
  Future<void> ping() async {
    final response = await _request(
      'PROPFIND',
      _uri([..._dirSegments()], directory: true),
      data: _propfindBody,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 207 || code == 200 || code == 404) return;
    if (code == 405 || code == 501) {
      // 少数服务端不支持 PROPFIND，用一次 GET 验证鉴权。
      final probe = await read('manifest.json');
      if (probe != null) return;
      final fallback = await read('diary.json');
      if (fallback != null) return;
      final manifest = await _request(
        'GET',
        _uri([..._dirSegments(), 'manifest.json']),
        options: Options(responseType: ResponseType.bytes),
      );
      final fallbackCode = manifest.statusCode ?? 0;
      if (fallbackCode == 404 || fallbackCode == 200) return;
      throw _errorFor(fallbackCode, '连接 WebDAV 失败');
    }
    throw _errorFor(code, '连接 WebDAV 失败');
  }

  @override
  Future<void> close() async {
    _dio.close(force: true);
  }

  List<String> _dirSegments() =>
      remoteDir.split('/').where((segment) => segment.isNotEmpty).toList();

  List<String> _split(String path) =>
      path.split('/').where((segment) => segment.isNotEmpty).toList();

  Uri _uri(List<String> segments, {bool directory = false}) {
    final baseSegments = _baseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final all = [...baseSegments, ...segments];
    if (directory && all.isNotEmpty) {
      return _baseUri.replace(pathSegments: [...all, '']);
    }
    return _baseUri.replace(pathSegments: all, query: null, fragment: null);
  }

  Future<Response<dynamic>> _request(
    String method,
    Uri uri, {
    Object? data,
    Options? options,
  }) async {
    requestCounter?.record();
    try {
      return await _dio.requestUri<dynamic>(
        uri,
        data: data,
        options: (options ?? Options()).copyWith(method: method),
      );
    } on DioException catch (error) {
      throw _networkError(error);
    }
  }

  SyncException _errorFor(int code, String action) {
    if (code == 401 || code == 403) {
      return SyncException('$action：账号或应用密码不正确', statusCode: code);
    }
    if (code == 423) {
      return SyncException('$action：远端文件被其他程序锁定', statusCode: code);
    }
    if (code == 429) {
      final recent = requestCounter?.recentCount;
      final budget = recent == null ? '' : '（本机最近 30 分钟已发出 $recent 次请求）';
      return SyncException('$action：请求太频繁$budget，请稍后再试', statusCode: code);
    }
    if (code == 507) {
      return SyncException('$action：云端空间不足', statusCode: code);
    }
    return SyncException('$action（HTTP $code）', statusCode: code);
  }

  SyncException _networkError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const SyncException('连接超时，请检查网络或 WebDAV 地址');
      case DioExceptionType.badCertificate:
        return const SyncException('HTTPS 证书校验失败');
      case DioExceptionType.connectionError:
        return const SyncException('无法连接 WebDAV，请检查网络或地址');
      case DioExceptionType.cancel:
        return const SyncException('同步已取消');
      default:
        final cause = error.error;
        if (cause is SocketException) {
          return const SyncException('网络不可用，请稍后再试');
        }
        debugPrint('WebDAV 请求失败：${error.type} ${error.message ?? ''}');
        return const SyncException('访问 WebDAV 失败，请稍后再试');
    }
  }

  static Uri _parseBase(String raw) {
    var value = raw.trim();
    if (value.isEmpty) throw const SyncException('请填写 WebDAV 地址');
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      throw const SyncException('WebDAV 地址格式不正确');
    }
    return uri;
  }

  static String _normalizeDir(String raw) {
    var dir = raw.trim().replaceAll(r'\', '/');
    if (dir.isEmpty) return '/shengwuji_sync';
    if (!dir.startsWith('/')) dir = '/$dir';
    while (dir.length > 1 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    return dir.replaceAll(RegExp('/+'), '/');
  }

  static String? _header(Response<dynamic> response, String name) {
    final value = response.headers.value(name);
    return value == null || value.isEmpty ? null : value;
  }

  /// 取 PROPFIND 响应里的某个属性值，兼容带命名空间前缀的标签。
  static String? _xmlProp(String xml, String name) {
    final match = RegExp(
      '<((?:[\\w.-]+:)?${RegExp.escape(name)})\\b[^>]*>(.*?)</\\1>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    if (match == null) return null;
    final value = _decodeXml(match.group(2) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  static String _decodeXml(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }
}
