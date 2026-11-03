import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 把每一幀的偵測結果存成手機上的文字檔，打完球用 USB 拉回電腦分析。
///
/// Supabase 只有判定成進球的那幾筆，調門檻最需要的是「差一點沒判定」的球，所以每幀都記。
/// 記錄失敗不能影響偵測，所有錯誤都吞掉；累積一批才寫一次，不拖慢畫面。
class TraceLog {
  TraceLog(this.file, {this.batch = 50});

  /// 只留最近幾個檔案，免得佔滿手機（每 30 分鐘約 3 MB）。
  static const keepFiles = 30;

  final File file;
  final int batch;
  final _lines = <String>[];
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// 開一個新的記錄檔；手機拿不到儲存空間時回傳 null，偵測照常跑。
  static Future<TraceLog?> open() async {
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return null;
      final dir = Directory('${base.path}/trace');
      await dir.create(recursive: true);
      await prune(dir);
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      return TraceLog(File('${dir.path}/$stamp.log'));
    } catch (_) {
      return null;
    }
  }

  /// 刪掉最舊的檔案，只留最近 [keep] 個。檔名是時間，照名字排序就是照時間排序。
  static Future<void> prune(Directory dir, {int keep = keepFiles}) async {
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files.take(files.length - keep < 0 ? 0 : files.length - keep)) {
      await f.delete();
    }
  }

  void write(String line) {
    if (_closed) return;
    _lines.add(line);
    if (_lines.length >= batch) _flush();
  }

  void _flush() {
    if (_lines.isEmpty) return;
    final text = '${_lines.join('\n')}\n';
    _lines.clear();
    // 串起來一次寫一批，順序才不會亂
    _writing = _writing.then((_) => file.writeAsString(text, mode: FileMode.append)).catchError((_) => file);
  }

  /// 把剩下的寫完。重複呼叫沒關係。
  Future<void> close() async {
    _flush();
    _closed = true;
    await _writing;
  }
}
