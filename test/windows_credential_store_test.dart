import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/sync/windows_credential_store.dart';

void main() {
  test('密码写入 Windows 凭据管理器并可读回、删除', () async {
    if (!Platform.isWindows) return;
    final store = WindowsCredentialPasswordStore(
      target: 'shengwuji.test.${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(store.delete);

    expect(await store.read(), isNull);

    await store.write('口令 p@ss');
    expect(await store.read(), '口令 p@ss');

    await store.write('second');
    expect(await store.read(), 'second');

    await store.delete();
    expect(await store.read(), isNull);
  });
}
