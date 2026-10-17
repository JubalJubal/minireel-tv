import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

File? _diagnosticFile;

/// Release 构建里 Flutter 不把 print 写进 logcat，真机/模拟器上的播放链路
/// 失败因此无从排查。日志放在 sqflite 的 databases 目录（数据库本身已证明
/// 该目录可写），重启前一直保留；超过 2MB 时先清空。
Future<void> initDiagnosticLog() async {
  try {
    final path = await getDatabasesPath();
    final directory = Directory(path);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final file = File('${directory.path}/diagnostics.log');
    if (file.existsSync() && file.lengthSync() > 2 * 1024 * 1024) {
      file.deleteSync();
    }
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} [Boot] log ready\n',
      mode: FileMode.append,
      flush: true,
    );
    _diagnosticFile = file;
  } on Object {
    _diagnosticFile = null;
    return;
  }
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null || message.isEmpty) return;
    final line = '${DateTime.now().toIso8601String()} $message\n';
    try {
      _diagnosticFile?.writeAsStringSync(
        line,
        mode: FileMode.append,
        flush: false,
      );
    } on Object {
      // 诊断日志失败不影响主流程。
    }
    debugPrintSynchronously(message, wrapWidth: wrapWidth);
  };
}

String get diagnosticLogPath => _diagnosticFile?.path ?? '';
