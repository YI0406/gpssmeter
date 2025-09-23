// lib/camera.dart
// Recording mode with camera background and overlay HUD.
// NOTE:
// 1) This uses the `camera`, `path_provider`, and `share_plus` packages.
//    Make sure your pubspec.yaml includes:
//      camera: ^0.11.0
//      path_provider: ^2.1.3
//      share_plus: ^10.0.0
//    (Versions are examples; align with your project.)
// 2) The overlay you want (時速、里程、溫度、狀態等) 可由 overlayBuilder 提供，
//    這樣可直接重用你主頁現有的小元件。
// 3) 目前「保存到相簿」未內建，因為你先前回報 gallery_saver 套件相依衝突。
//    若要存到相簿，建議改用 `photo_manager` 或 `image_gallery_saver`，
//    之後我可以幫你補上對接（避免 http 衝突）。

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:gps_speedometer_min/setting.dart';

/// 頁面：錄影模式（相機做背景，資訊 HUD 懸浮其上）
class CameraRecordPage extends StatefulWidget {
  const CameraRecordPage({
    super.key,
    this.overlayBuilder,
    this.forceBackCamera = true,
    this.showSystemUI = false,
  });

  /// 你主頁現有資訊面板（時速/里程/狀態等）放這裡即可覆蓋在相機畫面上。
  final Widget Function(BuildContext context)? overlayBuilder;

  /// 是否強制使用後鏡頭（預設 true）。
  final bool forceBackCamera;

  /// 是否顯示系統 UI（狀態列/導航列）。一般錄影想要沉浸式可設為 false。
  final bool showSystemUI;

  @override
  State<CameraRecordPage> createState() => _CameraRecordPageState();
}

class _CameraRecordPageState extends State<CameraRecordPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Platform channel for iOS ReplayKit bridge
  static const MethodChannel _replaykit = MethodChannel('replaykit');

  CameraController? _controller;
  bool _isDisposingController = false;
  List<CameraDescription> _cameras = const [];
  bool _initializing = true;
  bool _recording = false;
  bool _opBusy = false; // guard for start/stop in progress

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Listen native callback: preview closed -> re-init camera
    _replaykit.setMethodCallHandler((call) async {
      if (call.method == 'previewClosed') {
        if (!mounted) return;
        setState(() => _recording = false);
        // Always rebuild a fresh camera session to avoid stale/invalid controller
        _initCamera();
      } else if (call.method == 'recordingStarted') {
        if (!mounted) return;
        setState(() => _recording = true);
      } else if (call.method == 'recordingStopped') {
        if (!mounted) return;
        setState(() => _recording = false);
      }
    });
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isDisposingController = true;
    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      unawaited(ctrl.dispose());
    }
    _isDisposingController = false;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (controller != null) {
        _isDisposingController = true;
        _controller = null;
        unawaited(controller.dispose());
        _isDisposingController = false;
        setState(() {});
      }
    } else if (state == AppLifecycleState.resumed) {
      // Always try to (re)initialize when coming back to foreground,
      // even if controller is currently null (e.g., after permission dialog
      // or after ReplayKit preview dismissal).
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    setState(() => _initializing = true);
    try {
      _cameras = await availableCameras();
      CameraDescription? cam;
      if (widget.forceBackCamera) {
        cam = _cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () =>
              _cameras.isNotEmpty ? _cameras.first : throw 'No camera',
        );
      } else {
        cam = _cameras.isNotEmpty ? _cameras.first : null;
      }
      if (cam == null) throw 'No camera found';

      _controller = null;
      final ctrl = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: true,
      );
      await ctrl.initialize();

      if (!mounted) return;
      setState(() {
        _controller = ctrl;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _initializing = false);
      _showSnack('${L10n.t('camera_init_failed')}：$e');
    }
  }

  Future<void> _recreateController() async {
    if (_isDisposingController) return;
    final selected = _controller?.description;
    if (selected == null) return _initCamera();
    try {
      final ctrl = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: true,
      );
      await ctrl.initialize();
      if (!mounted) return;
      setState(() => _controller = ctrl);
    } catch (e) {
      _showSnack('${L10n.t('camera_restore_failed')}：$e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 500), content: Text(msg)),
    );
  }

  Future<void> _toggleRecord() async {
    if (_opBusy) return;
    _opBusy = true;
    try {
      if (!_recording) {
        final bool ok = await _replaykit.invokeMethod<bool>(
            'startRecording', {'mic': true}).then((v) => v ?? true);
        if (ok) {
          if (!mounted) return;
          setState(() => _recording = true);
          _showSnack(L10n.t('recording_started'));
        } else {
          _showSnack(L10n.t('recording_start_failed'));
        }
      } else {
        final bool ok = await _replaykit
            .invokeMethod<bool>('stopRecording')
            .then((v) => v ?? true);
        if (ok) {
          if (!mounted) return;
          setState(() => _recording = false); // 立刻復原按鈕
          _showSnack(L10n.t('recording_stopped'));
        } else {
          _showSnack(L10n.t('recording_stop_failed'));
        }
      }
    } catch (e) {
      if (e is PlatformException && e.code == 'stop_failed') {
        if (!mounted) return;
        setState(() => _recording = false);
      }
      _showSnack('${L10n.t('recording_error')}：$e');
    } finally {
      _opBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    final initializing = _initializing ||
        ctrl == null ||
        _isDisposingController ||
        !ctrl.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: widget.showSystemUI,
        bottom: widget.showSystemUI,
        left: widget.showSystemUI,
        right: widget.showSystemUI,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera background
            if (!initializing && !_isDisposingController)
              GestureDetector(
                onTapDown: (details) async {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null && _controller != null) {
                    final offset = details.localPosition;
                    final size = box.size;
                    final dx = offset.dx / size.width;
                    final dy = offset.dy / size.height;
                    try {
                      await _controller!.setFocusPoint(Offset(dx, dy));
                      await _controller!.setExposurePoint(Offset(dx, dy));
                    } catch (_) {
                      // Some devices may not support setting focus/exposure point
                    }
                  }
                },
                child: CameraPreview(ctrl),
              )
            else
              const Center(child: CircularProgressIndicator()),

            // Overlay HUD from caller (你的主頁資訊)
            if (widget.overlayBuilder != null)
              Positioned.fill(child: widget.overlayBuilder!(context)),

            // Top bar
            Positioned(
              top: 50,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleBtn(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  _CircleBtn(
                    icon: _recording ? Icons.stop : Icons.fiber_manual_record,
                    onTap: _opBusy ? null : _toggleRecord,
                    tooltip: _recording
                        ? L10n.t('stop_recording')
                        : L10n.t('start_recording_camera'),
                    bgColor: _recording ? Colors.redAccent : Colors.black54,
                    iconColor: _recording ? Colors.white : Colors.redAccent,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({
    required this.icon,
    this.onTap,
    this.tooltip,
    this.bgColor,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? bgColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: bgColor ?? Colors.black.withOpacity(onTap == null ? 0.2 : 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor ?? Colors.white),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}
