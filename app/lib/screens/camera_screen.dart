import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config.dart';
import '../services/game_service.dart';
import '../services/goal_gate.dart';
import '../services/goal_reporter.dart';
import '../services/settings.dart';
import '../widgets/rim_selector.dart';

/// 鏡頭畫面：框選籃框、偵測進球（目前以「模擬進球」按鈕代替 YOLO）。
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
      final controller = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      setState(() => _error = '無法開啟鏡頭：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _camera;
    if (state == AppLifecycleState.inactive && cam != null) {
      _camera = null;
      cam.dispose();
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
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
    final hoop = widget.settings.hoop;
    widget.reporter.report(hoop: hoop, confidence: confidence);
    final team = widget.games.current?.teamNameForHoop(hoop) ?? '';
    messenger.showSnackBar(SnackBar(content: Text('進球！$team +$autoGoalPoints'), duration: const Duration(seconds: 1)));
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
                          ],
                        ),
                      ),
          ),
          SafeArea(child: _topBar()),
          SafeArea(child: Align(alignment: Alignment.bottomCenter, child: _bottomBar())),
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
          StreamBuilder<LiveGame?>(
            stream: widget.games.stream,
            initialData: widget.games.current,
            builder: (_, snap) => _chip('$hoop 號籃框 → ${snap.data?.teamNameForHoop(hoop) ?? '—'}'),
          ),
          const Spacer(),
          StreamBuilder<int>(
            stream: widget.reporter.pendingCount,
            initialData: widget.reporter.pending,
            builder: (_, snap) => (snap.data ?? 0) > 0 ? _chip('${snap.data} 筆待上傳', warn: true) : const SizedBox(),
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
          if (_editing)
            _chip(_rim == null ? '在畫面上拖一個框，框住籃框' : '可以重新拖曳，好了按完成')
          else
            FilledButton.tonalIcon(
              icon: const Icon(Icons.crop_free),
              label: const Text('重新框選'),
              onPressed: () => setState(() => _editing = true),
            ),
          const SizedBox(width: 12),
          if (_editing)
            FilledButton(
              onPressed: _rim == null ? null : () => setState(() => _editing = false),
              child: const Text('完成'),
            )
          else
            // YOLO 接上前，用按鈕模擬偵測到進球
            FilledButton.icon(
              icon: const Icon(Icons.sports_basketball),
              label: const Text('模擬進球'),
              onPressed: _onGoal,
            ),
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
        child: Text(text, style: const TextStyle(color: Colors.white)),
      );
}
