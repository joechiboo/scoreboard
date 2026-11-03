import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreboard_detector/services/trace_log.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('trace_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('依序寫入，關閉時不漏掉最後一批', () async {
    final file = File('${dir.path}/a.log');
    final log = TraceLog(file, batch: 3);
    for (var i = 0; i < 7; i++) {
      log.write('line $i');
    }
    await log.close();
    expect(file.readAsLinesSync(), [for (var i = 0; i < 7; i++) 'line $i']);
  });

  test('關閉後再寫不會出錯，也不會寫入', () async {
    final file = File('${dir.path}/a.log');
    final log = TraceLog(file);
    log.write('first');
    await log.close();
    log.write('late');
    await log.close();
    expect(file.readAsLinesSync(), ['first']);
  });

  test('寫不進去時不丟例外，偵測才不會被記錄拖垮', () async {
    final log = TraceLog(File('${dir.path}/沒有這個資料夾/a.log'), batch: 1);
    log.write('x');
    log.write('y');
    await expectLater(log.close(), completes);
  });

  test('只留最新的檔案，其他副檔名不動', () async {
    for (var i = 0; i < 5; i++) {
      File('${dir.path}/2026-11-0$i.log').writeAsStringSync('x');
    }
    final other = File('${dir.path}/note.txt')..writeAsStringSync('x');
    await TraceLog.prune(dir, keep: 2);
    final names = dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(names, ['2026-11-03.log', '2026-11-04.log', 'note.txt']);
    expect(other.existsSync(), isTrue);
  });

  test('檔案比保留數少時什麼都不刪', () async {
    File('${dir.path}/a.log').writeAsStringSync('x');
    await TraceLog.prune(dir, keep: 30);
    expect(File('${dir.path}/a.log').existsSync(), isTrue);
  });
}
