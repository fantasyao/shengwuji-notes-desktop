/// WebDAV 同步配置（不含密码）。
///
/// 地址、账号与远端目录随 `settings.json` 保存；密码单独进系统凭据存储。
class SyncConfig {
  const SyncConfig({
    this.baseUrl = '',
    this.username = '',
    this.remoteDir = defaultRemoteDir,
    this.enabled = true,
    this.audioEnabled = false,
    this.autoSyncMinutes = defaultAutoSyncMinutes,
  });

  static const String defaultRemoteDir = '/shengwuji_sync';

  /// 自动检查云端的间隔；0 表示只在启动、改动后与手动点击时同步。
  static const int defaultAutoSyncMinutes = 10;

  /// 设置页可选的间隔（分钟）；0 表示关闭。
  static const List<int> autoSyncOptions = [0, 5, 10, 15, 30];

  final String baseUrl;
  final String username;
  final String remoteDir;
  final bool enabled;

  /// 是否下载手机录音。默认关，避免一开同步就把所有历史录音拉下来。
  final bool audioEnabled;

  final int autoSyncMinutes;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      remoteDir.trim().isNotEmpty;

  Duration? get autoSyncInterval =>
      autoSyncMinutes > 0 ? Duration(minutes: autoSyncMinutes) : null;

  SyncConfig copyWith({
    String? baseUrl,
    String? username,
    String? remoteDir,
    bool? enabled,
    bool? audioEnabled,
    int? autoSyncMinutes,
  }) {
    return SyncConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      remoteDir: remoteDir ?? this.remoteDir,
      enabled: enabled ?? this.enabled,
      audioEnabled: audioEnabled ?? this.audioEnabled,
      autoSyncMinutes: autoSyncMinutes ?? this.autoSyncMinutes,
    );
  }

  Map<String, dynamic> toJson() => {
    'base_url': baseUrl.trim(),
    'username': username.trim(),
    'remote_dir': normalizeRemoteDir(remoteDir),
    'enabled': enabled,
    'audio_enabled': audioEnabled,
    'auto_sync_minutes': autoSyncMinutes,
  };

  factory SyncConfig.fromJson(Map<String, dynamic> json) {
    final baseUrl = json['base_url'];
    final username = json['username'];
    final remoteDir = json['remote_dir'];
    final enabled = json['enabled'];
    final audioEnabled = json['audio_enabled'];
    final autoSyncMinutes = json['auto_sync_minutes'];
    return SyncConfig(
      baseUrl: baseUrl is String ? baseUrl.trim() : '',
      username: username is String ? username.trim() : '',
      remoteDir: remoteDir is String && remoteDir.trim().isNotEmpty
          ? normalizeRemoteDir(remoteDir)
          : defaultRemoteDir,
      enabled: enabled is bool ? enabled : true,
      audioEnabled: audioEnabled is bool ? audioEnabled : false,
      autoSyncMinutes:
          autoSyncMinutes is num &&
              autoSyncOptions.contains(autoSyncMinutes.toInt())
          ? autoSyncMinutes.toInt()
          : defaultAutoSyncMinutes,
    );
  }

  /// 与手机端 `_normalizeBase` 保持一致的远端目录写法：前导 `/`、无末尾 `/`。
  static String normalizeRemoteDir(String value) {
    var dir = value.trim().replaceAll(r'\', '/');
    if (dir.isEmpty) return defaultRemoteDir;
    if (!dir.startsWith('/')) dir = '/$dir';
    while (dir.length > 1 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    dir = dir.replaceAll(RegExp('/+'), '/');
    return dir.isEmpty ? defaultRemoteDir : dir;
  }
}
