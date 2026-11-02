import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/ball_detector.dart';
import '../services/game_service.dart';
import '../services/goal_gate.dart';
import '../services/goal_pipeline.dart';
import '../services/goal_reporter.dart';
import '../services/settings.dart';
import '../services/vision.dart';
import '../widgets/rim_hint.dart';
import '../widgets/rim_selector.dart';

/// 鏡頭畫面：框選籃框、即時找球與判定進球。「模擬進球」按鈕留著測計分那條路。
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.settings, required this.games, required this.reporter});

  final Settings settings;
  final GameService games;
  final GoalReporter reporter;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _camera;
  String? _error;
  late Rect? _rim = widget.settings.rimBox;
  late bool _editing = _rim == null;
  final _gate = GoalGate();
  BallDetector? _detector;
  GoalPipeline? _pipeline;
  bool _streaming = false;
  bool _showHint = true;
  final _status = ValueNotifier<PipelineStatus?>(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable(); // 架著拍不能自動鎖屏
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        fps: 30,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
      await _syncDetection();
    } catch (e) {
      setState(() => _error = '無法開啟鏡頭：$e');
    }
  }

  /// 框好籃框才開始偵測；編輯中或沒有籃框時停下來。
  Future<void> _syncDetection() async {
    final cam = _camera;
    final rim = _rim;
    if (cam == null) return;
    final want = !_editing && rim != null;
    if (want == _streaming) return;
    if (!want) {
      _streaming = false;
      _pipeline = null;
      _status.value = null;
      await cam.stopImageStream();
      return;
    }
    try {
      _detector ??= await BallDetector.start();
    } catch (e) {
      if (mounted) setState(() => _error = '模型載入失敗：$e');
      return;
    }
    if (!mounted || _camera != cam) return;
    final pipeline = GoalPipeline(
      rimNorm: rim,
      detector: _detector!,
      onGoal: (ev) {
        if (mounted) _onGoal(confidence: ev.confidence);
      },
      onStatus: (s) => _status.value = s,
    );
    _pipeline = pipeline;
    _streaming = true;
    await cam.startImageStream((image) {
      final p = _pipeline;
      if (p == null || image.planes.length < 3) return;
      final uv = image.planes[1];
      p.onFrame(
        YuvFrame(
          width: image.width,
          height: image.height,
          y: image.planes[0].bytes,
          yStride: image.planes[0].bytesPerRow,
          u: uv.bytes,
          v: image.planes[2].bytes,
          uvStride: uv.bytesPerRow,
          uvPixelStride: uv.bytesPerPixel ?? 1,
        ),
        upsideDown: cam.value.deviceOrientation == DeviceOrientation.landscapeRight,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _camera;
    if (state == AppLifecycleState.inactive && cam != null) {
      _camera = null;
      _streaming = false;
      _pipeline = null;
      cam.dispose();
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pipeline = null;
    _camera?.dispose();
    _detector?.dispose();
    _status.dispose();
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onGoal({double? confidence}) {
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (!_gate.tryPass()) {
      messenger.showSnackBar(const SnackBar(content: Text('冷卻中，忽略'), duration: Duration(seconds: 1)));
      return;
    }
    final game = widget.games.current;
    // 半場只有一個籃框，固定回報 1 號
    final hoop = game?.isHalfCourt ?? false ? 1 : widget.settings.hoop;
    widget.reporter.report(hoop: hoop, confidence: confidence);
    final team = game?.teamNameForHoop(hoop);
    final text = game == null
        ? '進球！'
        : team == null
        ? '進球 +${game.autoPoints}，請在計分板選隊伍'
        : '進球！$team +${game.autoPoints}';
    messenger.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.white))
                : cam == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: cam.value.aspectRatio,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(cam),
                        RimSelector(
                          rim: _rim,
                          editing: _editing,
                          onChanged: (r) => setState(() => widget.settings.rimBox = _rim = r),
                        ),
                        IgnorePointer(
                          child: ValueListenableBuilder<PipelineStatus?>(
                            valueListenable: _status,
                            builder: (_, s, _) => CustomPaint(painter: _BallPainter(s?.ball)),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          SafeArea(child: _topBar()),
          if (_editing && _showHint && cam != null)
            SafeArea(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  // 上下留給返回鍵和完成鍵，不要蓋住
                  padding: const EdgeInsets.fromLTRB(12, 60, 12, 64),
                  child: RimHint(onClose: () => setState(() => _showHint = false)),
                ),
              ),
            ),
          SafeArea(
            child: Align(alignment: Alignment.bottomCenter, child: _bottomBar()),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final hoop = widget.settings.hoop;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          IconButton.filledTonal(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
          const SizedBox(width: 12),
          Flexible(
            child: StreamBuilder<LiveGame?>(
              stream: widget.games.stream,
              initialData: widget.games.current,
              builder: (_, snap) => _chip(
                snap.data?.isHalfCourt ?? false
                    ? '半場：進球在計分板選隊伍'
                    : '$hoop 號籃框 → ${snap.data?.teamNameForHoop(hoop) ?? '—'}',
              ),
            ),
          ),
          const SizedBox(width: 8),
          StreamBuilder<int>(
            stream: widget.reporter.pendingCount,
            initialData: widget.reporter.pending,
            builder: (_, snap) => (snap.data ?? 0) > 0 ? _chip('${snap.data} 筆待上傳', warn: true) : const SizedBox(),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: ValueListenableBuilder<PipelineStatus?>(
            valueListenable: _status,
            builder: (_, s, _) => s == null
                ? const SizedBox()
                : _chip(
                    '找球 ${s.fps.toStringAsFixed(0)} fps · ${s.backend} ${s.inferenceMs}+${s.prepareMs} ms · '
                    '${s.frameSize.width.toInt()}×${s.frameSize.height.toInt()} · 網 ${s.netMotion.toStringAsFixed(3)}',
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_editing && (_rim?.width ?? 1) < minRimWidth) ...[
            Flexible(child: _chip('籃框太小，容易漏判：手機架近一點再重新框選', warn: true)),
            const SizedBox(width: 12),
          ],
          if (_editing)
            _chip(_rim == null ? '在畫面上拖一個框，框住籃框' : '可以重新拖曳，好了按完成')
          else
            FilledButton.tonalIcon(
              icon: const Icon(Icons.crop_free),
              label: const Text('重新框選'),
              onPressed: () {
                setState(() {
                  _editing = true;
                  _showHint = true;
                });
                _syncDetection();
              },
            ),
          const SizedBox(width: 12),
          if (_editing)
            FilledButton(
              onPressed: _rim == null
                  ? null
                  : () {
                      setState(() => _editing = false);
                      _syncDetection();
                    },
              child: const Text('完成'),
            )
          else
            FilledButton.icon(icon: const Icon(Icons.sports_basketball), label: const Text('模擬進球'), onPressed: _onGoal),
        ],
      ),
    );
  }

  Widget _chip(String text, {bool warn = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: (warn ? Colors.orange.shade900 : Colors.black).withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
  );
}

/// 畫出目前偵測到的球，確認座標有對齊。
class _BallPainter extends CustomPainter {
  _BallPainter(this.ball);

  final Offset? ball;

  @override
  void paint(Canvas canvas, Size size) {
    final b = ball;
    if (b == null) return;
    canvas.drawCircle(
      Offset(b.dx * size.width, b.dy * size.height),
      14,
      Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BallPainter old) => old.ball != ball;
}
