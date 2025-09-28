// lib/camera.dart
// Recording mode with camera background and overlay HUD.
// NOTE:
// 1) This uses the `camera` and `share_plus` packages.
//    Make sure your pubspec.yaml includes：
//      camera: ^0.11.0
//      share_plus: ^10.0.2
//    （版本請依你的專案調整）
// 2) The overlay you want (時速、里程、溫度、狀態等) 可由 overlayBuilder 提供，
//    這樣可直接重用你主頁現有的小元件。
// 3) 錄影完成後會直接呼叫分享面板（Share Sheet）供使用者分享影片。

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    final previous = _controller;
    final selected = previous?.description;
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
      unawaited(previous?.dispose());
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
        final String? outputPath = await _replaykit
            .invokeMethod<String>('stopRecording')
            .then((value) => value?.toString());

        if (!mounted) return;
        setState(() => _recording = false);

        if (outputPath != null && outputPath.isNotEmpty) {
          _showSnack(L10n.t('recording_stopped'));
          await _handlePostRecording(outputPath);
        } else {
          // Older iOS fallback 仍會顯示系統預覽
          _showSnack(L10n.t('recording_stopped'));
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

  Future<void> _handlePostRecording(String filePath) async {
    final file = File(filePath);

    const checkDelay = Duration(milliseconds: 120);
    const maxRetry = 50; // ~6s max wait
    int retries = 0;
    bool ready = false;
    while (retries < maxRetry) {
      if (await file.exists()) {
        final length = await file.length();
        if (length > 0) {
          ready = true;
          break;
        }
      }
      await Future.delayed(checkDelay);
      retries++;
    }

    if (!ready) {
      _showSnack('${L10n.t('recording_error')}：file unavailable');
      return;
    }

    await _shareRecording(file);
    unawaited(file.delete().catchError((_) {}));

    await _recreateController();
  }

  Future<void> _shareRecording(File file) async {
    try {
      _showSnack(L10n.t('share_recording_prompt'));
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) {
      debugPrint('Share failed: $e');
      _showSnack('${L10n.t('share_failed')}：$e');
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
              left: 16,
              right: 16,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CircleBtn(
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      _CircleBtn(
                        icon:
                            _recording ? Icons.stop : Icons.fiber_manual_record,
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
