import 'dart:async';
import 'trip.dart';
import 'mapmode.dart';
import 'main.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gps_speedometer_min/setting.dart';

/// 速度圓底不透明度（0.0 ~ 1.0）
const double kSpeedBadgeOpacity = 0.35; // 速度圓：更淡就 0.25，更實就 0.5
/// 指南針底圈不透明度（0.0 ~ 1.0）
const double kCompassBadgeOpacity = 0.8; // 指南針：獨立調整
/// 自動暫停判定視窗（秒）與位移門檻（公尺）——需與主頁一致
const double kAutoPauseWindowSec = 3.0;
const double kAutoPauseDistanceMeters = 1.5;

/// 允許旋轉的最低速度（m/s）— 5 km/h
const double kRotateMinSpeedMps = 5.0 / 3.6;

/// 啟動紀錄的最低速度（m/s）— 10 km/h（未達前狀態顯示保持為「暫停中」）
const double kRecordStartMinSpeedMps = 10.0 / 3.6;

/// 地圖相機模式
/// - northUp: 永遠北上（關陀螺儀 / 不依車頭旋轉）
/// - headingUp: 依車頭方向（開陀螺儀可旋轉）
enum MapCameraMode { northUp, headingUp }

/// 進入「地圖模式」的頁面
///
/// 功能：
/// 1. 只顯示時速 + 地圖 + 軌跡線。
/// 2. 支援兩種相機模式（北上/車頭朝上）。
/// 3. 開始記錄時會持續把當下 GPS 位置加入 polyline。
/// 4. 跟隨主題顏色（淺/深色、主色）。
///
/// 備註：本頁可透過 onStopAndSave 回呼（若有傳入）觸發結束旅程與儲存。
class MapModePage extends StatefulWidget {
  /// 記錄使用者上次選擇的模式
  static MapCameraMode? _lastMode;
  const MapModePage({
    super.key,
    required this.route,
    required this.recording,
    required this.onToggleRecord,
    this.onStopAndSave,
    this.onStopAndSaveResult,
    this.initialMode = MapCameraMode.headingUp,
    this.useMiles = false,
    this.liveSpeedMps,
  });

  /// 預設模式（主頁分流選的子選項）
  final MapCameraMode initialMode;

  final bool useMiles;

  final List<LatLng> route;
  final bool recording;
  final ValueListenable<double>? liveSpeedMps;
  final VoidCallback onToggleRecord;
  final Future<void> Function()? onStopAndSave;
  final Future<bool> Function()? onStopAndSaveResult;

  @override
  State<MapModePage> createState() => _MapModePageState();
}

// 近 3 秒內的座標樣本，用於判斷「自動暫停中」
class _TimedSample {
  final LatLng pos;
  final DateTime ts;
  _TimedSample(this.pos, this.ts);
}

final List<_TimedSample> _recentSamples = [];

class _MapModePageState extends State<MapModePage> {
  AppleMapController? _mapController;
  final _polylines = <Polyline>{};
  final _annotations = <Annotation>{};
  // 強制重繪 polyline 用：每次更新切換一組 id，避免偶發不刷新的情況
  int _polyVersion = 0;
  StreamSubscription<Position>? _posSub;
  MapCameraMode _mode = MapCameraMode.headingUp;
  double _speedDisplay = 0; // 顯示單位（km/h 或 mph）
  late bool _useMiles;
  late bool _recording;
  // 是否已跨過起步門檻（>= 10 km/h）才算真正「開始記錄」
  bool _passedStartGate = false;
  // 使用者手動旋轉暫存：未達門檻時維持；超過門檻自動清除
  double? _manualHeadingDeg;
  bool get _hasManualHeading => _manualHeadingDeg != null;

  bool _isMoving = false;
  DateTime? _lastMoveAt;

  int _lastRouteLen = 0;
  DateTime? _lastTick;
  Timer? _routeWatch;
  LatLng? _prevLast;

  final _displayRoute = <LatLng>[];

  VoidCallback? _liveSpeedListener;

  // Annotation state
  LatLng? _current;

  // 是否自動跟隨相機（預設關閉，讓使用者可自由平移/縮放）
  bool _followCamera = false;
  // 使用者手動移動地圖時，關閉跟隨
  bool _userGesture = false;
  // 暫時性：不改模式（可能仍是 northUp），但強制以 heading 追蹤來顯示扇形並隨手機旋轉
  bool _headingFollowTransient = false;
  // 定位按鈕行為：第一次按只回到目前位置；第二次按才切 headingUp 顯示扇形
  bool _locatePrimed = false;
  DateTime? _locatePrimedAt;
  bool _progCamMove = false; // 程式主動移動相機時避免誤判為使用者操作
  // 保留最後一次已知的行進方位（停止時仍可用於 headingUp）
  double _headingDeg = 0;
  double _lastValidHeadingDeg = 0; // 長停時用的最後有效車頭角度（避免回到北方在上）
  // 目前相機朝向（地圖旋轉角度，0 = 北向上），用於指南針箭頭
  double _cameraHeadingDeg = 0;
  // 記住目前縮放（避免按定位鍵被重設）
  double _currentZoom = 14; // 與 initialCameraPosition 對齊
  // 取得目前顯示中的縮放（優先取最近一次快取到的相機 zoom）
  double get _zoomNow => _lastCam?.zoom ?? _currentZoom;
  // 最近一次已知的相機狀態（用於取代 getCameraPosition）
  CameraPosition? _lastCam;
  // 追蹤模式下等待恢復的縮放任務序號（用於取消排程）
  int _zoomRestoreSeq = 0;
  double _lastMps = 0.0;
  bool get _canRotate => _lastMps > kRotateMinSpeedMps;
  // 使用 Apple Maps 原生追蹤模式：
  // northUp → follow；headingUp → followWithHeading；未跟隨 → none
  TrackingMode get _trackingMode {
    if (!_followCamera) return TrackingMode.none;
    if (_headingFollowTransient || _mode == MapCameraMode.headingUp) {
      return TrackingMode.followWithHeading; // 顯示扇形，隨手機旋轉
    }
    return TrackingMode.follow; // 僅置中
  }

  // 啟用暫時 heading 追蹤（不改 _mode），並強制 AppleMap 重新套 trackingMode
  void _engageTransientHeadingTracking({bool recenter = true, double? zoom}) {
    final savedZoom = zoom ?? _zoomNow;
    setState(() {
      _headingFollowTransient = true; // 啟用暫時 heading 追蹤（不改 _mode）
      _manualHeadingDeg = null; // 交給原生旋轉
      _followCamera = true; // 必須打開跟隨
      _currentZoom = savedZoom;
    });
    if (recenter) {
      _jumpToCurrent(zoom: savedZoom, force: true);
    }
    // 透過脈衝切換，強制 plugin 重新套用 trackingMode
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _followCamera = false;
      });
      Future.delayed(const Duration(milliseconds: 16), () {
        if (!mounted) return;
        setState(() {
          _followCamera = true;
          _currentZoom = savedZoom;
        });
        if (recenter) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _jumpToCurrent(zoom: savedZoom, force: true);
          });
        }
      });
    });
  }

  // 跟隨防誤觸：僅當使用者確實平移/縮放/旋轉到一定門檻才關閉跟隨
  DateTime? _gestureStartAt;
  LatLng? _gestureStartTarget;
  double _gestureStartZoom = 14;
  double _gestureMovedMeters = 0;
  double _gestureZoomDelta = 0;
  double _gestureHeadingDelta = 0;
  DateTime? _lastUserGestureAt; // 最後一次使用者操作時間

  // 面板/對話框動畫期間抑制系統觸發的相機事件
  DateTime? _zoomGuardUntil; // 在面板/對話框動畫期間抑制系統觸發的相機事件
  bool get _inZoomGuard =>
      _zoomGuardUntil != null && DateTime.now().isBefore(_zoomGuardUntil!);
  void _armZoomGuard([int ms = 1400]) {
    _zoomGuardUntil = DateTime.now().add(Duration(milliseconds: ms));
  }

  // UI helpers
  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _onPrimary => Theme.of(context).colorScheme.onPrimary;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _onSurface => Theme.of(context).colorScheme.onSurface;
  void _pushRecent(LatLng p) {
    final now = DateTime.now();
    _recentSamples.add(_TimedSample(p, now));
    // 移除視窗外的舊點
    final cutoff = now.subtract(
      Duration(milliseconds: (kAutoPauseWindowSec * 1000).toInt()),
    );
    _recentSamples.removeWhere((e) => e.ts.isBefore(cutoff));
    // 也避免無限成長（保留最多 120 筆 ≈ 3 秒 / 25Hz）
    if (_recentSamples.length > 120) {
      _recentSamples.removeRange(0, _recentSamples.length - 120);
    }
  }

  bool get _isAutoPaused {
    if (!_recording) return false;
    if (_recentSamples.length < 2) return false;
    final first = _recentSamples.first.pos;
    final last = _recentSamples.last.pos;
    final d = _distanceMeters(first, last);
    return d < kAutoPauseDistanceMeters;
  }

  @override
  void initState() {
    super.initState();
    _mode = MapModePage._lastMode ?? widget.initialMode;
    _useMiles = widget.useMiles;
    _recording = widget.recording;
    // 剛進入地圖頁就開啟跟隨，並在第一幀後套用相機模式
    _followCamera = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyCameraForMode();
    });
    // 再補一拍（200ms）重試，避免地圖尚未完全就緒時第一次呼叫無效
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      if (_mapController != null) {
        _applyCameraForMode();
      }
    });
    _initLocationStream();
    // 初始時把現有的主路徑拷貝到顯示用路徑，避免返回再進來看不到線
    if (widget.route.isNotEmpty) {
      _displayRoute
        ..clear()
        ..addAll(widget.route);
      _lastRouteLen = widget.route.length;
      _prevLast = widget.route.last;
      // 先畫一次
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshPolyline();
        _refreshAnnotations();
      });
    }
    if (widget.liveSpeedMps != null) {
      _liveSpeedListener = () {
        final mps = widget.liveSpeedMps!.value;
        final kmh = mps * 3.6;
        final display = _useMiles ? (kmh * 0.621371) : kmh;
        final moving = mps > 0.5; // ~1.8 km/h
        setState(() {
          _lastMps = mps;
          _speedDisplay = display;
          _isMoving = moving;
          if (moving) _lastMoveAt = DateTime.now();
        });
        // 錄製中且第一次跨過 10 km/h → 視為開始記錄
        if (_recording &&
            !_passedStartGate &&
            _lastMps >= kRecordStartMinSpeedMps) {
          setState(() {
            _passedStartGate = true;
          });
        }
        // 超過門檻（>5 km/h）恢復自動轉向
        if (_lastMps > kRotateMinSpeedMps && _hasManualHeading) {
          _manualHeadingDeg = null;
        }
      };
      widget.liveSpeedMps!.addListener(_liveSpeedListener!);
      // 立刻同步一次以避免顯示 0
      _liveSpeedListener!();
    }
    _routeWatch = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      final len = widget.route.length;
      final hasAny = len > 0;
      final last = hasAny ? widget.route.last : null;
      final changed = (len != _lastRouteLen) ||
          (last != null &&
              (_prevLast == null ||
                  (_prevLast!.latitude != last.latitude ||
                      _prevLast!.longitude != last.longitude)));

      // 維持地圖上連續的顯示路徑：即使主資料只覆寫末端，我們也把末端累積起來
      if (!hasAny) {
        _displayRoute.clear();
      } else if (changed) {
        // 新增或覆寫皆納入顯示路徑
        _displayRoute.add(last!);
        // 避免無限增長，可選擇保留最近 5000 點（足夠顯示）
        if (_displayRoute.length > 5000) {
          _displayRoute.removeRange(0, _displayRoute.length - 5000);
        }
      }
      if (_displayRoute.isEmpty && hasAny) {
        _displayRoute.add(last!);
      }

      // 每一拍都刷新，避免偶發沒觸發
      _refreshPolyline();
      _refreshAnnotations();

      // 計算 heading（即使未啟用跟隨也要更新，供「目的地方向上」在靜止時立即生效）
      double heading = 0;
      if (_mode == MapCameraMode.headingUp && hasAny) {
        if (len >= 2) {
          heading = _bearing(widget.route[len - 2], last!);
        } else if (len == 1 && _prevLast != null) {
          // 只有一個點但 last 在移動（被覆寫），也用上一拍的 last 算方向
          heading = _bearing(_prevLast!, last!);
        }
      }
      // 記住最後一次計算的 heading，停止時沿用
      _headingDeg = heading != 0 ? heading : _headingDeg;

      // 若本拍有新增或末端座標有變化，就估算速度（即使沒跟隨）
      if (changed) {
        LatLng? a;
        if (len >= 2) {
          a = widget.route[len - 2];
        } else if (_prevLast != null && last != null) {
          a = _prevLast; // 同長度時末點被覆寫
        }
        if (a != null && last != null) {
          final now = DateTime.now();
          final meters = _distanceMeters(a, last);
          final dt = _lastTick == null
              ? 0.3
              : (now.difference(_lastTick!).inMilliseconds / 1000).clamp(
                  0.05,
                  2.0,
                );
          if (widget.liveSpeedMps == null) {
            final kmh = (meters / dt) * 3.6;
            final display = _useMiles ? (kmh * 0.621371) : kmh;
            setState(() => _speedDisplay = display);
          }
          _lastTick = now;
        }
      }

      // 自動恢復跟隨：若使用者已停止操作一段時間且正在移動
      if (!_followCamera && _mapController != null && hasAny) {
        final now2 = DateTime.now();
        final bool quietUser = _lastUserGestureAt == null ||
            now2.difference(_lastUserGestureAt!).inMilliseconds > 5000;
        if (quietUser && _isMoving) {
          // 直接執行「定位」FAB 的行為：
          // 北上模式 → 回定位且維持北上；
          // 目的地方向上 → 回定位並開啟扇形、隨手機旋轉。
          _onLocateFabPressed();
        }
      }

      // 僅在啟用跟隨時移動相機
      if (_followCamera &&
          _mapController != null &&
          hasAny &&
          _trackingMode == TrackingMode.none) {
        double camHeading;
        if (_mode == MapCameraMode.northUp) {
          // 北上：低速可暫時維持手動角度；達門檻或一般情況回正北
          if (!_canRotate && _hasManualHeading) {
            camHeading = _manualHeadingDeg!;
          } else {
            camHeading = 0.0;
          }
        } else {
          // 目的地方向上
          if (_hasManualHeading && !_canRotate) {
            // 低速且有手動 → 維持手動角度
            camHeading = _manualHeadingDeg!;
          } else if (_canRotate) {
            // 達門檻 → 自動依行進方向
            camHeading = (heading != 0 ? heading : _headingDeg);
          } else {
            // 低速且無手動 → 凍結目前角度
            camHeading = _cameraHeadingDeg;
          }
        }
        if ((_cameraHeadingDeg - camHeading).abs() > 0.1) {
          setState(() {
            _cameraHeadingDeg = camHeading;
          });
        }
        final cp = CameraPosition(
          target: last!,
          zoom: _zoomNow,
          heading: camHeading,
          pitch: 0,
        );
        _lastCam = cp;
        await _moveCamera(CameraUpdate.newCameraPosition(cp));
      }

      _lastRouteLen = len;
      _prevLast = last;
      if (_current == null && last != null) {
        _pushRecent(last);
      }

      // Update movement state based on route changes
      final now = DateTime.now();
      if (changed) {
        _lastMoveAt = now;
      }
      if (_lastMoveAt != null) {
        // 若 1.2 秒內都有變化則視為移動中
        final moving = now.difference(_lastMoveAt!).inMilliseconds < 1200;
        if (moving != _isMoving) {
          setState(() {
            _isMoving = moving;
          });
          // 只要開始移動，就把相機拉回路徑末端（不可平移，但仍可縮放）
          // if (moving) {
          //   _applyCameraForMode();
          // }
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant MapModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liveSpeedMps != widget.liveSpeedMps) {
      if (oldWidget.liveSpeedMps != null && _liveSpeedListener != null) {
        oldWidget.liveSpeedMps!.removeListener(_liveSpeedListener!);
      }
      if (widget.liveSpeedMps != null) {
        _liveSpeedListener = () {
          final mps = widget.liveSpeedMps!.value;
          final kmh = mps * 3.6;
          final display = _useMiles ? (kmh * 0.621371) : kmh;
          final moving = mps > 0.5;
          setState(() {
            _lastMps = mps;
            _speedDisplay = display;
            _isMoving = moving;
            if (moving) _lastMoveAt = DateTime.now();
          });
          // 錄製中且第一次跨過 10 km/h → 視為開始記錄
          if (_recording &&
              !_passedStartGate &&
              _lastMps >= kRecordStartMinSpeedMps) {
            setState(() {
              _passedStartGate = true;
            });
          }
          // 超過門檻（>5 km/h）恢復自動轉向
          if (_lastMps > kRotateMinSpeedMps && _hasManualHeading) {
            _manualHeadingDeg = null;
          }
        };
        widget.liveSpeedMps!.addListener(_liveSpeedListener!);
        _liveSpeedListener!();
      }
    }
    // Keep local recording flag in sync with parent
    if (oldWidget.recording != widget.recording) {
      setState(() {
        _recording = widget.recording;
        // whenever recording status is externally toggled, reset start gate
        _passedStartGate = false;
      });
    }
  }

  @override
  void dispose() {
    _routeWatch?.cancel();
    _posSub?.cancel();
    if (widget.liveSpeedMps != null && _liveSpeedListener != null) {
      widget.liveSpeedMps!.removeListener(_liveSpeedListener!);
    }
    super.dispose();
  }

  Future<void> _initLocationStream() async {
    // 權限
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1, // 1m 更新
      ),
    ).listen(_onPosition);
  }

  void _onPosition(Position p) {
    // 速度（m/s -> km/h）。過濾少於 0.3 m/s (~1 km/h) 的微動。
    if (widget.liveSpeedMps == null) {
      final mps = p.speed.isFinite ? p.speed : 0.0;
      _lastMps = mps;
      final kmh = (mps < 0.3) ? 0.0 : (mps * 3.6);
      final display = _useMiles ? (kmh * 0.621371) : kmh;
      setState(() {
        _speedDisplay = display;
        final moving = mps > 0.5;
        _isMoving = moving;
        if (moving) _lastMoveAt = DateTime.now();
      });
      // 錄製中且第一次跨過 10 km/h → 視為開始記錄（未用 liveSpeedMps 時適用）
      if (_recording &&
          !_passedStartGate &&
          _lastMps >= kRecordStartMinSpeedMps) {
        setState(() {
          _passedStartGate = true;
        });
      }
    }

    // Removed block that appends to widget.route

    // 記住裝置 heading（只在移動中且角度可信時才覆寫）
    if (p.heading.isFinite) {
      final mps = p.speed.isFinite ? p.speed : 0.0;
      final movingEnough = mps > 0.8; // ~2.9 km/h，過慢時指南針不穩定
      final hdg = p.heading;
      final accOk = (p.headingAccuracy.isNaN || p.headingAccuracy <= 25.0);
      if (movingEnough && accOk && hdg != 0.0) {
        _headingDeg = hdg;
        _lastValidHeadingDeg = hdg;
      }
    }

    // 相機跟隨
    _current = LatLng(p.latitude, p.longitude);
    _pushRecent(_current!);
    if (_mapController != null) {
      double headingForCam;
      if (_mode == MapCameraMode.northUp) {
        if (!_canRotate && _hasManualHeading) {
          headingForCam = _manualHeadingDeg!; // 低速可維持手動角度
        } else {
          headingForCam = 0.0; // 回正北
        }
      } else {
        if (_hasManualHeading && !_canRotate) {
          headingForCam = _manualHeadingDeg!; // 低速維持手動角度
        } else if (_canRotate) {
          headingForCam = p.heading.isFinite ? p.heading : _headingDeg; // 自動
        } else {
          headingForCam = _cameraHeadingDeg; // 低速凍結
        }
      }
      // 若已交給 Apple Maps 原生追蹤，就不要在這裡再手動移動相機，避免互相搶鏡頭。
      if (_trackingMode != TrackingMode.none) {
        _refreshAnnotations();
        return;
      }
      final cam = CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(p.latitude, p.longitude),
          zoom: _zoomNow,
          heading: headingForCam,
          pitch: 0,
        ),
      );
      if (_followCamera) {
        setState(() {
          _cameraHeadingDeg = headingForCam;
        });
        _lastCam = CameraPosition(
          target: LatLng(p.latitude, p.longitude),
          zoom: _zoomNow,
          heading: headingForCam,
          pitch: 0,
        );
        _moveCamera(cam);
      }
      _refreshAnnotations();
    }
  }

  void _jumpToCurrent({double? zoom, bool force = false}) {
    if (_inZoomGuard) return;
    if (_mapController == null) return;

    LatLng? focus;
    if (_current != null) {
      focus = _current;
    } else if (widget.route.isNotEmpty) {
      focus = widget.route.last;
    } else if (_prevLast != null) {
      focus = _prevLast;
    }
    if (focus == null) return;
    if (_trackingMode != TrackingMode.none && !force) {
      // 交給原生追蹤，僅更新狀態即可
      setState(() {});
      return;
    }

    double heading = 0;
    if (_mode == MapCameraMode.headingUp) {
      if (_current != null && _prevLast != null) {
        heading = _bearing(_prevLast!, focus);
      } else if (widget.route.length >= 2) {
        heading = _bearing(
          widget.route[widget.route.length - 2],
          widget.route.last,
        );
      }
      if (heading == 0) {
        heading = (_headingDeg != 0)
            ? _headingDeg
            : _lastValidHeadingDeg; // keep last known heading when stationary
      }
    }
    // 低速（≤2 km/h）時不旋轉，但仍然跳到最新位置
    // 依模式與速度決定相機角度（允許低速手動角度）
    if (_mode == MapCameraMode.northUp) {
      if (!_canRotate && _hasManualHeading) {
        heading = _manualHeadingDeg!; // 低速維持手動角度
      } else {
        heading = 0.0; // 立刻回正北
      }
    } else {
      if (_hasManualHeading && !_canRotate) {
        heading = _manualHeadingDeg!; // 低速維持手動角度
      } else if (_canRotate) {
        // 可旋轉 → 使用前面算出的 heading
      } else {
        heading = _cameraHeadingDeg; // 低速凍結目前角度
      }
    }

    _cameraHeadingDeg = heading;
    final cp = CameraPosition(
      target: focus,
      zoom: zoom ?? _zoomNow,
      heading: heading,
      pitch: 0,
    );
    _lastCam = cp;
    _moveCamera(CameraUpdate.newCameraPosition(cp));
  }

  // 重新武裝原生 heading 追蹤：
  // 1) 保證為 headingUp
  // 2) 先確保跟隨開啟，再短暫關閉→下一幀再開啟，強迫 AppleMap 重新套用 trackingMode
  void _rearmNativeHeadingTracking({bool recenter = true, double? zoom}) {
    final savedZoom = zoom ?? _zoomNow;
    setState(() {
      _mode = MapCameraMode.headingUp;
      _manualHeadingDeg = null;
      MapModePage._lastMode = _mode;
      _followCamera = true;
      _currentZoom = savedZoom;
    });
    if (recenter) {
      _jumpToCurrent(zoom: savedZoom, force: true);
    }
    // 透過一次“脈衝”切換強制 plugin 重新套 trackingMode
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _followCamera = false;
      });
      // 極短延遲後再打開，避免與當前 frame 合併
      Future.delayed(const Duration(milliseconds: 16), () {
        if (!mounted) return;
        setState(() {
          _followCamera = true;
          _currentZoom = savedZoom;
        });
        if (recenter) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _jumpToCurrent(zoom: savedZoom, force: true);
          });
        }
      });
    });
  }

  // 右下角「定位」FAB 的行為（依模式區分）：
  // 北上模式：只回定位且維持北上（不出現扇形、不跟手機旋轉）
  // 目的地方向上：回定位＋立刻啟用原生扇形並隨手機旋轉
  void _onLocateFabPressed() {
    final savedZoom = _zoomNow;
    // 不再使用雙擊流程
    _locatePrimed = false;
    _locatePrimedAt = null;

    if (_mode == MapCameraMode.northUp) {
      // ★ 永遠北上：回定位、維持北上、不開扇形
      setState(() {
        _headingFollowTransient = false; // 確保不啟用暫時 heading 追蹤
        _followCamera = true; // 開啟跟隨，但 trackingMode 只會是 follow（不旋轉）
        _manualHeadingDeg = null; // 清手動角度，避免殘留
        _cameraHeadingDeg = 0.0; // 北方在上
        _currentZoom = savedZoom;
      });
      _jumpToCurrent(zoom: savedZoom, force: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _jumpToCurrent(zoom: savedZoom, force: true);
      });

      return;
    }

    // ★ 目的地方向上：回定位＋原生 followWithHeading（顯示扇形、跟手機旋轉）
    _engageTransientHeadingTracking(recenter: true, zoom: savedZoom);
  }

  Future<void> _moveCamera(CameraUpdate cu) async {
    if (_mapController == null) return;
    _progCamMove = true;
    try {
      await _mapController!.moveCamera(cu);
    } finally {
      // 稍微延後關閉，避免 onCameraIdle 尚未觸發就被判定
      Future.delayed(const Duration(milliseconds: 10), () {
        _progCamMove = false;
      });
    }
  }

  void _refreshPolyline() {
    // 將路徑切成多段，避免單一 polyline 點數過多在 Apple Maps 上偶發斷線/不重繪；
    // 同時每次呼叫切換一組 id，確保 SDK 會真正重繪。
    const int chunk = 400; // 每段最多 400 點（保守值）
    final pidPrefix = 'route_${_polyVersion % 2}_';
    _polyVersion++;

    // 先清掉舊的 route_* polyline，避免殘留
    _polylines.removeWhere((e) => e.polylineId.value.startsWith('route_'));

    if (_displayRoute.length < 2) {
      setState(() {}); // 仍觸發一次刷新以清空
      return;
    }

    final newPolys = <Polyline>{};
    int idx = 0;
    for (int i = 0; i < _displayRoute.length - 1; i += chunk - 1) {
      final end = math.min(i + chunk, _displayRoute.length);
      final seg = _displayRoute.sublist(i, end);
      if (seg.length < 2) continue;
      final id = PolylineId('$pidPrefix${idx++}');
      newPolys.add(
        Polyline(
          polylineId: id,
          width: 4,
          color: _primary,
          points: List<LatLng>.from(seg),
          consumeTapEvents: false,
          zIndex: 1,
        ),
      );
    }

    setState(() {
      _polylines.addAll(newPolys);
    });
  }

  void _refreshAnnotations() {
    final ann = <Annotation>{};

    // 起點：系統預設大頭針（紅色）
    if (widget.route.isNotEmpty) {
      ann.add(
        Annotation(
          annotationId: AnnotationId('start'),
          position: widget.route.first,
          icon: BitmapDescriptor.defaultAnnotation,
          zIndex: 1,
        ),
      );

      // 終點：
      // 1) 若目前有定位（myLocationEnabled 會顯示藍點），就不再放終點針，避免兩個一樣的紅針。
      // 2) 若尚無定位可用，才放一支終點針作為參考。
      final hasCurrent = _current != null;
      if (!hasCurrent) {
        ann.add(
          Annotation(
            annotationId: AnnotationId('end'),
            position: widget.route.last,
            icon: BitmapDescriptor.defaultAnnotation,
            zIndex: 2,
          ),
        );
      }
    }

    setState(() {
      _annotations
        ..clear()
        ..addAll(ann);
    });
  }

  double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = math.atan2(y, x) * 180 / math.pi;
    return (brng + 360) % 360;
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return R * c;
  }

  void _switchMode(MapCameraMode m) {
    if (_mode == m) return;
    setState(() {
      _mode = m;
      // 使用者明確切換模式後，取消暫時 heading 追蹤
      _headingFollowTransient = false;
      // 切「目的地方向上」自動開啟跟隨
      if (m == MapCameraMode.headingUp) {
        _followCamera = true;
      }
      // 切「北方在上」立即轉正北並清除手動角度
      if (m == MapCameraMode.northUp) {
        _manualHeadingDeg = null;
        _cameraHeadingDeg = 0.0;
      }
    });
    MapModePage._lastMode = m;
    // 強制立即更新相機狀態（不同模式下立即切換定位/heading）
    if (m == MapCameraMode.northUp) {
      // 立刻回正北並回到目前位置（忽略原生追蹤的早退）
      _currentZoom = _zoomNow;
      _jumpToCurrent(zoom: _currentZoom, force: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _jumpToCurrent(zoom: _currentZoom, force: true);
      });
    } else {
      // headingUp：立即啟用原生扇形並隨手機旋轉，同時回到目前位置
      _rearmNativeHeadingTracking(recenter: true, zoom: _zoomNow);
    }
  }

  void _applyCameraForMode() {
    if (_mapController == null) return;
    // 啟用原生追蹤時，交給 Apple Maps 自行置中/旋轉
    if (_trackingMode != TrackingMode.none) {
      setState(() {});
      return;
    }
    // 目標焦點：優先使用軌跡末點，其次目前定位，再其次上一拍末點
    LatLng? focus;
    if (widget.route.isNotEmpty) {
      focus = widget.route.last;
    } else if (_current != null) {
      focus = _current;
    } else if (_prevLast != null) {
      focus = _prevLast;
    }
    if (focus == null) return;

    // 計算方位
    double computedHeading = 0;
    if (_mode == MapCameraMode.headingUp) {
      // 1) 盡量用顯示用路徑（避免主資料只覆寫末點導致長度不足）
      if (_displayRoute.length >= 2) {
        final a = _displayRoute[_displayRoute.length - 2];
        final b = _displayRoute[_displayRoute.length - 1];
        computedHeading = _bearing(a, b);
      } else if (widget.route.length >= 2) {
        computedHeading = _bearing(
          widget.route[widget.route.length - 2],
          widget.route.last,
        );
      } else if (_prevLast != null &&
          (focus.latitude != _prevLast!.latitude ||
              focus.longitude != _prevLast!.longitude)) {
        computedHeading = _bearing(_prevLast!, focus);
      } else {
        // 沒有移動或不足以計算方位：沿用最後一次已知 heading（保持「目的地方向上」）
        computedHeading =
            (_headingDeg != 0) ? _headingDeg : _lastValidHeadingDeg;
      }
    } else {
      computedHeading = 0; // northUp
    }

    // 依模式/門檻/手動角度調整
    if (_mode == MapCameraMode.northUp) {
      // 北上：低速可維持手動角度；達門檻或一般情況回正 0°
      if (!_canRotate && _hasManualHeading) {
        computedHeading = _manualHeadingDeg ?? _cameraHeadingDeg;
      } else {
        computedHeading = 0.0;
      }
    } else {
      // 目的地方向上
      if (_hasManualHeading && !_canRotate) {
        computedHeading = _manualHeadingDeg!;
      } else if (_canRotate) {
        // 達門檻 → 使用已計算的 computedHeading
      } else {
        // 低速且沒有手動角度 → 凍結目前角度
        computedHeading = _cameraHeadingDeg;
      }
    }

    final shouldUpdateHeading = true;

    _cameraHeadingDeg = shouldUpdateHeading ? computedHeading : 0.0;
    final cp = CameraPosition(
      target: focus,
      zoom: _currentZoom,
      heading: shouldUpdateHeading ? computedHeading : 0.0,
      pitch: 0,
    );
    _lastCam = cp;
    _moveCamera(CameraUpdate.newCameraPosition(cp));
  }

  void _showControlsSheetInMap() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 返回主頁（將原本主頁的「地圖模式」在此替換成返回）
              ListTile(
                leading: const Icon(Icons.home, color: Colors.white),
                title: Text(
                  L10n.t('back_home'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).maybePop();
                },
              ),
              // 開始/暫停 記錄
              ListTile(
                leading: Icon(
                  _recording ? Icons.pause : Icons.play_arrow,
                  color: _recording ? cs.tertiary : cs.primary,
                ),
                title: Text(
                  _recording
                      ? L10n.t('pause_recording')
                      : L10n.t('start_recording'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  widget.onToggleRecord();
                  setState(() {
                    _recording = !_recording;
                    // 每次切換錄製狀態時重置起步門檻狀態
                    _passedStartGate = false;
                  });
                },
              ),
              // 結束旅程並儲存（與主頁相同流程）
              ListTile(
                leading: const Icon(Icons.flag, color: Colors.white),
                title: Text(
                  L10n.t('end_and_save'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                onTap: () async {
                  // 關閉面板
                  Navigator.of(context).pop();
                  _armZoomGuard(1600);
                  // snapshot and re-apply zoom immediately to prevent map from auto-zooming due to panel/dialog close
                  final savedZoom = _currentZoom;
                  // 先強制把相機拉回目前位置並維持縮放，避免因為面板/對話框收合造成地圖自動縮放。
                  _followCamera = true;
                  _jumpToCurrent(zoom: savedZoom);
                  if (widget.onStopAndSaveResult != null) {
                    final ok = await widget.onStopAndSaveResult!();
                    _armZoomGuard(1600);
                    if (!mounted) return;
                    if (!ok) {
                      // 未達保存條件（例如移動/時間太短）→ 給提示
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(L10n.t('save_condition_not_met')),
                        ),
                      );
                      // 保持畫面狀態不變即可
                      return;
                    }
                    setState(() {
                      _currentZoom = savedZoom;
                      _followCamera = true;
                    });
                    _jumpToCurrent(zoom: savedZoom);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _jumpToCurrent(zoom: savedZoom);
                      }
                    });
                  } else if (widget.onStopAndSave != null) {
                    await widget.onStopAndSave!();
                    _armZoomGuard(1600);
                    if (!mounted) return;
                    setState(() {
                      _currentZoom = savedZoom;
                      _followCamera = true;
                    });
                    _jumpToCurrent(zoom: savedZoom);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _jumpToCurrent(zoom: savedZoom);
                      }
                    });
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(L10n.t('save_not_wired'))),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String get _speedText {
    // 四捨五入顯示整數（0~999）
    final v = _speedDisplay.clamp(0, 999);
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Apple Map 會依時間自動夜間樣式，這裡用平台外觀推測（若系統是自動外觀，夜間時此值會是 dark）。
    final platformDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final mapLooksDark = isDark || platformDark; // 兩者其一為深色就視為地圖是暗夜模式
    final speedTextColor = mapLooksDark ? Colors.white : Colors.black;
    final speedBadgeColor = mapLooksDark
        ? Colors.black.withOpacity(kSpeedBadgeOpacity)
        : Colors.white.withOpacity(kSpeedBadgeOpacity);
    final compassBadgeColor = mapLooksDark
        ? Colors.black.withOpacity(kCompassBadgeOpacity)
        : Colors.white.withOpacity(kCompassBadgeOpacity);

    final bool is3digit = _speedText.length >= 3;
    final double badgeSize = is3digit ? 260.0 : 240.0; // 放大圓匡，避免過於貼字

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // 地圖
          AppleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(23.902, 120.545),
              zoom: 14,
            ),
            onMapCreated: (c) {
              _mapController = c;
              // 以可用的焦點初始化快取相機位置：優先路徑末點 → 目前定位 → 上一拍末點 → 固定後備
              LatLng initialTarget;
              if (widget.route.isNotEmpty) {
                initialTarget = widget.route.last;
              } else if (_current != null) {
                initialTarget = _current!;
              } else if (_prevLast != null) {
                initialTarget = _prevLast!;
              } else {
                initialTarget = const LatLng(23.902, 120.545); // 後備
              }
              _lastCam = CameraPosition(
                target: initialTarget,
                zoom: _zoomNow,
                heading: _cameraHeadingDeg,
                pitch: 0,
              );
              _followCamera = true; // 進入即跟隨
              // 地圖建立後立刻依模式轉正並移到焦點
              _applyCameraForMode();
              // 再補一拍（200ms）重試，確保相機狀態到位
              Future.delayed(const Duration(milliseconds: 200), () {
                if (!mounted) return;
                if (_mapController != null) {
                  _applyCameraForMode();
                }
              });
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            trackingMode: _trackingMode, // ★ 交給原生追蹤（置中/旋轉）
            compassEnabled: false,
            polylines: _polylines,
            annotations: _annotations,
            // 原本：rotateGesturesEnabled: _mode == MapCameraMode.headingUp && !_isMoving,
            rotateGesturesEnabled: true,
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            onCameraMoveStarted: () {
              if (_inZoomGuard) return; // 忽略系統動畫引發的事件
              if (_progCamMove) return; // 程式主動移動
              if (_trackingMode != TrackingMode.none) {
                // 原生追蹤（含扇形旋轉/置中）造成的移動，不能當成使用者手勢
                return;
              }
              // 標記確實為使用者操作，並初始化門檻度量
              _userGesture = true;
              // （移除：使用者手動操作 → 關閉跟隨，交由 onCameraIdle 判斷是否關閉）
              _lastUserGestureAt = DateTime.now();
              _gestureStartAt = _lastUserGestureAt;
              _gestureMovedMeters = 0;
              _gestureZoomDelta = 0;
              _gestureHeadingDelta = 0;
              // 讀取當前相機做為起點
              final cam = _lastCam;
              if (cam != null) {
                _gestureStartTarget = cam.target;
                _gestureStartZoom = cam.zoom;
              }
            },
            onCameraMove: (position) {
              if (_inZoomGuard) return; // 忽略系統動畫
              if (_progCamMove) return; // 程式移動

              final hNow = position.heading; // 目前相機朝向（由 SDK 提供）

              // ★ 原生追蹤期間：允許更新指南針角度，但不要當成使用者手勢、也不要累積門檻
              if (_trackingMode != TrackingMode.none) {
                if (hNow != null && hNow.isFinite) {
                  setState(() {
                    _cameraHeadingDeg = hNow;
                  });
                }
                // 同步快取相機狀態（不影響手勢統計）
                _currentZoom = position.zoom.clamp(3.0, 20.0);
                _lastCam = CameraPosition(
                  target: position.target,
                  zoom: _currentZoom,
                  heading: hNow ?? _cameraHeadingDeg,
                  pitch: position.pitch ?? 0,
                );
                return; // 不做手勢累積/判斷
              }

              // 以下僅在使用者手勢期間統計門檻
              if (!_userGesture) return;

              // 統計累積位移/縮放/旋轉門檻
              final z = position.zoom.clamp(3.0, 20.0);
              if (_gestureStartTarget != null) {
                _gestureMovedMeters = _distanceMeters(
                  _gestureStartTarget!,
                  position.target,
                );
                _gestureZoomDelta = (z - _gestureStartZoom).abs();
                _gestureHeadingDelta =
                    (((hNow ?? 0.0) - _cameraHeadingDeg) % 360).abs();
                if (_gestureHeadingDelta > 180)
                  _gestureHeadingDelta = 360 - _gestureHeadingDelta;
              }

              // 更新本地即時狀態（不關閉跟隨）
              _currentZoom = z;
              if (hNow != null && hNow.isFinite) {
                setState(() {
                  _cameraHeadingDeg = hNow;
                });
              }
              _lastCam = CameraPosition(
                target: position.target,
                zoom: _currentZoom,
                heading: hNow ?? _cameraHeadingDeg,
                pitch: position.pitch ?? 0,
              );
            },
            onCameraIdle: () {
              if (_inZoomGuard) return;

              // 若這一段移動是由原生追蹤觸發（例如 followWithHeading 的扇形旋轉/置中），
              // 不要關閉跟隨、也不要記錄手動角度；直接重置手勢狀態。
              if (_trackingMode != TrackingMode.none) {
                if (_userGesture) {
                  // 使用者完成手勢後退出暫時 heading 追蹤（保留原本模式 semantics）
                  if (_headingFollowTransient) {
                    setState(() {
                      _headingFollowTransient = false;
                    });
                  }
                }
                _userGesture = false;
                _gestureStartAt = null;
                _gestureStartTarget = null;
                _gestureMovedMeters = 0;
                _gestureZoomDelta = 0;
                _gestureHeadingDelta = 0;
                return;
              }

              if (_userGesture) {
                // 只有「平移/縮放」才關閉跟隨；旋轉則記錄手動角度
                final movedEnough = _gestureMovedMeters > 25;
                final zoomedEnough = _gestureZoomDelta > 0.15;
                final rotatedEnough = _gestureHeadingDelta > 5;

                if ((movedEnough || zoomedEnough) && _followCamera) {
                  setState(() {
                    _followCamera = false; // 讓使用者自由移動/縮放
                    _zoomRestoreSeq++; // 使用者介入時取消待處理的縮放復原
                  });
                }
                if (rotatedEnough) {
                  // 記錄使用者希望維持的角度（直到速>5km/h 才自動清除並轉回）
                  _manualHeadingDeg = _cameraHeadingDeg;
                }
              }

              // 重置手勢狀態
              _userGesture = false;
              _gestureStartAt = null;
              _gestureStartTarget = null;
              _gestureMovedMeters = 0;
              _gestureZoomDelta = 0;
              _gestureHeadingDelta = 0;
            },
          ),

          // 中央大型時速
          Positioned(
            top: MediaQuery.of(context).padding.top + 64,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  color: speedBadgeColor,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _speedText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: is3digit ? 116 : 136,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                        color: speedTextColor,
                        shadows: const [
                          Shadow(blurRadius: 2, offset: Offset(0, 1)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _useMiles ? 'MPH' : 'KM/H',
                      style: TextStyle(
                        fontSize: 20,
                        letterSpacing: 2,
                        color: speedTextColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 左上角：錄製狀態
          Positioned(
            left: 12,
            top: MediaQuery.of(context).padding.top + 12,
            child: _StatusChip(
              // 錄製中顯示紅點，未錄製顯示暫停圖示
              icon: _recording ? Icons.fiber_manual_record : Icons.pause_circle,
              // 改成：只要「正在錄製」且偵測到自動暫停條件，就顯示「自動暫停中」，
              // 即使尚未跨過 10 km/h 起步門檻也一樣要顯示。
              label: _recording
                  ? (_isAutoPaused
                      ? L10n.t('auto_paused')
                      : (_passedStartGate
                          ? L10n.t('recording')
                          : L10n.t('paused')))
                  : L10n.t('paused'),
            ),
          ),

          // 瀏海下方置中：指南針（顯示目前相機朝向）
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            left: 0,
            right: 0,
            child: Center(
              child: _CompassChip(
                headingDeg: _cameraHeadingDeg,
                bgColor: compassBadgeColor,
                nColor: mapLooksDark
                    ? Colors.white.withOpacity(0.9)
                    : Colors.black.withOpacity(0.9),
              ),
            ),
          ),

          // 右上角：切換模式（北上 / 車頭朝上）
          Positioned(
            right: 12,
            top: MediaQuery.of(context).padding.top + 12,
            child: _ModeSwitcher(mode: _mode, onChanged: _switchMode),
          ),

          // 右下角：選單按鈕（與主頁同風格），包含跳回目前位置
          Positioned(
            right: 16,
            bottom: 24 + MediaQuery.of(context).padding.bottom,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 跳回目前位置
                FloatingActionButton.small(
                  heroTag: 'jump_to_current',
                  onPressed: _onLocateFabPressed,
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 12),
                // 原本選單
                FloatingActionButton(
                  heroTag: 'more_menu',
                  onPressed: _showControlsSheetInMap,
                  child: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: cs.onSurface, fontSize: 13)),
        ],
      ),
    );
  }
}

class _CompassChip extends StatelessWidget {
  const _CompassChip({
    required this.headingDeg,
    required this.bgColor,
    required this.nColor,
  });
  final double headingDeg;
  final Color bgColor;
  final Color nColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: Border.all(color: cs.outlineVariant.withOpacity(0)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 北方標記
          Positioned(
            top: -1.5,
            child: Text(
              'N',
              style: TextStyle(
                fontSize: 12,
                color: nColor,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          // 方向箭頭（依 heading 旋轉），往下偏移 2px
          Transform.translate(
            offset: const Offset(0, 2),
            child: Transform.rotate(
              angle: headingDeg * math.pi / 180.0,
              child: Icon(
                Icons.navigation_rounded,
                size: 32,
                color: cs.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({required this.mode, required this.onChanged});
  final MapCameraMode mode;
  final ValueChanged<MapCameraMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          _seg(
            context,
            icon: Icons.explore,
            active: mode == MapCameraMode.northUp,
            onTap: () => onChanged(MapCameraMode.northUp),
          ),
          const SizedBox(width: 6),
          _seg(
            context,
            icon: Icons.navigation_rounded,
            active: mode == MapCameraMode.headingUp,
            onTap: () => onChanged(MapCameraMode.headingUp),
          ),
        ],
      ),
    );
  }

  Widget _seg(
    BuildContext context, {
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: active ? cs.onPrimary : cs.onSurface),
          ],
        ),
      ),
    );
  }
}
