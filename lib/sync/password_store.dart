/// WebDAV 密码的存取。密码不写进 settings.json、数据库或日志。
abstract class PasswordStore {
  Future<String?> read();

  Future<void> write(String password);

  Future<void> delete();
}

/// 测试替身。
class MemoryPasswordStore implements PasswordStore {
  MemoryPasswordStore([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String password) async {
    value = password.isEmpty ? null : password;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}
