import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'password_store.dart';

/// 把 WebDAV 密码存进 Windows 凭据管理器（“Windows 凭据”里的普通凭据）。
///
/// 不依赖 flutter_secure_storage：它的 Windows 实现需要 ATL 头文件，
/// 而普通 VS C++ 桌面工作负载不一定包含 ATL。
class WindowsCredentialPasswordStore implements PasswordStore {
  WindowsCredentialPasswordStore({this.target = 'shengwuji.webdav.password'});

  final String target;

  static const String _userName = 'shengwuji';
  static const int _maxBlobBytes = 5 * 512;

  @override
  Future<String?> read() async {
    final targetPtr = target.toPcwstr();
    final credentialPtr = calloc<Pointer<CREDENTIAL>>();
    try {
      final result = CredRead(targetPtr, CRED_TYPE_GENERIC, credentialPtr);
      if (!result.value) return null;
      final credential = credentialPtr.value;
      try {
        final size = credential.ref.CredentialBlobSize;
        final blob = credential.ref.CredentialBlob;
        if (blob == nullptr || size == 0) return null;
        final value = utf8.decode(blob.asTypedList(size));
        return value.isEmpty ? null : value;
      } finally {
        CredFree(credential.cast());
      }
    } finally {
      free(credentialPtr);
      free(targetPtr);
    }
  }

  @override
  Future<void> write(String password) async {
    if (password.isEmpty) {
      await delete();
      return;
    }
    final bytes = utf8.encode(password);
    if (bytes.length > _maxBlobBytes) {
      throw StateError('WebDAV 密码过长，无法写入 Windows 凭据管理器');
    }

    final targetPtr = target.toPcwstr();
    final userPtr = _userName.toPcwstr();
    final blobPtr = calloc<Uint8>(bytes.length);
    blobPtr.asTypedList(bytes.length).setAll(0, bytes);
    final credentialPtr = calloc<CREDENTIAL>();
    try {
      final credential = credentialPtr.ref;
      credential.Type = CRED_TYPE_GENERIC;
      credential.TargetName = PWSTR(targetPtr);
      credential.UserName = PWSTR(userPtr);
      credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
      credential.CredentialBlobSize = bytes.length;
      credential.CredentialBlob = blobPtr;
      final result = CredWrite(credentialPtr, 0);
      if (!result.value) {
        throw StateError('写入 Windows 凭据管理器失败（${result.error.toHRESULT()}）');
      }
    } finally {
      free(credentialPtr);
      free(blobPtr);
      free(userPtr);
      free(targetPtr);
    }
  }

  @override
  Future<void> delete() async {
    final targetPtr = target.toPcwstr();
    try {
      CredDelete(targetPtr, CRED_TYPE_GENERIC);
    } finally {
      free(targetPtr);
    }
  }
}
