import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'vision.dart';

// 模擬結果（10-30 半場 21 球）：輸入 320 只抓到 7 球，640 才有 15 球，所以用 640
const modelAsset = 'assets/yolo11n_640.tflite';
const modelInputSize = 640;

/// 模型偵測門檻。現成模型對遠處的籃球信心很低，門檻設低，靠軌跡和籃網排除誤判。
const ballConfidence = 0.05;

class CropResult {
  CropResult(this.boxes, this.inferenceMs, this.prepareMs);

  /// 裁切區座標的 [cx, cy, w, h, conf]。
  final List<List<double>> boxes;
  final int inferenceMs;
  final int prepareMs;
}

/// 背景 isolate 跑 YOLO，不卡畫面。一次只處理一張，忙的時候呼叫端自己丟幀。
class BallDetector {
  BallDetector._(this._isolate, this._toWorker, this._results, this.backend);

  /// 實際用哪個運算單元：GPU，或 GPU 不支援時退回 CPU。
  final String backend;

  final Isolate _isolate;
  final SendPort _toWorker;
  final StreamQueue _results;

  static Future<BallDetector> start() async {
    final model = (await rootBundle.load(modelAsset)).buffer.asUint8List();
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_worker, [port.sendPort, TransferableTypedData.fromList([model])]);
    final queue = StreamQueue(port);
    final msg = await queue.next();
    if (msg is! List) {
      isolate.kill();
      throw StateError('模型載入失敗：$msg');
    }
    return BallDetector._(isolate, msg[0] as SendPort, queue, msg[1] as String);
  }

  Future<CropResult> detect(Uint8List rgb, int w, int h) async {
    _toWorker.send([TransferableTypedData.fromList([rgb]), w, h]);
    final msg = await _results.next() as List;
    return CropResult((msg[0] as List).cast<List<double>>(), msg[1] as int, msg[2] as int);
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _results.close();
  }

  static void _worker(List args) {
    final out = args[0] as SendPort;
    final Interpreter interpreter;
    var backend = 'GPU';
    try {
      final model = (args[1] as TransferableTypedData).materialize().asUint8List();
      interpreter = _open(model) ?? _openCpu(model);
      if (interpreter.address == 0) throw StateError('interpreter');
      backend = _lastBackend;
    } catch (e) {
      out.send('$e');
      return;
    }
    final port = ReceivePort();
    out.send([port.sendPort, backend]);
    final input = interpreter.getInputTensor(0);
    final output = interpreter.getOutputTensor(0);
    final n = output.shape[2];
    port.listen((m) {
      final msg = m as List;
      final rgb = (msg[0] as TransferableTypedData).materialize().asUint8List();
      final w = msg[1] as int, h = msg[2] as int;
      final sw = Stopwatch()..start();
      final lb = Letterbox.from(rgb, w, h, modelInputSize);
      input.data = lb.input.buffer.asUint8List();
      final prepareMs = sw.elapsedMilliseconds;
      sw.reset();
      interpreter.invoke();
      final inferenceMs = sw.elapsedMilliseconds;
      final bytes = Uint8List.fromList(output.data);
      final boxes = parseYolo(bytes.buffer.asFloat32List(), n, modelInputSize, ballConfidence);
      final mapped = [
        for (final b in boxes) [lb.toCropX(b[0]), lb.toCropY(b[1]), b[2] / lb.scale, b[3] / lb.scale, b[4]],
      ];
      out.send([mapped, inferenceMs, prepareMs]);
    });
  }
}

String _lastBackend = 'CPU';

/// 先試 GPU（CPU 跑 640 輸入每張要 267 ms，來不及看球的軌跡）；不支援就回傳 null。
Interpreter? _open(Uint8List model) {
  try {
    final options = InterpreterOptions()..addDelegate(GpuDelegateV2());
    final i = Interpreter.fromBuffer(model, options: options)..allocateTensors();
    _lastBackend = 'GPU';
    return i;
  } catch (_) {
    return null;
  }
}

Interpreter _openCpu(Uint8List model) {
  _lastBackend = 'CPU';
  return Interpreter.fromBuffer(model, options: InterpreterOptions()..threads = 4)..allocateTensors();
}

/// 依序取 ReceivePort 的訊息（不引入 async 套件）。
class StreamQueue {
  StreamQueue(this._port) {
    _sub = _port.listen((m) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(m);
      } else {
        _buffer.add(m);
      }
    });
  }

  final ReceivePort _port;
  late final StreamSubscription _sub;
  final _buffer = <Object?>[];
  final _waiting = <Completer<Object?>>[];

  Future<Object?> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<Object?>();
    _waiting.add(c);
    return c.future;
  }

  void close() {
    _sub.cancel();
    _port.close();
  }
}
