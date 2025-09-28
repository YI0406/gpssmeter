import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'trip.dart';
import 'ad.dart';
import 'purchase_service.dart';
import 'package:uni_links/uni_links.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

import 'mapmode.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'camera.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am;
import 'package:flutter/material.dart';
// Global navigator key for use throughout the app.
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'accel_page.dart';

import 'package:gps_speedometer_min/setting.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
// 全局 UI 動畫時長（數字/指針補間）
const int kUiAnimMs = 100; // 原 220ms → 更快更靈敏

// Default gauge max speed (km/h)
const double kDefaultMaxKmh = 160.0;

// 嚴格停止門檻（小於此值一律視為停止）
const double kStrictStopKmh = 2.0; // 原 1.0 → 2.0 km/h
const double kStrictStopMps = kStrictStopKmh / 3.6; // ≈ 0.5556 m/s

// 顯示用「歸零/恢復」雙門檻（抖動抑制 + 走路仍可顯示）
const double kZeroSnapKmh = 0.5; // 低於此值且確定幾乎未移動 → 立刻顯示 0
const double kZeroReleaseKmh = 2.0; // 速度回到此值以上才「離開 0」
const double kLowBlendKmh = 7.0; // 低速區域（~步行）使用混合估計，不再取 min 導致誤歸零
const double kZeroSnapMps = kZeroSnapKmh / 3.6;
const double kZeroReleaseMps = kZeroReleaseKmh / 3.6;
const double kLowBlendMps = kLowBlendKmh / 3.6;

// ===== GPS 抑噪與防暴衝參數 =====
const double kBadHAccMeters = 25.0; // 水平精度差：> 25m 視為不可靠
const double kBadSpdAccMps = 2.0; // 速度精度差：> 2 m/s 視為不可靠
const double kMinDtForSpeed = 0.05; // 相鄰樣本最小時間差（秒）
const double kAccelClampMps2 = 6.0; // 速度變化上限（加速度夾制）6 m/s^2 ≈ 21.6 km/h/s
const double kSpikeGapMps = 8.0; // 異常尖峰判斷：若裝置速度超過距離速度 + 8 m/s 且距離速度很低 → 視為尖峰
// 近窗位移快速歸零（硬煞/原地晃動時避免卡在 3~5km/h）
const double kStopWindowSec = 2.0; // 檢查最近 2 秒
const double kStopWindowDist = 1.0; // 總位移 < 1.0 m 視為停止，顯示 0

// 旅程保存最小門檻（只移動很短就不存）
const int kMinMovingSecondsToSave = 2; // 少於 2秒不保存

// 設定檔案名稱
const String kSettingsFile = 'settings.json';

// 全局主題色（MaterialApp 監聽它即可熱更新）
final ValueNotifier<Color> appThemeSeed = ValueNotifier<Color>(Colors.green);
final ValueNotifier<bool> appLightMode =
    ValueNotifier<bool>(false); // false=暗夜, true=白天

/// Request App Tracking Transparency on iOS before initializing ad SDKs.
Future<void> _requestATTIfNeeded() async {
  if (!Platform.isIOS) return;
  try {
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) {
      // Give iOS a brief moment to ensure the dialog can be presented cleanly.
      await Future.delayed(const Duration(milliseconds: 200));
      await AppTrackingTransparency.requestTrackingAuthorization();
    }
  } catch (e) {
    debugPrint('ATT request error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _handleIncomingShortcut(); // 加這行來支援捷徑動作
  _handleShortcut(); // 加這行來支援捷徑動作
  await Setting.loadFromPrefs(); // ← 在這裡全域灌值
  try {
    debugPrint('🔥 Firebase init: start');
    // iOS 原生已完成 configure，這裡用「不帶 options」即可接上 default app
    await Firebase.initializeApp();
    debugPrint('✅ Firebase init: done');
  } catch (e, st) {
    debugPrint('❌ Firebase init failed: $e\n$st');
  }
  // 鎖定螢幕方向：只允許直向模式
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // 初始化內購（啟動只需一次），先載入本機 VIP 狀態
  await PurchaseService().initStoreInfo();
  debugPrint('📲 啟動時購買狀態：${PurchaseService().isPremiumUnlocked}');

  // Request ATT prior to initializing ads (iOS only)
  await _requestATTIfNeeded();
  // 初始化 AdMob
  await AdService.instance.init();

  runApp(const MyApp());
}

void _handleShortcut() {
  final uri = Uri.base;
  if (uri.scheme == 'gpssmeter' && uri.host == 'maptrack') {
    Future.microtask(() {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => MapModePage(
            initialMode: MapCameraMode.headingUp,
            route: const [],
            recording: false,
            onToggleRecord: () {},
          ),
        ),
      );
    });
  } else if (uri.scheme == 'gpssmeter' && uri.host == 'accel') {
    print('📲 捷徑觸發：打開加速模式頁');
    Future.microtask(() {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => AccelPage(
            mode: AccelMode.zeroTo100,
          ),
        ),
      );
    });
  }
}

void _handleIncomingShortcut() {
  getInitialUri().then((uri) {
    if (uri != null) {
      debugPrint('📥 Shortcut URI received at launch: $uri');
      _handleUriAction(uri);
    }
  });

  uriLinkStream.listen((uri) {
    if (uri != null) {
      debugPrint('🔄 Shortcut URI received in background: $uri');
      _handleUriAction(uri);
    }
  });
}

void _handleUriAction(Uri uri) {
  final action = (uri.host.isNotEmpty
          ? uri.host
          : uri.pathSegments.isNotEmpty
              ? uri.pathSegments.first
              : uri.queryParameters['target'])
      ?.toLowerCase();
  if (action == 'maptrack' || action == 'map_track') {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => MapModePage(
          initialMode: MapCameraMode.headingUp,
          route: const [], // 空的路徑清單
          recording: false, // 非錄影中
          onToggleRecord: () {}, // 空的 callback
        ),
      ),
    );
  } else if (action == 'accel') {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => const AccelPage(
          mode: AccelMode.zeroTo100,
        ),
      ),
    );
  }
}

/// ===== 模型 =====
class Trip {
  DateTime startAt;
  DateTime? endAt;

  double distanceMeters = 0; // 總里程
  double maxSpeedMps = 0; // 最高速（m/s）
  double avgSpeedMps = 0; // 平均移動速度（m/s）
  int movingSeconds = 0; // 移動秒數
  int stoppedSeconds = 0; // 停止秒數（自動暫停）

  // 天氣（保存當下快照，供旅程回看）
  String? weatherProvider; // e.g. 'open-meteo'
  double? weatherTempC; // 攝氏溫度
  DateTime? weatherAt; // 量測時間
  double? weatherLat; // 取得天氣時的經緯度（近似）
  double? weatherLon;

  String? name;
  List<TrackSample> samples = [];

  String? unit; // 'km' or 'mi' at the time of saving

  Trip(this.startAt, {this.name});

  Map<String, dynamic> toJson() => {
        'startAt': startAt.toIso8601String(),
        'endAt': endAt?.toIso8601String(),
        'distanceMeters': distanceMeters,
        'maxSpeedMps': maxSpeedMps,
        'avgSpeedMps': avgSpeedMps,
        'movingSeconds': movingSeconds,
        'stoppedSeconds': stoppedSeconds,
        'name': name,
        'unit': unit,
        'samples': samples.map((e) => e.toJson()).toList(),
        // weather snapshot
        'weatherProvider': weatherProvider,
        'weatherTempC': weatherTempC,
        'weatherAt': weatherAt?.toIso8601String(),
        'weatherLat': weatherLat,
        'weatherLon': weatherLon,
      };
}

/// 單一軌跡點
class TrackSample {
  final DateTime ts;
  final double lat;
  final double lon;
  final double? alt; // meters
  final double speedMps;
  final bool autoPaused;
  final bool manuallyPaused;

  TrackSample({
    required this.ts,
    required this.lat,
    required this.lon,
    required this.speedMps,
    this.alt,
    this.autoPaused = false,
    this.manuallyPaused = false,
  });

  Map<String, dynamic> toJson() => {
        'ts': ts.toIso8601String(),
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'speedMps': speedMps,
        'autoPaused': autoPaused,
        'manuallyPaused': manuallyPaused,
      };
}

/// 最近位移樣本（用於 3 秒視窗判斷是否真的停下來）
class _RecentMove {
  final DateTime ts;
  final double d; // meters moved since previous sample
  const _RecentMove(this.ts, this.d);
}

/// ===== 追蹤核心（含自動暫停/恢復、速度平滑） =====
class TrackingService {
  StreamSubscription<Position>? _sub;
  Trip? _trip;

  // 速度平滑（指數移動平均）
  double _emaSpeed = 0;
  DateTime? _lastTs;
  Position? _lastPos;

  final List<TrackSample> _samples = [];

  // 近幾秒位移視窗，用來精準判定「真的停下來」
  final List<_RecentMove> _recentMoves = [];

  // 顯示是否鎖在 0（雙門檻抑制抖動）
  bool _displayZero = false;

  // ===== 模擬模式（內建路線） =====
  bool enableMockRoute = false; // 模擬模式開關（先不做 UI，之後從設定頁切）
  //bool enableMockRoute = true; // ← 開啟模擬模式
  Timer? _mockTimer;
  int _mockTick = 0; // 0.5 秒為單位的 tick 計數
  DateTime? _mockStartAt;
  double _mockLat = 24.16362;
  double _mockLon = 120.64770;
  double _mockAlt = 30.0; // meters, 初始海拔

  // 自動暫停
  final double stopSpeedMps = 0.8; // ≈ 2.9 km/h
  final int stopHoldSec = 20; // 停止 30 秒即自動暫停
  int _belowCount = 0;
  bool _autoPaused = false;
  bool _manuallyPaused = false; // 手動暫停狀態
  Timer? _stoppedTicker; // 每秒在自動/手動暫停時累加停止秒數
  double _movingFrac = 0.0; // 移動秒數的小數累加，避免 round 抖動

  // 新增：尚未移動前不計時
  bool _startedRecording = false; // 尚未移動前不計時
  final ValueNotifier<bool> hasStarted = ValueNotifier(false);

  // 對外可讀值
  final ValueNotifier<double> speedMps = ValueNotifier(0);
  final ValueNotifier<double> altitudeMeters = ValueNotifier(0);
  final ValueNotifier<double> distanceMeters = ValueNotifier(0);
  final ValueNotifier<int> movingSeconds = ValueNotifier(0);
  final ValueNotifier<int> stoppedSeconds = ValueNotifier(0);
  final ValueNotifier<int> autoStoppedSeconds = ValueNotifier(0); // 只計自動暫停時間
  final ValueNotifier<int> manualPausedSeconds = ValueNotifier(0); // 只計手動暫停時間
  final ValueNotifier<double> maxSpeedMps = ValueNotifier(0);
  final ValueNotifier<bool> isRunning = ValueNotifier(false);
  final ValueNotifier<bool> isAutoPaused = ValueNotifier(false);
  final ValueNotifier<bool> isManuallyPaused = ValueNotifier(false);

  // 方位（北=0，順時針，單位度）
  final ValueNotifier<double?> headingDeg = ValueNotifier<double?>(null);

  Trip? get currentTrip => _trip;

  Future<void> start({bool allowBackground = false}) async {
    final perm = await Geolocator.checkPermission();
    debugPrint('[BG] start() allowBackground=$allowBackground, perm=$perm');
    // 若已在追蹤，就直接確保訂閱恢復
    if (isRunning.value) {
      _sub?.resume();
      return;
    }
    final ok = await _ensureLocationPermission();
    if (!ok) {
      throw Exception('未取得定位權限或定位服務未開啟');
    }

    await WakelockPlus.enable();

    _trip = Trip(DateTime.now());
    _trip!.samples = _samples;
    _samples.clear();
    _resetState();
    _startedRecording = false;
    hasStarted.value = false;

    final LocationSettings settings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            allowBackgroundLocationUpdates: allowBackground, // 依偏好決定
            pauseLocationUpdatesAutomatically:
                !allowBackground, // 背景關閉時允許系統自動暫停
            showBackgroundLocationIndicator: allowBackground, // 僅在需要背景時顯示藍條
            activityType: ActivityType.automotiveNavigation,
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          );

    if (enableMockRoute) {
      _startMockRoute();
    } else {
      _sub = Geolocator.getPositionStream(locationSettings: settings)
          .listen(_onPosition, onError: (e, st) {
        // 若背景遭系統中斷，嘗試標記未運行以便之後再啟
        isRunning.value = false;
      });
    }

    // 重置手動暫停
    _manuallyPaused = false;
    isManuallyPaused.value = false;
    // 啟動停止秒數計時器（每秒tick一次）
    _stoppedTicker?.cancel();
    _stoppedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // 尚未開始（等待首次移動）時，不計任何時間
      if (!_startedRecording) {
        return;
      }
      if (!_manuallyPaused) {
        // 不再於無新點時改動速度值；僅由 _onPosition 以實際速度更新
      }

      if (_manuallyPaused) {
        // 手動暫停：僅累加「手動暫停秒數」，不累加「總停止時間」
        // -> 總時間 = 移動 + 停止；手動暫停時兩者皆不變，總時間停止計算
        manualPausedSeconds.value += 1;
      } else if (_autoPaused) {
        // 自動暫停：累加自動與總停止（總時間持續走）
        autoStoppedSeconds.value += 1;
        stoppedSeconds.value += 1;
      } else if (_emaSpeed < kStrictStopMps) {
        // 嚴格門檻（1 km/h）：低於即累加停止（總時間持續走）
        stoppedSeconds.value += 1;
      }
    });

    isRunning.value = true;
  }

  Future<void> pause() async {
    // 手動暫停：不再暫停 GPS 串流，仍持續接收速度並更新 UI
    _manuallyPaused = true;
    isManuallyPaused.value = true;
    // 保持訂閱不中斷，避免速度歸零
    // _sub?.pause(); // 移除：仍持續接收位置
    isRunning.value = true; // 仍處於追蹤狀態，只是不累積里程/時間
    _mockTimer?.cancel();
  }

  Future<void> resume() async {
    _manuallyPaused = false;
    isManuallyPaused.value = false;
    // 若之前未暫停串流，此呼叫不會有影響；若有外部暫停，也可恢復
    _sub?.resume();
    isRunning.value = true;
    if (enableMockRoute) {
      _startMockRoute(resume: true);
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _mockTimer?.cancel();
    _mockTimer = null;
    _stoppedTicker?.cancel();
    _stoppedTicker = null;
    _sub = null;
    isRunning.value = false;
    autoStoppedSeconds.value = 0;
    manualPausedSeconds.value = 0;
    _manuallyPaused = false;
    isManuallyPaused.value = false;
    headingDeg.value = null;

    if (_trip != null) {
      _trip!.endAt = DateTime.now();
      if (movingSeconds.value > 0) {
        _trip!.avgSpeedMps = distanceMeters.value / movingSeconds.value;
      }
      await WakelockPlus.disable();
    }
  }

  /// 手動開始：不論速度門檻，立即開始記錄，並把此刻視為旅程開始時間
  void forceStartRecordingNow() {
    _startedRecording = true;
    hasStarted.value = true;
    final now = DateTime.now();
    if (_trip != null) {
      _trip!.startAt = now;
    }
  }

  // 清空所有顯示用統計值，並重置狀態（結束旅程之後呼叫）
  void clearStats() {
    _resetState();
    _trip = null;
    // 再次顯式歸零所有對外的 notifier，確保 UI 馬上刷新
    speedMps.value = 0;
    altitudeMeters.value = 0;
    distanceMeters.value = 0;
    movingSeconds.value = 0;
    stoppedSeconds.value = 0;
    autoStoppedSeconds.value = 0;
    manualPausedSeconds.value = 0;
    maxSpeedMps.value = 0;
    isRunning.value = false;
    isAutoPaused.value = false;
    isManuallyPaused.value = false;
    headingDeg.value = null;
  }

  void _resetState() {
    _emaSpeed = 0;
    _lastTs = null;
    _lastPos = null;
    _belowCount = 0;
    _autoPaused = false;

    _displayZero = false;

    speedMps.value = 0;
    distanceMeters.value = 0;
    movingSeconds.value = 0;
    stoppedSeconds.value = 0;
    autoStoppedSeconds.value = 0;
    manualPausedSeconds.value = 0;
    maxSpeedMps.value = 0;
    isAutoPaused.value = false;
    isManuallyPaused.value = false;
    _manuallyPaused = false;
    _stoppedTicker?.cancel();
    _movingFrac = 0.0;
    _mockTick = 0;
    _mockStartAt = null;
    _samples.clear();
    _recentMoves.clear();
    _startedRecording = false;
    hasStarted.value = false;
    headingDeg.value = null;
  }

  void _onPosition(Position p) {
    final now = DateTime.now();
    // 與上一筆的時間差（秒）
    final double dtSec = (_lastTs != null)
        ? (now.difference(_lastTs!).inMilliseconds / 1000.0)
        : 0.0;
    const bool kRawSpeed = true; // 真實速度模式：移除各種門檻/夾制/平滑

    // 太密集的樣本直接忽略（避免 0 dt 造成無限大速度）
    if (_lastTs != null) {
      if (dtSec < kMinDtForSpeed) {
        return; // 等待下一筆
      }
    }

    // 先採用裝置回報速度與精度
    double sp = p.speed.isFinite ? math.max(0, p.speed) : 0.0; // m/s
    final double hAcc = (p.accuracy.isFinite) ? p.accuracy : 9999.0; // m
    final double sAcc =
        (p.speedAccuracy.isFinite) ? p.speedAccuracy : 9999.0; // m/s

    // 以相鄰點距離推得的速度（對停車/低速更可靠）
    double v = sp; // fallback
    double d = 0.0;
    double dt = 0.0;
    if (_lastPos != null && _lastTs != null) {
      dt = dtSec;
      if (dt > 0) {
        d = Geolocator.distanceBetween(
            _lastPos!.latitude, _lastPos!.longitude, p.latitude, p.longitude);
        v = d / dt; // RAW: 不做抖動門檻，直接使用距離/時間
      }
      // 維護最近 3 秒位移視窗（用於硬煞歸零判斷）
      if (dt > 0) {
        _recentMoves.add(_RecentMove(now, d));
        final cutoff = now
            .subtract(Duration(milliseconds: (kStopWindowSec * 1000).round()));
        while (
            _recentMoves.isNotEmpty && _recentMoves.first.ts.isBefore(cutoff)) {
          _recentMoves.removeAt(0);
        }
      }
    }

    // RAW: 不做尖峰壓制，完整呈現裝置回報速度

    // (RAW: 不做精度 fallback)

    // RAW: 直接採用裝置速度（不可用時才退回距離速度）
    double chosen = sp.isFinite ? sp : (v.isFinite ? v : 0.0);
    // 急煞/原地抖動：若最近 3 秒總位移極小，直接顯示 0，避免卡在 3~5 km/h
    double sumRecentD = 0.0;
    for (final rm in _recentMoves) {
      sumRecentD += rm.d;
    }
    if (sumRecentD < kStopWindowDist) {
      chosen = 0.0;
      // 停止時清空方位，避免停下來仍顯示方向
      headingDeg.value = null;
    }

    // RAW: 不做加速度夾制

    // RAW: 不做強制歸零，直接顯示 chosen
    _displayZero = false;
    _emaSpeed = math.max(0.0, chosen);

    // 更新方位（有時速就嘗試顯示；需至少有上一筆位置）
    double? hdg;
    if (!_autoPaused &&
        !_manuallyPaused &&
        _emaSpeed > 0.0 &&
        _lastPos != null) {
      try {
        final bearing = Geolocator.bearingBetween(
          _lastPos!.latitude,
          _lastPos!.longitude,
          p.latitude,
          p.longitude,
        );
        // 轉為 0~360，北=0、順時針
        hdg = (bearing.isFinite ? (bearing + 360.0) % 360.0 : null);
      } catch (_) {
        hdg = null;
      }
    }
    // 若停下或尚無上一筆就清空
    headingDeg.value = hdg;

    // 若尚未開始，當速度達到「啟動門檻」（10 km/h）才視為「開始記錄」
    const double startThresholdMps = 10.0 / 3.6; // 10 km/h
    if (!_startedRecording &&
        !_manuallyPaused &&
        _emaSpeed >= startThresholdMps) {
      _startedRecording = true;
      hasStarted.value = true;
      if (_trip != null) {
        _trip!.startAt = now; // 以實際起動時間為旅程開始
      }
    }

    // 停止門檻與自動暫停判斷（stopSpeedMps: 0.8 m/s, stopHoldSec: 30 秒）
    if (_emaSpeed < stopSpeedMps) {
      _belowCount += dtSec.round();
      if (!_autoPaused && _belowCount >= stopHoldSec) {
        _autoPaused = true;
        isAutoPaused.value = true;
      }
    } else {
      _belowCount = 0;
      if (_autoPaused) {
        _autoPaused = false;
        isAutoPaused.value = false;
      }
    }

    if (_lastPos != null &&
        _startedRecording &&
        !_autoPaused &&
        !_manuallyPaused) {
      final seg = Geolocator.distanceBetween(
          _lastPos!.latitude, _lastPos!.longitude, p.latitude, p.longitude);
      distanceMeters.value += seg;
      // 以整秒為單位，但用 >=1 的累加避免 0/1 抖動
      _movingFrac += dtSec;
      if (_movingFrac >= 1.0) {
        final inc = _movingFrac.floor();
        movingSeconds.value += inc;
        _movingFrac -= inc;
      }
      maxSpeedMps.value = math.max(maxSpeedMps.value, _emaSpeed);
    }
    // 停止秒數改由每秒ticker累加，避免GPS靜止時不觸發而不更新

    speedMps.value = _emaSpeed;
    _lastPos = p;
    _lastTs = now;

    // 更新海拔
    if (p.altitude.isFinite) {
      altitudeMeters.value = p.altitude;
    }

    // 記錄軌跡點
    final double? altVal = p.altitude.isFinite ? p.altitude : null;
    if (kDebugMode) {
      // 'GPS sample: ts=${now.toIso8601String()} lat=${p.latitude.toStringAsFixed(5)} lon=${p.longitude.toStringAsFixed(5)} alt=${altVal?.toStringAsFixed(1)} speed(m/s)=${_emaSpeed.toStringAsFixed(2)} mocked=${p.isMocked == true}'
    }
    _samples.add(TrackSample(
      ts: now,
      lat: p.latitude,
      lon: p.longitude,
      alt: altVal,
      speedMps: _emaSpeed,
      autoPaused: _autoPaused,
      manuallyPaused: _manuallyPaused,
    ));
  }

  // 啟動內建模擬路線（新版腳本情境）
  void _startMockRoute({bool resume = false}) {
    _mockTimer?.cancel();
    final dtMs = 100; // 每 0.1 秒一筆
    _mockStartAt ??= DateTime.now();

    // === 模擬腳本參數 ===
    // 等待 5 秒
    // 第 1 輪：加速 10s（到 310km/h）→ 減速 10s → 等待 2s
    // 等待 5 秒
    // 第 2 輪：加速 3s（到 55km/h）→ 減速 2s → 等待 2s
    // 等待 5 秒
    // 第 3 輪：加速 3s（到 55km/h）→ 減速 2s → 等待 2s
    // 等待 5 秒
    // 第 4 輪：加速 10s（到 310km/h）→ 減速 10s → 等待 2s
    // 結束
    const double dtSec = 0.1; // tick = 0.1s
    const double vmaxHighKmh = 310.0; // 輪1 & 輪4
    const double vmaxLowKmh = 55.0; // 輪2 & 輪3
    final double vmaxHigh = vmaxHighKmh / 3.6; // m/s
    final double vmaxLow = vmaxLowKmh / 3.6; // m/s

    // 片段長度（以 tick 計）
    final int ticksWait5 = (5.0 / dtSec).round();
    final int ticksAcc10 = (10.0 / dtSec).round();
    final int ticksAcc3 = (3.0 / dtSec).round();
    final int ticksDec10 = (10.0 / dtSec).round();
    final int ticksDec2 = (2.0 / dtSec).round();
    final int ticksPause2 = (2.0 / dtSec).round();

    // 邊界（以 tick 為單位）
    final int b0 = ticksWait5; // 開頭等待 5s 結束
    // 第 1 輪（310）：10s 加速 → 10s 減速 → 等 2s
    final int b1a = b0 + ticksAcc10; // 輪1加速結束
    final int b1 = b1a + ticksDec10; // 輪1減速結束
    final int b1w = b1 + ticksPause2; // 輪1等待 2s 結束

    // 等待 5s
    final int b2w0 = b1w + ticksWait5; // 輪2開始前再等 5s 結束
    // 第 2 輪（55）：3s 加速 → 2s 減速 → 等 2s
    final int b2a = b2w0 + ticksAcc3; // 輪2加速（3s）結束
    final int b2 = b2a + ticksDec2; // 輪2減速（2s）結束
    final int b2w = b2 + ticksPause2; // 輪2等待 2s 結束

    // 等待 5s
    final int b3w0 = b2w + ticksWait5; // 輪3開始前再等 5s 結束
    // 第 3 輪（55）：3s 加速 → 2s 減速 → 等 2s
    final int b3a = b3w0 + ticksAcc3; // 輪3加速（3s）結束
    final int b3 = b3a + ticksDec2; // 輪3減速（2s）結束
    final int b3w = b3 + ticksPause2; // 輪3等待 2s 結束

    // 等待 5s
    final int b4w0 = b3w + ticksWait5; // 輪4開始前再等 5s 結束
    // 第 4 輪（310）：10s 加速 → 10s 減速 → 等 2s
    final int b4a = b4w0 + ticksAcc10; // 輪4加速結束
    final int b4 = b4a + ticksDec10; // 輪4減速結束
    final int b4w = b4 + ticksPause2; // 輪4等待 2s 結束（腳本終點）

    final int totalTicks = b4w;

    _mockTimer = Timer.periodic(Duration(milliseconds: dtMs), (t) {
      _mockTick++;

      final sp = _mockSpeedScenarioYI(
        _mockTick,
        ticksWait5: ticksWait5,
        ticksAcc10: ticksAcc10,
        ticksAcc3: ticksAcc3,
        ticksDec10: ticksDec10,
        ticksDec2: ticksDec2,
        ticksPause2: ticksPause2,
        vmaxHigh: vmaxHigh,
        vmaxLow: vmaxLow,
        dtSec: dtSec,
      ); // m/s

      // 依速度推進經緯度（向東前進）
      final meters = sp * (dtMs / 1000.0);
      final dLat = meters / 111320.0;
      final cosLat = math.cos(_mockLat * math.pi / 180.0).clamp(0.0001, 1.0);
      final dLon = meters / (111320.0 * cosLat);
      final dir = ((_mockTick ~/ 200) % 2 == 0) ? 1.0 : -1.0;
      _mockLat += dLat * 0.2 * dir;
      _mockLon += dLon * 0.8 * dir;

      // 海拔：依腳本逐步變化（沿用原有邏輯）
      _mockAlt += _mockAltitudeDeltaForTick(_mockTick);

      final pos = Position(
        latitude: _mockLat,
        longitude: _mockLon,
        timestamp: _mockStartAt!.add(Duration(milliseconds: _mockTick * dtMs)),
        accuracy: 5.0,
        altitude: _mockAlt,
        heading: 0.0,
        speed: sp,
        speedAccuracy: 0.5,
        headingAccuracy: 5.0,
        altitudeAccuracy: 3.0,
        isMocked: true,
      );
      _onPosition(pos);

      // 自動結束腳本
      if (_mockTick > totalTicks) {
        t.cancel();
      }
    });
  }

  // 新腳本情境：
  // 等待5s → [10s加速(到310)→10s減速→等2s] → 等5s → [3s加速(到55)→2s減速→等2s]
  // → 等5s → [3s加速(到55)→2s減速→等2s] → 等5s → [10s加速(到310)→10s減速→等2s] → 結束
  double _mockSpeedScenarioYI(
    int tick, {
    required int ticksWait5,
    required int ticksAcc10,
    required int ticksAcc3,
    required int ticksDec10,
    required int ticksDec2,
    required int ticksPause2,
    required double vmaxHigh, // 310 km/h (m/s)
    required double vmaxLow, // 55  km/h (m/s)
    required double dtSec,
  }) {
    // 與 _startMockRoute 保持一致的邊界
    final int b0 = ticksWait5; // 開頭等待 5s
    final int b1a = b0 + ticksAcc10; // 輪1加速(310)結束
    final int b1 = b1a + ticksDec10; // 輪1減速結束
    final int b1w = b1 + ticksPause2; // 輪1等待 2s

    final int b2w0 = b1w + ticksWait5; // 輪2前等待 5s
    final int b2a = b2w0 + ticksAcc3; // 輪2加速(55)結束
    final int b2 = b2a + ticksDec2; // 輪2減速(2s)結束
    final int b2w = b2 + ticksPause2; // 輪2等待 2s

    final int b3w0 = b2w + ticksWait5; // 輪3前等待 5s
    final int b3a = b3w0 + ticksAcc3; // 輪3加速(55)結束
    final int b3 = b3a + ticksDec2; // 輪3減速(2s)結束
    final int b3w = b3 + ticksPause2; // 輪3等待 2s

    final int b4w0 = b3w + ticksWait5; // 輪4前等待 5s
    final int b4a = b4w0 + ticksAcc10; // 輪4加速(310)結束
    final int b4 = b4a + ticksDec10; // 輪4減速結束
    final int b4w = b4 + ticksPause2; // 輪4等待 2s（終點）

    double accel(int k0, int len, double vMax) {
      final double t = (tick - k0) * dtSec;
      final double T = len * dtSec;
      final double a = (T > 0) ? (vMax / T) : 0.0;
      return a * t; // 0 → vMax 線性
    }

    double decel(int k0, int len, double vMax) {
      final double t = (tick - k0) * dtSec;
      final double T = len * dtSec;
      final double a = (T > 0) ? (vMax / T) : 0.0;
      return math.max(0.0, vMax - a * t); // vMax → 0 線性
    }

    if (tick <= b0) return 0.0; // 等待5s
    if (tick <= b1a) return accel(b0, ticksAcc10, vmaxHigh); // 輪1加速(310)
    if (tick <= b1) return decel(b1a, ticksDec10, vmaxHigh); // 輪1減速
    if (tick <= b1w) return 0.0; // 輪1等2s

    if (tick <= b2w0) return 0.0; // 等5s
    if (tick <= b2a) return accel(b2w0, ticksAcc3, vmaxLow); // 輪2加速(55)
    if (tick <= b2) return decel(b2a, ticksDec2, vmaxLow); // 輪2減速(2s)
    if (tick <= b2w) return 0.0; // 輪2等2s

    if (tick <= b3w0) return 0.0; // 等5s
    if (tick <= b3a) return accel(b3w0, ticksAcc3, vmaxLow); // 輪3加速(55)
    if (tick <= b3) return decel(b3a, ticksDec2, vmaxLow); // 輪3減速(2s)
    if (tick <= b3w) return 0.0; // 輪3等2s

    if (tick <= b4w0) return 0.0; // 等5s
    if (tick <= b4a) return accel(b4w0, ticksAcc10, vmaxHigh); // 輪4加速(310)
    if (tick <= b4) return decel(b4a, ticksDec10, vmaxHigh); // 輪4減速
    if (tick <= b4w) return 0.0; // 輪4等2s

    return 0.0; // 結束
  }

  // 依腳本產生海拔變化（每 tick=0.1s 回傳位移量，單位 m）
  double _mockAltitudeDeltaForTick(int tick) {
    // A: 0~4s（0~39）緩升 +0.8 m/s
    if (tick < 40) return 0.8 * 0.1; // +0.08 m/tick
    // B: 4~8.1s（40~80）小幅上升 +0.2 m/s
    if (tick < 81) return 0.2 * 0.1; // +0.02
    // C: 8.1~9.7s（81~96）下降 -0.5 m/s
    if (tick < 97) return -0.5 * 0.1; // -0.05
    // D: 9.7~13.8s（97~137）幾乎持平（可加微幅 undulation）
    if (tick < 138) return 0.0;
    // E: 13.8~17.9s（138~178）停止，持平
    if (tick < 179) return 0.0;
    // F: 17.9~19.9s（179~198）緩升 +0.6 m/s
    if (tick < 199) return 0.6 * 0.1; // +0.06
    // 之後持平
    return 0.0;
  }

  // 根據三段式腳本產生速度（A:梯形加速-巡航-減速，B:等待，C:三角加減速）
  double _mockSpeedForTick(int tick,
      {required int ticksAAccel,
      required int ticksAPlateau,
      required int ticksADecel,
      required int ticksWait,
      required int ticksC,
      required double vmax1,
      required double vmax2,
      required double dtSec}) {
    // 三段式：A(加速→巡航5s→減速，Vmax=310km/h，總距離 610m)
    //        B 等待（速度=0）
    //        C(三角加減速，Vmax=200km/h，總距離 600m）
    // A 段切片與邊界
    final int ticksATotal = ticksAAccel + ticksAPlateau + ticksADecel;
    final int b1 = ticksATotal; // A 結束
    final int b2 = b1 + ticksWait; // B 結束
    final int b3 = b2 + ticksC; // C 結束

    if (tick <= b1) {
      // 段 A：加速 → 巡航 → 減速
      final int k = tick;
      if (k <= ticksAAccel && ticksAAccel > 0) {
        // 線性加速：0 → vmax1
        final double t = k * dtSec;
        final double Ta = ticksAAccel * dtSec;
        final double a = (Ta > 0) ? (vmax1 / Ta) : 0.0;
        return a * t;
      } else if (k <= (ticksAAccel + ticksAPlateau)) {
        // 巡航：固定 vmax1
        return vmax1;
      } else {
        // 線性減速：vmax1 → 0
        final int k2 = k - (ticksAAccel + ticksAPlateau);
        final double t = k2 * dtSec;
        final double Td = ticksADecel * dtSec;
        final double a = (Td > 0) ? (vmax1 / Td) : 0.0;
        return math.max(0.0, vmax1 - a * t);
      }
    } else if (tick <= b2) {
      // 段 B：等待（速度 0）
      return 0.0;
    } else if (tick <= b3) {
      // 段 C：三角加減速（維持原本三角形邏輯）
      final int k = tick - b2; // 0..ticksC
      final double tTotal = ticksC * dtSec;
      final double tHalf = tTotal / 2.0;
      final double a = (tHalf > 0) ? (vmax2 / tHalf) : 0.0;
      final double t = (k.clamp(0, ticksC)) * dtSec;
      if (t <= tHalf) {
        return a * t; // 加速
      } else {
        return a * (tTotal - t); // 減速
      }
    } else {
      // 之後保持停止
      return 0.0;
    }
  }

  Future<bool> _ensureLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;

    return true;
  }
}

/// ===== App UI =====
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: Setting.instance.language,
      builder: (_, lang, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: appLightMode,
          builder: (_, isLight, __) {
            return ValueListenableBuilder<Color>(
              valueListenable: Setting.instance.themeSeed,
              builder: (_, seed, __) {
                final base = ThemeData(
                  brightness: isLight ? Brightness.light : Brightness.dark,
                  colorSchemeSeed: seed,
                  scaffoldBackgroundColor:
                      isLight ? Colors.white : Colors.black,
                  snackBarTheme: const SnackBarThemeData(
                      behavior: SnackBarBehavior.floating),
                  appBarTheme: AppBarTheme(
                    backgroundColor: isLight ? Colors.white : Colors.black,
                    foregroundColor: isLight ? Colors.black : Colors.white,
                    elevation: isLight ? 0.5 : 0,
                  ),
                  textTheme: isLight
                      ? const TextTheme(
                          bodyLarge: TextStyle(color: Colors.black),
                          bodyMedium: TextStyle(color: Colors.black87),
                          bodySmall: TextStyle(color: Colors.black54),
                        )
                      : TextTheme(
                          bodyLarge: TextStyle(color: seed),
                          bodyMedium: TextStyle(color: seed.withOpacity(0.85)),
                          bodySmall: TextStyle(color: seed.withOpacity(0.7)),
                          displayLarge: TextStyle(color: seed),
                          displayMedium:
                              TextStyle(color: seed.withOpacity(0.9)),
                          displaySmall: TextStyle(color: seed.withOpacity(0.8)),
                        ),
                  useMaterial3: true,
                );
                return MaterialApp(
                  title: 'GPS Speedometer Minimal',
                  theme: base,
                  home: HomePage(),
                  debugShowCheckedModeBanner: false,
                  navigatorKey: navigatorKey,
                );
              },
            );
          },
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

// ===== Reusable stats panel (Home & Camera overlay) =====
class StatsPanel extends StatelessWidget {
  final bool useMiles;
  final ValueListenable<double> distanceMeters;
  final ValueListenable<double> altitudeMeters;
  final ValueListenable<int> stoppedSeconds;
  final ValueListenable<double> maxSpeedMps;
  final ValueListenable<int> movingSeconds;
  // 新增：錄影模式下的樣式
  final bool cameraStyle;

  const StatsPanel({
    super.key,
    required this.useMiles,
    required this.distanceMeters,
    required this.altitudeMeters,
    required this.stoppedSeconds,
    required this.maxSpeedMps,
    required this.movingSeconds,
    this.cameraStyle = false,
  });

  String _formatDistance(double meters) => useMiles
      ? '${(meters / 1609.34).toStringAsFixed(2)} mi'
      : '${(meters / 1000).toStringAsFixed(2)} km';

  String _formatSpeedFromMps(double mps) {
    final v = useMiles ? (mps * 2.23694) : (mps * 3.6);
    final unit = useMiles ? 'mph' : 'km/h';
    return '${v.toStringAsFixed(1)} $unit';
  }

  String _fmtHms(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatAltitude(double meters) => useMiles
      ? '${(meters * 3.28084).toStringAsFixed(1)} ft'
      : '${meters.toStringAsFixed(1)} m';

  Widget _buildValue(String text, {bool emphasize = true}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: cameraStyle ? 20 : 18,
        fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
        color: cameraStyle ? Colors.white : null,
      ),
    );
  }

  Widget _buildTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: cameraStyle ? 13 : 12,
        color: cameraStyle ? Colors.white70 : Colors.grey,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildCameraPanel(BuildContext context) {
    Widget _cell(String title, Widget value) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          value,
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.black.withOpacity(0.35),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第一列：距離、海拔、停止時間
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _cell(
                      L10n.t('distance'),
                      ValueListenableBuilder<double>(
                        valueListenable: distanceMeters,
                        builder: (_, m, __) => _buildValue(_formatDistance(m)),
                      ),
                    ),
                    const SizedBox(width: 24),
                    _cell(
                      L10n.t('altitude'),
                      ValueListenableBuilder<double>(
                        valueListenable: altitudeMeters,
                        builder: (_, alt, __) =>
                            _buildValue(_formatAltitude(alt)),
                      ),
                    ),
                    const SizedBox(width: 24),
                    _cell(
                      L10n.t('stopped_time'),
                      ValueListenableBuilder<int>(
                        valueListenable: stoppedSeconds,
                        builder: (_, s, __) => _buildValue(_fmtHms(s)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 第二列：最高速、平均速、總時間
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _cell(
                      L10n.t('max_speed'),
                      ValueListenableBuilder<double>(
                        valueListenable: maxSpeedMps,
                        builder: (_, mps, __) =>
                            _buildValue(_formatSpeedFromMps(mps)),
                      ),
                    ),
                    const SizedBox(width: 24),
                    _cell(
                      L10n.t('avg_speed'),
                      ValueListenableBuilder2<double, int>(
                        a: distanceMeters,
                        b: movingSeconds,
                        builder: (_, m, s, __) {
                          final vMps = (s > 0) ? (m / s) : 0.0;
                          return _buildValue(_formatSpeedFromMps(vMps));
                        },
                      ),
                    ),
                    const SizedBox(width: 24),
                    _cell(
                      L10n.t('total_time'),
                      ValueListenableBuilder2<int, int>(
                        a: movingSeconds,
                        b: stoppedSeconds,
                        builder: (_, ms, stopS, __) {
                          final total = ms + stopS;
                          return _buildValue(_fmtHms(total));
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (cameraStyle) {
      return _buildCameraPanel(context);
    }

    // 原本樣式（主頁使用）
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左欄
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Stat(
                    title: L10n.t('distance'),
                    child: ValueListenableBuilder<double>(
                      valueListenable: distanceMeters,
                      builder: (_, m, __) => Text(
                        _formatDistance(m),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Stat(
                    title: L10n.t('altitude'),
                    child: ValueListenableBuilder<double>(
                      valueListenable: altitudeMeters,
                      builder: (_, alt, __) => Text(
                        _formatAltitude(alt),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Stat(
                    title: L10n.t('stopped_time'),
                    child: ValueListenableBuilder<int>(
                      valueListenable: stoppedSeconds,
                      builder: (_, s, __) => Text(
                        _fmtHms(s),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 32),
            // 右欄
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Stat(
                    title: L10n.t('max_speed'),
                    child: ValueListenableBuilder<double>(
                      valueListenable: maxSpeedMps,
                      builder: (_, mps, __) => Text(
                        _formatSpeedFromMps(mps),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Stat(
                    title: L10n.t('avg_speed'),
                    child: ValueListenableBuilder2<double, int>(
                      a: distanceMeters,
                      b: movingSeconds,
                      builder: (_, m, s, __) {
                        final vMps = (s > 0) ? (m / s) : 0.0;
                        return Text(
                          _formatSpeedFromMps(vMps),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Stat(
                    title: L10n.t('total_time'),
                    child: ValueListenableBuilder2<int, int>(
                      a: movingSeconds,
                      b: stoppedSeconds,
                      builder: (_, ms, stopS, __) {
                        final total = ms + stopS;
                        return Text(
                          _fmtHms(total),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        );
                      },
                    ),
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

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Listener for background recording preference
  VoidCallback? _bgPrefListener;
  Future<bool> _getBgRecordingPref() async {
    final sp = await SharedPreferences.getInstance();
    final bool? stored = sp.getBool('enable_bg_recording');
    if (stored == null) {
      // 首次啟動：預設開啟，並立刻持久化以便主頁首次自動啟動時就能允許背景
      await sp.setBool('enable_bg_recording', true);
      return true;
    }
    return stored;
  }

  Future<void> _restoreMaxKmh() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getDouble('max_kmh');
      if (saved != null && saved > 0) {
        setState(() {
          maxKmh = saved;
        });
      }
    } catch (_) {
      // ignore read failure; keep default
    }
  }

  // 讓大數字以「每次±1」的方式平滑前進，避免卡在某些整數
  Timer? _digitTimer;
  int _displayInt = 0; // 目前顯示（整數）
  bool get _isVip => PurchaseService().isPremiumUnlocked;
  double _lastTargetKmh = 0.0; // 目標值（已轉成顯示單位的 km/h 或 mph 數值）
  // 估算目標變化速度（km/h 每秒）
  DateTime? _lastTargetUpdate;
  double _targetVelKmhps = 0.0; // 目標的變化速率（km/h per second）
  double _targetPrev = 0.0; // 上一次的目標值
  // 整數步進積分器：把連續的速度變化轉成均勻的「每 1 格」跳動
  double _stepAcc = 0.0; // 單位：km/h（累積到 ±1 就跨一格）

  // ===== Interstitial Ad scheduling (once at launch, once on each resume) =====
  Timer? _adTimer;
  bool _adScheduled = false;
  bool _inSaveFlow = false; // 正在結束/命名/保存旅程流程中
  DateTime? _lastAdShownAt;
  // Deep link subscription for uni_links (Shortcuts / URL scheme)
  StreamSubscription? _linkSub;
  void _scheduleOnceAd() {
    // VIP 用戶永不顯示廣告
    if (_isVip) {
      _adTimer?.cancel();
      _adScheduled = false;
      return;
    }
    // Cancel any previous pending schedule, then schedule exactly one show
    _adTimer?.cancel();
    _adScheduled = true;
    _adTimer = Timer(const Duration(seconds: 20), () async {
      _adScheduled = false;
      // 再次檢查 VIP（避免購買後仍誤彈）
      if (_isVip) return;
      final shown = await AdService.instance.showInterstitial();
      if (shown) {
        _lastAdShownAt = DateTime.now();
      }
    });
  }

  Future<void> _handleIncomingUri(Uri? uri) async {
    if (uri == null) return;
    debugPrint("🔄 Shortcut URI received in background: $uri");
    // 支援三種叫法：
    // gpssmeter://maptrack
    // gpssmeter://action/maptrack
    // gpssmeter://open?target=maptrack
    final action = (uri.host.isNotEmpty
            ? uri.host
            : uri.pathSegments.isNotEmpty
                ? uri.pathSegments.first
                : uri.queryParameters['target'])
        ?.toLowerCase();
    if (action == 'maptrack' || action == 'map_track') {
      _openMapMode(MapCameraMode.headingUp);
    } else if (action == 'accel') {
      _openAccelMode();
    }
  }

// ===== iOS/Android Home Screen Quick Actions 快捷選單=====
  final QuickActions _qa = const QuickActions();

  void _onQuickAction(String? type) {
    if (type == 'action_map_track') {
      _openMapMode(MapCameraMode.headingUp);
    } else if (type == 'action_accel_mode') {
      _openAccelMode();
    }
  }

// ===== iOS/Android Home Screen Quick Actions 快捷選單=====
  void _openAccelMode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccelPage(
          liveSpeedMps: svc.speedMps,
          headingDeg: svc.headingDeg,
          distanceMeters: svc.distanceMeters,
          movingSeconds: svc.movingSeconds,
          stoppedSeconds: svc.stoppedSeconds,
          isAutoPaused: svc.isAutoPaused,
          isManuallyPaused: svc.isManuallyPaused,
          forceStartRecordingNow: svc.forceStartRecordingNow,
          mode: AccelMode.zeroTo100,
        ),
      ),
    );
  }

// ===== iOS/Android Home Screen Quick Actions 快捷選單=====
  void _updateQuickActions() {
    final lang = Setting.instance.language.value;
    final titleMap = L10n.t('qa_map_track', lang: lang);
    final titleAccel = L10n.t('qa_accel_mode', lang: lang);
    _qa.setShortcutItems([
      ShortcutItem(
        type: 'action_map_track',
        localizedTitle: titleMap,
        icon: 'location', // 之後想換自定義再說
      ),
      ShortcutItem(
        type: 'action_accel_mode',
        localizedTitle: titleAccel,
        icon: 'speed', // iOS 可放 SFSymbol 名稱；先用通用字串
      ),
    ]);
  }

  void _ensureDigitStepper() {
    _digitTimer ??= Timer.periodic(const Duration(milliseconds: 40), (_) {
      // 以目標變化速率（km/h 每秒）積分出穩定的整數跳動，避免「卡一下再 +2」的不均勻感
      final int target = _lastTargetKmh.round();

      // 若已達目標，慢慢把積分器拉回 0，避免殘餘造成下一次突跳
      if (_displayInt == target) {
        _stepAcc *= 0.85;
        if (_stepAcc.abs() < 0.05) _stepAcc = 0.0;
        return;
      }

      // 單次 tick 時間（秒）
      const double dt = 0.04; // 40ms

      // 取當前的目標變化速率（km/h per second）
      double v = _targetVelKmhps.abs();
      // 為了避免目標速度斜率接近 0 時無法收斂到 target，給一個「最小收斂速率」。
      // 這不是速度限速，只是保證在目標不再變化時，顯示仍會以穩定節奏靠攏目標。
      const double vMinConverge = 5.0; // km/h/s  → 每 40ms 積分 ~0.2，一秒約前進 5 格
      if (v < vMinConverge && _displayInt != target) v = vMinConverge;

      // 根據「目標在顯示值的上/下方」決定積分方向
      final bool rising = target > _displayInt;
      final double signedV = rising ? v : -v;

      // 把連續值積分到累加器中（達到 ±1 就前進/後退 1 格）
      _stepAcc += signedV * dt; // 單位仍為 km/h，因顯示單位即是 km/h（一格=1）

      bool changed = false;
      // 依 accumulator 均勻地跨整數格，直到接近目標
      while (_stepAcc >= 1.0 && _displayInt < target) {
        _displayInt += 1;
        _stepAcc -= 1.0;
        changed = true;
      }
      while (_stepAcc <= -1.0 && _displayInt > target) {
        _displayInt -= 1;
        _stepAcc += 1.0;
        changed = true;
      }

      // 停車時更俐落：目標為 0 且剩餘很接近 0，就直接歸零
      if (target == 0) {
        if (_displayInt <= 5) {
          _displayInt = 0;
          _stepAcc = 0.0;
          changed = true;
        }
      }

      // 安全：避免越過目標
      if (rising && _displayInt > target) _displayInt = target;
      if (!rising && _displayInt < target) _displayInt = target;

      if (_displayInt < 0) _displayInt = 0;
      if (changed && mounted) setState(() {});
    });
  }

  void _openMapMode(MapCameraMode mode) {
    final sharedRoute = <am.LatLng>[];
    final src0 = svc.currentTrip?.samples ?? [];
    for (final s in src0) {
      sharedRoute.add(am.LatLng(s.lat, s.lon));
    }
    int mirrored = src0.length;
    Timer? mirrorTimer;
    mirrorTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final src = svc.currentTrip?.samples;
      if (src == null) return;
      while (mirrored < src.length) {
        final s = src[mirrored++];
        sharedRoute.add(am.LatLng(s.lat, s.lon));
      }
      if (src.isNotEmpty && sharedRoute.isNotEmpty) {
        final s = src.last;
        final last = sharedRoute.last;
        if (last.latitude != s.lat || last.longitude != s.lon) {
          sharedRoute[sharedRoute.length - 1] = am.LatLng(s.lat, s.lon);
        }
      }
    });
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => MapModePage(
          initialMode: mode,
          useMiles: _useMiles,
          route: sharedRoute,
          recording: svc.isRunning.value && !svc.isManuallyPaused.value,
          liveSpeedMps: svc.speedMps,
          onToggleRecord: () async {
            if (svc.isManuallyPaused.value) {
              await svc.resume();
            } else if (svc.isRunning.value) {
              await svc.pause();
            } else {
              try {
                final bg = await _getBgRecordingPref();
                await svc.start(allowBackground: bg);
                svc.forceStartRecordingNow();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        duration: const Duration(milliseconds: 500),
                        content: Text('${L10n.t('start_failed_prefix')}$e')),
                  );
                }
              }
            }
            if (mounted) setState(() {});
          },
          onStopAndSave: () async {
            await _stopAndSaveFromAnywhere();
          },
        ),
      ),
    )
        .then((_) {
      mirrorTimer?.cancel();
    });
  }

  Future<void> _stopAndSaveFromAnywhere() async {
    _inSaveFlow = true; // 標記：避免 resumed 時自動重啟追蹤或跳廣告
    _adTimer?.cancel(); // 取消任何已排程的插頁式廣告
    _adScheduled = false;
    try {
      await svc.stop();
      if (!mounted) return;
      final name = await _promptTripName(context);
      if (name != null && svc.currentTrip != null) {
        svc.currentTrip!.name = name.isEmpty ? null : name;
        final saved = await _saveTrip();
        if (!saved && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                duration: const Duration(milliseconds: 500),
                content: Text(L10n.t('save_failed_try_again'))),
          );
        }
      }
      // 無論是否命名/保存，最後都清零顯示
      svc.clearStats();
      if (mounted) {
        setState(() {
          _gaugeFromKmh = 0.0;
          _numberFromKmh = 0.0;
        });
      }
      // 在保存/取消保存後，立刻重新開啟定位串流，
      // 讓主頁能即時顯示時速，並維持「手動開始」狀態（尚未達門檻不會計入旅程）。
      try {
        final bg = await _getBgRecordingPref();
        await svc.start(allowBackground: bg);
        // 注意：不要呼叫 forceStartRecordingNow()，以維持手動開始的邏輯。
      } catch (_) {
        // 忽略錯誤：若權限或系統條件不允許，使用者仍可手動開始。
      }
    } finally {
      _inSaveFlow = false; // 結束保存流程
      // 保存完成後，重新排程一次插頁式廣告（10 秒後顯示一次）
      _scheduleOnceAd();
    }
  }

  Future<void> _showControlsSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ValueListenableBuilder2<bool, bool>(
              a: svc.isRunning,
              b: svc.isManuallyPaused,
              builder: (context, running, manualPaused, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: svc.hasStarted,
                  builder: (context, hasStarted, __) {
                    final items = <Widget>[];
                    items.add(ValueListenableBuilder<bool>(
                      valueListenable: appLightMode,
                      builder: (context, isLight, __) {
                        return SwitchListTile(
                          secondary: Icon(
                              isLight ? Icons.dark_mode : Icons.light_mode,
                              color: isLight ? Colors.indigo : Colors.amber),
                          title: Text(
                              isLight
                                  ? L10n.t('dark_mode')
                                  : L10n.t('light_mode'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 18)),
                          subtitle: Text(
                              isLight
                                  ? L10n.t('switch_to_dark')
                                  : L10n.t('switch_to_light'),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          value: isLight,
                          onChanged: (v) async {
                            appLightMode.value = v;
                            await _saveSettings();
                          },
                        );
                      },
                    ));

                    if (manualPaused) {
                      items.add(ListTile(
                        leading: const Icon(Icons.play_circle,
                            color: Colors.greenAccent),
                        title: Text(L10n.t('resume'),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 18)),
                        onTap: () async {
                          Navigator.of(context).pop();
                          await svc.resume();
                        },
                      ));
                    } else if (running) {
                      // 正在追蹤
                      // 尚未達門檻 → 顯示「手動開始」讓使用者立即起算；此時不提供「暫停」以免把 GPS 流暫停導致無法偵測速度
                      if (!hasStarted) {
                        items.add(ListTile(
                          leading: const Icon(Icons.play_arrow,
                              color: Colors.greenAccent),
                          title: Text(L10n.t('manual_start'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 18)),
                          subtitle: Text(L10n.t('manual_start_sub'),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          onTap: () async {
                            Navigator.of(context).pop();
                            svc.forceStartRecordingNow();
                          },
                        ));
                      } else {
                        // 已開始紀錄後，才提供「暫停」
                        items.add(ListTile(
                          leading:
                              const Icon(Icons.pause, color: Colors.orange),
                          title: Text(L10n.t('pause'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 18)),
                          onTap: () async {
                            Navigator.of(context).pop();
                            await svc.pause();
                          },
                        ));
                      }
                    } else {
                      items.add(ListTile(
                        leading: const Icon(Icons.play_arrow,
                            color: Colors.greenAccent),
                        title: Text(L10n.t('start'),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 18)),
                        subtitle: Text(L10n.t('start_sub'),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                        onTap: () async {
                          Navigator.of(context).pop();
                          try {
                            final bg = await _getBgRecordingPref();
                            await svc.start(allowBackground: bg);
                            // 手動開始：直接進入記錄狀態（不受 10km/h 門檻限制）
                            svc.forceStartRecordingNow();
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  duration: const Duration(milliseconds: 500),
                                  content: Text(
                                      '${L10n.t('start_failed_prefix')}$e')),
                            );
                          }
                        },
                      ));
                    }

                    // 地圖模式
                    items.add(ListTile(
                      leading: const Icon(Icons.map, color: Colors.tealAccent),
                      title: Text(L10n.t('map_mode'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      subtitle: Text(L10n.t('map_mode_sub'),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      onTap: () async {
                        Navigator.of(context).pop();
                        _openMapMode(MapCameraMode.headingUp);
                      },
                    ));

                    // === 新增加速測試項目 ===
                    items.add(ListTile(
                      leading: const Icon(FontAwesomeIcons.flagCheckered,
                          color: Colors.purpleAccent),
                      title: Text(L10n.t('accel_test'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      onTap: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AccelPage(
                              liveSpeedMps: svc.speedMps,
                              headingDeg: svc.headingDeg,
                              distanceMeters: svc.distanceMeters,
                              movingSeconds: svc.movingSeconds,
                              stoppedSeconds: svc.stoppedSeconds,
                              isAutoPaused: svc.isAutoPaused,
                              isManuallyPaused: svc.isManuallyPaused,
                              forceStartRecordingNow:
                                  svc.forceStartRecordingNow,
                              mode: AccelMode.zeroTo100,
                            ),
                          ),
                        );
                      },
                    ));
                    // === 錄影模式 ===
                    items.add(
                      ListTile(
                        leading: const Icon(Icons.video_camera_back_rounded,
                            color: Colors.greenAccent),
                        title: Text(L10n.t('record_mode'),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 18)),
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CameraRecordPage(
                                overlayBuilder: (ctx) => Stack(
                                  children: [
                                    // 將大時速數字移至頂部安全區下方
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: MediaQuery.of(ctx).padding.top +
                                          28, // 放在瀏海/動態島下方 28px
                                      child: ValueListenableBuilder<double>(
                                        valueListenable: svc.speedMps,
                                        builder: (_, v, __) {
                                          final display = _mpsToDisplay(v);
                                          final text =
                                              display.round().toString();
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Text(
                                                text,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  fontSize: 120,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 1.0,
                                                  color: Colors.white,
                                                  shadows: [
                                                    Shadow(
                                                        offset: Offset(0, 1),
                                                        blurRadius: 6,
                                                        color: Colors.black54),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                _useMiles ? 'mph' : 'km/h',
                                                style: const TextStyle(
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.white70,
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),

                                    // 底部小膠囊統計面板（保留毛玻璃樣式）
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 24),
                                        child: StatsPanel(
                                          useMiles: _useMiles,
                                          distanceMeters: svc.distanceMeters,
                                          altitudeMeters: svc.altitudeMeters,
                                          stoppedSeconds: svc.stoppedSeconds,
                                          maxSpeedMps: svc.maxSpeedMps,
                                          movingSeconds: svc.movingSeconds,
                                          cameraStyle: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                    // 設置（與主頁左下角設定按鈕相同功能）
                    items.add(
                      ListTile(
                        leading:
                            const Icon(Icons.settings, color: Colors.white70),
                        title: Text(
                          L10n.t('settings_menu'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18),
                        ),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final bool prevMock = svc.enableMockRoute;
                          final result =
                              await Navigator.of(context).push<SettingsData>(
                            MaterialPageRoute(
                              builder: (_) => SettingsPage(
                                initialMaxKmh: maxKmh,
                                initialThemeColor: _themeColor,
                                initialEnableBootAnimation:
                                    _enableBootAnimation,
                                initialEnableMockRoute: svc.enableMockRoute,
                                initialUseMiles: _useMiles,
                                initialLanguage: _language,
                              ),
                            ),
                          );
                          if (result != null && mounted) {
                            setState(() {
                              _useMiles = result.useMiles;
                              final currentDisplay =
                                  _mpsToDisplay(svc.speedMps.value);
                              _gaugeFromKmh = currentDisplay;
                              _numberFromKmh = currentDisplay;
                              _displayInt = currentDisplay.round();
                              _lastTargetKmh = currentDisplay;
                              _gaugeDisplayKmh =
                                  _mpsToDisplay(svc.speedMps.value);

                              maxKmh = result.maxKmh;
                              _themeColor = result.themeColor;
                              _enableBootAnimation = result.enableBootAnimation;
                              svc.enableMockRoute = result.enableMockRoute;
                              _language = result.language;
                            });
                            // 同步語言到全域並保存
                            Setting.instance.setLanguage(_language);
                            // 更新全局主題色
                            // 更新全局主題色
                            Setting.instance.setThemeSeed(_themeColor);
                            await _saveSettings();
                            // 若切換了模擬模式，重新啟動追蹤以套用資料來源（GPS ⇄ 模擬）
                            if (prevMock != svc.enableMockRoute) {
                              try {
                                if (svc.isRunning.value) {
                                  await svc.stop();
                                }
                                await svc.start();
                              } catch (_) {
                                // 忽略：可能權限/背景等因素；使用者可手動開始
                              }
                            }
                            // 若關閉再開啟自檢，返回後可立即以新上限重跑一次
                            if (_enableBootAnimation) {
                              _initBootAnimation();
                            }
                          }
                        },
                      ),
                    );
                    // 旅程列表
                    items.add(ListTile(
                      leading:
                          const Icon(Icons.list, color: Colors.lightBlueAccent),
                      title: Text(L10n.t('trip_list'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      onTap: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const TripsListPage()),
                        );
                      },
                    ));

                    // 停止旅程
                    items.addAll([
                      ListTile(
                        leading:
                            const Icon(Icons.stop, color: Colors.redAccent),
                        title: Text(L10n.t('end_trip'),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 18)),
                        subtitle: Text(
                          L10n.t('end_trip_sub'),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        onTap: () async {
                          Navigator.of(context).pop();
                          await _stopAndSaveFromAnywhere();
                        },
                      ),
                    ]);
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 44,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          ...items,
                          const SizedBox(height: 16),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  final svc = TrackingService();

  Future<String?> _promptTripName(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String?>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(L10n.t('name_this_trip'),
              style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: DateFormat('MM/dd HH:mm').format(DateTime.now()),
              hintStyle: const TextStyle(color: Colors.white54),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              // 先取消焦點，再關閉對話框，避免 KeyUpEvent 狀態不一致警告
              FocusScope.of(ctx).unfocus();
              Navigator.of(ctx).pop(controller.text.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                FocusScope.of(ctx).unfocus();
                Navigator.of(ctx).pop(null);
              },
              child: Text(L10n.t('cancel')),
            ),
            TextButton(
              onPressed: () {
                FocusScope.of(ctx).unfocus();
                Navigator.of(ctx).pop(controller.text.trim());
              },
              child: Text(L10n.t('save')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showThankYouDialog() async {
    if (!mounted) return;
    final isLight = appLightMode.value;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E1E1E),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Text(L10n.t('premium', lang: _language)),
          content: Text(L10n.t('restore_success', lang: _language)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(L10n.t('ok', lang: _language)),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _showUpgradeDialog() async {
    bool purchased = false;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // 避免尚未完成購買就被關閉
      builder: (ctx) {
        bool buying = false;
        return StatefulBuilder(
          builder: (ctx, setState) {
            final isLight = appLightMode.value;
            return WillPopScope(
              onWillPop: () async => !buying, // 購買中禁止返回
              child: AlertDialog(
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF1E1E1E),
                title: Text(
                  L10n.t('upgrade_paywall_title'),
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.t('upgrade_paywall_message'),
                      style: TextStyle(
                        color: isLight ? Colors.black87 : Colors.white70,
                        height: 1.45,
                      ),
                    ),
                    if (buying) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ],
                ),
                actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                actions: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed:
                              buying ? null : () => Navigator.of(ctx).pop(),
                          child: Text(
                            L10n.t('upgrade_later'),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            elevation: 0,
                          ),
                          onPressed: buying
                              ? null
                              : () async {
                                  setState(() => buying = true);
                                  try {
                                    final ok = await PurchaseService()
                                        .buyPremium(context);
                                    purchased = ok;
                                    if (ok) {
                                      // 讓感謝視窗在 finally 關掉付費牆後再跳出
                                      Future.microtask(
                                          () => _showThankYouDialog());
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                            duration: const Duration(
                                                milliseconds: 500),
                                            content: Text(
                                                '${L10n.t('purchase_failed_prefix')}$e')),
                                      );
                                    }
                                    purchased = false;
                                  } finally {
                                    if (mounted) {
                                      setState(() => buying = false);
                                    }
                                    // 完成後再關閉對話框，讓外層能拿到正確結果
                                    Navigator.of(ctx).pop();
                                  }
                                },
                          child: Text(L10n.t('upgrade_buy')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    return purchased;
  }

  // Gauge config/state
  double maxKmh = kDefaultMaxKmh; // 可在設定頁調整上限
  Color _themeColor = Colors.green; // 主題色（影響速度色帶起點）
  bool _enableBootAnimation = true; // 是否啟用開機自檢動畫
  bool _useMiles = false; // 單位：false=公里, true=英里
  String _language = 'zh-TW'; // App 語言：'zh-TW' | 'zh-CN' | 'en'

  AnimationController? _bootCtl;
  Animation<double>? _bootAnim;
  double _bootKmh = 0.0;
  bool _booting = true; // 啟動自檢動畫：0 -> max -> 0
  // 補間起點快取：讓動畫從「上一個值」補到新值，而不是每次從 0 開始
  double _gaugeFromKmh = 0.0;
  double _numberFromKmh = 0.0;
  // 針與色條的「滑動顯示值」（以固定最大速率趨近目標），避免跳過去
  double _gaugeDisplayKmh = 0.0;
  Ticker? _gaugeTicker;
  Duration _lastGaugeTick = Duration.zero;
  // 指針最大移動速率（顯示單位：km/h 每秒）。數值越大越「跟手」，越小越「滑順」。
  static const double _kGaugeMaxKmhpsNormal = 50.0; //儀表平滑
  static const double _kGaugeMaxKmhpsBoot = 900.0; //自檢

  void _initBootAnimation() {
    _bootCtl?.dispose();
    _booting = true;
    _gaugeDisplayKmh = 0.0;
    _gaugeFromKmh = 0.0;
    _numberFromKmh = 0.0;
    _bootCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    final curved = CurvedAnimation(parent: _bootCtl!, curve: Curves.easeInOut);
    _bootAnim = Tween<double>(begin: 0, end: maxKmh).animate(curved)
      ..addListener(() {
        setState(() => _bootKmh = _bootAnim!.value);
      })
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _bootCtl!.reverse();
        } else if (s == AnimationStatus.dismissed) {
          setState(() => _booting = false);
        }
      });
    _bootCtl!.forward();
  }

  // Top status row: clock & weather
  late final Timer _clockTimer;
  String _clockText = '';
  String _tempText = '--°C';
  Timer? _weatherTimer;

  // 最近一次取得的天氣（供保存旅程時寫入）
  double? _lastTempC;
  DateTime? _lastWeatherAt;
  double? _lastWeatherLat;
  double? _lastWeatherLon;

  Color _speedColor(double ratio) {
    // ratio: 0.0 ~ 1.0
    if (ratio <= 0.6) {
      return Color.lerp(_themeColor, Colors.yellow, ratio / 0.6)!;
    } else if (ratio <= 0.85) {
      // 0.6 ~ 0.85 之間由黃漸橘
      return Color.lerp(Colors.yellow, Colors.orange, (ratio - 0.6) / 0.25)!;
    } else {
      // 0.85 以上橘漸紅
      return Color.lerp(Colors.orange, Colors.red, (ratio - 0.85) / 0.15)!;
    }
  }

  String _fmtKm(double meters) => (meters / 1000).toStringAsFixed(2);
  String _fmtHms(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  // ===== 單位換算與格式化 =====
  String get _speedUnit => _useMiles ? 'mph' : 'km/h';
  double _mpsToDisplay(double mps) => _useMiles ? (mps * 2.23694) : (mps * 3.6);
  double _kmhToDisplay(double kmh) => _useMiles ? (kmh * 0.621371) : kmh;

  String formatSpeedFromMps(double mps, {int fractionDigits = 1}) {
    final v = _mpsToDisplay(mps);
    return '${v.toStringAsFixed(fractionDigits)} $_speedUnit';
  }

  String formatDistance(double meters) {
    if (_useMiles) {
      return '${(meters / 1609.34).toStringAsFixed(2)} mi';
    } else {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
  }

  // 格式化海拔（主頁用，根據 _useMiles）
  String _formatAltitudeHome(double meters) {
    return _useMiles
        ? '${(meters * 3.28084).toStringAsFixed(1)} ft'
        : '${meters.toStringAsFixed(1)} m';
  }

  // 角度轉方位字母（四象限）：N/E/S/W
  String _cardinalFromDeg(double deg) {
    final d = (deg % 360 + 360) % 360; // 0..360
    if (d >= 45 && d < 135) return 'E';
    if (d >= 135 && d < 225) return 'S';
    if (d >= 225 && d < 315) return 'W';
    return 'N';
  }

  void _updateClock() {
    final now = DateTime.now();
    _clockText =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (mounted) setState(() {});
  }

  Future<void> _fetchWeather() async {
    try {
      // 1) 確認定位服務與權限（weather 取當前定位）
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return; // 定位未開，保持舊值

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return; // 沒權限就不更新，保留原本文字
      }

      // 2) 先拿最後一次位置，失敗再取即時位置（加上超時）
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low, // 天氣不需高精度，成功率更高
        timeLimit: const Duration(seconds: 8),
      );
      if (pos == null) return;

      _lastWeatherLat = pos.latitude;
      _lastWeatherLon = pos.longitude;

      // 3) 呼叫 Open-Meteo 取得溫度（避免超時）
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=${pos.latitude}&longitude=${pos.longitude}'
        '&current=temperature_2m&timezone=auto',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final current = data['current'] as Map<String, dynamic>?;
      final temp = current?['temperature_2m'];
      if (temp is num) {
        _lastTempC = temp.toDouble();
        _lastWeatherAt = DateTime.now();
        _tempText = '${temp.toStringAsFixed(0)}°C';
        if (mounted) setState(() {});
      }
    } catch (_) {
      // 忽略錯誤，維持原值（--°C 或上一筆）
    }
  }

  /// Detect system locale using the first preferred language (iOS: Language & Region → top of the list)
  /// Maps to app keys: 'zh-TW' | 'zh-CN' | 'en', default fallback: 'en'.
  String _detectSystemLanguage() {
    // Use the first preferred locale instead of the single negotiated locale
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    final locale = locales.isNotEmpty
        ? locales.first
        : WidgetsBinding.instance.platformDispatcher.locale;

    final lang = locale.languageCode.toLowerCase();
    final country = (locale.countryCode ?? '').toUpperCase();
    final script = (locale.scriptCode ?? '').toLowerCase();

    if (lang == 'zh') {
      // Traditional Chinese: Hant script or regions TW/HK/MO
      if (script == 'hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        return 'zh-TW';
      }
      // Default Chinese → Simplified
      return 'zh-CN';
    }
    if (lang == 'en') return 'en';
    // Fallback to English for unsupported languages
    return 'en';
  }

  Future<void> _loadSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$kSettingsFile');
      if (await file.exists()) {
        final txt = await file.readAsString();
        final data = jsonDecode(txt) as Map<String, dynamic>;
        final double? mk = (data['maxKmh'] as num?)?.toDouble();
        final int? colorVal = data['themeColor'] as int?;
        final bool? boot = data['enableBootAnimation'] as bool?;
        final bool? mock = data['enableMockRoute'] as bool?;
        final bool? light = data['useLightMode'] as bool?;
        if (mounted) {
          setState(() {
            if (mk != null && mk >= 60 && mk <= 300) {
              maxKmh = mk;
            }
            if (colorVal != null) {
              _themeColor = Color(colorVal);
              Setting.instance.setThemeSeed(_themeColor);
            }
            if (boot != null) {
              _enableBootAnimation = boot;
            }
            // 模擬模式不影響 UI 佈局，直接套到服務層
            if (mock != null) {
              svc.enableMockRoute = mock;
            }
            final bool? miles = data['useMiles'] as bool?;
            if (miles != null) {
              _useMiles = miles;
            }
            if (light != null) appLightMode.value = light;
            // Use saved language if present; otherwise detect once
            final String? savedLang = data['language'] as String?;
            if (savedLang == 'zh-TW' ||
                savedLang == 'zh-CN' ||
                savedLang == 'en') {
              _language = savedLang!;
            } else {
              _language = _detectSystemLanguage();
            }
            // 同步到全域，讓其他頁（含設定頁）立刻知道目前語言
            Setting.instance.setLanguage(_language);
          });
        }
      } else {
        // First launch: detect once and remember
        _language = _detectSystemLanguage();
        // Persist initial detection so subsequent launches keep user's choice
        unawaited(_saveSettings());
      }
    } catch (_) {
      _language = _detectSystemLanguage();
    }
    if (mounted) {
      Setting.instance.setLanguage(_language);
    }
  }

  Future<void> _saveSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$kSettingsFile');
      final map = <String, dynamic>{
        'maxKmh': maxKmh,
        'themeColor': _themeColor.value,
        'enableBootAnimation': _enableBootAnimation,
        'enableMockRoute': svc.enableMockRoute,
        'useMiles': _useMiles,
        'useLightMode': appLightMode.value,
        'language': _language,
      };
      await file.writeAsString(jsonEncode(map));
    } catch (_) {
      // 忽略寫入錯誤
    }
  }

  Future<bool> _saveTrip() async {
    final trip = svc.currentTrip;
    if (trip == null) return false;
    bool purchasedDuringFlow = false; // 記錄此保存流程中是否剛完成購買
    // 若在保存流程中(_inSaveFlow)且此刻已是 VIP（可能因購買成功旗標已先更新），
    // 亦視為剛完成購買的一次性放寬，避免因旗標先更新而錯過 purchasedDuringFlow=true 的設定。
    if (_inSaveFlow && PurchaseService().isPremiumUnlocked) {
      purchasedDuringFlow = true;
    }
    // 非 VIP 限制：最多只能保存 1 筆旅程（VIP 不限）
    if (!PurchaseService().isPremiumUnlocked) {
      try {
        // 使用「有效旅程數」計算，會自動清掉壞檔，避免誤判
        final validCount = await TripStore.instance.countValidTrips();
        if (validCount >= 1) {
          if (mounted) {
            // 先以 SnackBar 告知，再彈出升級提示窗（引導購買）
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  duration: const Duration(milliseconds: 500),
                  content: Text(L10n.t('free_limit_one_unlock_vip'))),
            );
            final didPurchase = await _showUpgradeDialog();
            if (!didPurchase) {
              return false; // 使用者未完成購買 → 中止保存
            }
            // ✅ 購買完成：立刻繼續保存這次旅程（不再等待 isPremiumUnlocked 旗標延遲更新）
            purchasedDuringFlow = true;
          }
        }
      } catch (_) {
        // 檢查失敗時，不擋存檔以免誤傷用戶（可依需要改為 return）
      }
    }

    // 同步當前統計值到 Trip 物件（避免寫入 0）
    trip.distanceMeters = svc.distanceMeters.value;
    trip.maxSpeedMps = svc.maxSpeedMps.value;
    trip.movingSeconds = svc.movingSeconds.value;
    trip.stoppedSeconds = svc.stoppedSeconds.value;

    // 重新計算平均速（以移動秒數為分母）
    if (trip.movingSeconds > 0) {
      trip.avgSpeedMps = trip.distanceMeters / trip.movingSeconds;
    }
    // 若移動時間過短，直接不保存並提示
    final int movingSec = svc.movingSeconds.value;
    if (movingSec < kMinMovingSecondsToSave && !purchasedDuringFlow) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(
                '${L10n.t('trip_too_short_not_saved')} (${L10n.t('moved_only')} $movingSec${L10n.t('sec_abbr')})'),
          ),
        );
      }
      return false;
    }
    // 將最近的天氣快照寫入旅程
    trip.weatherProvider = 'open-meteo';
    trip.weatherTempC = _lastTempC;
    trip.weatherAt = _lastWeatherAt;
    trip.weatherLat = _lastWeatherLat;
    trip.weatherLon = _lastWeatherLon;
    trip.unit = _useMiles ? 'mi' : 'km';
    final jsonStr = const JsonEncoder.withIndent('  ').convert(trip.toJson());

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateFormat('yyyyMMdd_HHmmss').format(trip.startAt);
    final file = File('${dir.path}/trip_$ts.json');
    await file.writeAsString(jsonStr);

    // === 同步寫入新格式到 trips/{id}.json，供 TripDetail 直接讀取 ===
    try {
      final tripsDir = Directory('${dir.path}/trips');
      if (!await tripsDir.exists()) {
        await tripsDir.create(recursive: true);
      }

      final id = 'trip_$ts';

      // 展開 samples 成為 arrays 與 points
      final s = trip.samples;
      final List<String> tsList = s.map((e) => e.ts.toIso8601String()).toList();
      final List<double> latList = s.map((e) => e.lat).toList();
      final List<double> lonList = s.map((e) => e.lon).toList();
      final List<double?> altList = s.map((e) => e.alt).toList();
      if (kDebugMode) {
        final nonNullAlt = altList.where((e) => e != null).length;
        debugPrint(
            'saveTrip: samples=${s.length}, altitude non-null=$nonNullAlt');
      }
      final List<double> speedList = s.map((e) => e.speedMps).toList();
      final List<List<double>> points = [
        for (final e in s) [e.lat, e.lon]
      ];

      // bounds: left=minLng, top=maxLat, right=maxLng, bottom=minLat
      double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
      for (int i = 0; i < latList.length; i++) {
        final la = latList[i];
        final lo = lonList[i];
        if (la < minLat) minLat = la;
        if (la > maxLat) maxLat = la;
        if (lo < minLng) minLng = lo;
        if (lo > maxLng) maxLng = lo;
      }

      final normalized = {
        'id': id,
        'name': trip.name ?? '未命名旅程',
        // geo for縮圖/地圖
        'points': points,
        if (latList.isNotEmpty)
          'bounds': {
            'minLat': minLat,
            'minLng': minLng,
            'maxLat': maxLat,
            'maxLng': maxLng,
          },
        // 時序資料（詳情頁曲線/播放）
        'ts': tsList,
        'lat': latList,
        'lon': lonList,
        'alt': altList,
        'speedMps': speedList,
        // 摘要欄位
        'startTime': trip.startAt.toIso8601String(),
        'endTime': (trip.endAt ?? DateTime.now()).toIso8601String(),
        'totalDistanceMeters': trip.distanceMeters,
        'movingTimeMs': trip.movingSeconds * 1000,
        'avgSpeedMps': trip.avgSpeedMps,
        'maxSpeedMps': trip.maxSpeedMps,
        'preferredUnit': _useMiles ? 'mi' : 'km',
        // 天氣快照
        'weatherProvider': trip.weatherProvider,
        'weatherTempC': trip.weatherTempC,
        'weatherAt': trip.weatherAt?.toIso8601String(),
        'weatherLat': trip.weatherLat,
        'weatherLon': trip.weatherLon,
      };

      final normalizedFile = File('${tripsDir.path}/$id.json');
      await normalizedFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(normalized));
    } catch (_) {
      // 不阻塞主流程
    }

    final idx = File('${dir.path}/trips_index.txt');
    final displayKm = (trip.distanceMeters / 1000).toStringAsFixed(2);
    final namePart =
        (trip.name == null || trip.name!.isEmpty) ? '' : '\t${trip.name}';
    final line =
        '$ts, ${(trip.endAt ?? DateTime.now()).toIso8601String()}, ${displayKm}km$namePart\n';
    await idx.writeAsString(line, mode: FileMode.append);

    if (mounted) {
      final shown = (trip.name == null || trip.name!.isEmpty)
          ? L10n.t('saved')
          : '${L10n.t('saved_named_prefix')}「${trip.name}」';

      if (purchasedDuringFlow) {
        // 購買成功且已成功保存旅程 → 顯示感謝視窗
        // 不阻塞後續 Snackbar，使用 unawaited 方式彈出
        // ignore: unawaited_futures

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              duration: const Duration(milliseconds: 500),
              content: Text(L10n.t('thanks_for_upgrading_saved_now'))),
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text('$shown：${file.path}')),
      );
    }

// ⚠️ 有些清單頁面可能 cache 了索引，這裡盡力刷新一次（若無此 API 會被 try/catch 吃掉）

    return true;
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _weatherTimer?.cancel();
    _bootCtl?.dispose();
    svc.stop();
    _digitTimer?.cancel();
    _gaugeTicker?.stop();
    _gaugeTicker?.dispose();
    _gaugeTicker = null;
    _adTimer?.cancel();
    _linkSub?.cancel();
    _linkSub = null;

    // Remove background recording preference listener
    if (_bgPrefListener != null) {
      Setting.instance.backgroundRecording.removeListener(_bgPrefListener!);
      _bgPrefListener = null;
    }

    WidgetsBinding.instance.removeObserver(this);
    Setting.instance.language.removeListener(_updateQuickActions);
    Setting.instance.language.removeListener(_onLanguageChanged);
    super.dispose();
  }

  // 語言改變時觸發主畫面重建
  void _onLanguageChanged() {
    if (!mounted) return;
    _language = Setting.instance.language.value; // 同步目前語言到本頁狀態
    unawaited(_saveSettings()); // 立刻持久化，避免下次又讀回舊值
    setState(() {}); // 觸發主頁重建
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_restoreMaxKmh);
    // 啟動時若尚未授權，主動提醒一次（之後每次開啟都會提醒）
    // 監聽 VIP 變化：一旦購買成功，取消任何已排程的廣告
    PurchaseService().onPurchaseUpdated = () {
      if (PurchaseService().isPremiumUnlocked) {
        _adTimer?.cancel();
        _adScheduled = false;
      }
      if (mounted) setState(() {});
    };
    PurchaseService().onIapBusyChanged = (busy) {
      if (busy) {
        _adTimer?.cancel();
        _adScheduled = false;
        AdService.instance.dispose();
      } else {
        if (!PurchaseService().isPremiumUnlocked) {
          _scheduleOnceAd();
        }
      }
    };
    Future.microtask(() => _checkLocationPermissionOnLaunch());
    // Home screen quick actions（桌面圖標長按）
    _qa.initialize(_onQuickAction);
    _updateQuickActions();
    // 冷啟
    getInitialUri().then((uri) => _handleIncomingUri(uri)).catchError((_) {});
// 熱啟
    _linkSub = uriLinkStream.listen((uri) {
      _handleIncomingUri(uri);
    }, onError: (_) {});
// 語言切換時，更新快捷選單的本地化文字
    Setting.instance.language.addListener(_updateQuickActions);
    Setting.instance.language.addListener(_onLanguageChanged);

    // 時鐘：每 30 秒更新一次（顯示 HH:mm）
    _updateClock();
    _clockTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _updateClock());

    // 天氣：啟動時取一次，之後每 5 分鐘更新（需求調整）
    _fetchWeather();
    _weatherTimer?.cancel();
    _weatherTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _fetchWeather());

    // Gauge ticker: 固定速率滑動顯示值
    _gaugeTicker = createTicker((elapsed) {
      final dt = (elapsed - _lastGaugeTick).inMicroseconds / 1e6;
      _lastGaugeTick = elapsed;
      if (dt <= 0) return;

      // 目標顯示值：開機自檢時跟著自檢，否則跟即時速度（顯示單位）
      final double targetDisplay = _booting
          ? _kmhToDisplay(_bootKmh)
          : _mpsToDisplay(svc.speedMps.value);

      // 以固定最大速率趨近目標，避免「跳過去」
      final double maxKmhps =
          _booting ? _kGaugeMaxKmhpsBoot : _kGaugeMaxKmhpsNormal;
      final double maxStep = maxKmhps * dt; // 本次允許的最大跨越（km/h）
      final double diff = targetDisplay - _gaugeDisplayKmh;

      if (diff.abs() <= maxStep) {
        if (diff.abs() > 0.0001) {
          _gaugeDisplayKmh = targetDisplay;
          if (mounted) setState(() {});
        }
      } else {
        _gaugeDisplayKmh += (diff.isNegative ? -maxStep : maxStep);
        if (mounted) setState(() {});
      }
    });
    _gaugeTicker!.start();

    // 先載入設定，再依據 maxKmh 啟動自檢動畫；完成後自動開始追蹤
    _loadSettings().whenComplete(() {
      debugPrint('initState completed, _language=$_language');
      if (_enableBootAnimation) {
        _initBootAnimation();
      } else {
        setState(() {
          _booting = false;
          _gaugeFromKmh = 0.0;
          _numberFromKmh = 0.0;
        });
      }
      // 嘗試自動啟動追蹤（第一次會請求權限）
      Future.microtask(() async {
        try {
          final bg = await _getBgRecordingPref();
          await svc.start(allowBackground: bg);
        } catch (_) {
          // 權限或服務未開啟時忽略；使用者可從控制面板手動開始
        }
      });
    });
    // 在啟動後排程 10 秒只顯示一次插頁式廣告
    _scheduleOnceAd();

    // 即時監聽設定頁「背景持續記錄」開關，立即作用 TrackingService
    _bgPrefListener = () {
      final wantBg = Setting.instance.backgroundRecording.value;
      Future.microtask(() async {
        try {
          if (wantBg) {
            if (svc.isRunning.value) {
              await svc.stop();
            }
            await svc.start(allowBackground: true);
          } else {
            await svc.stop();
          }
        } catch (_) {}
      });
    };
    Setting.instance.backgroundRecording.addListener(_bgPrefListener!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_inSaveFlow) {
        // 正在保存旅程（命名/寫檔）期間，禁止自動重啟追蹤與廣告，以免洗掉當前 Trip
        return;
      }
      // 回到前景時也再次檢查，未授權則彈窗引導
      _checkLocationPermissionOnLaunch();
      // 回前景：若手動暫停則尊重使用者；否則自動恢復追蹤
      if (svc.isManuallyPaused.value) return;
      if (!svc.isRunning.value) {
        _getBgRecordingPref()
            .then((bg) => svc.start(allowBackground: bg))
            .catchError((_) {});
      } else {
        svc.resume();
      }
      // 回到前景後 10 秒只顯示一次插頁式廣告；
      // 但若是因為插頁式關閉而觸發的 resumed（通常在幾秒內），就略過避免形成循環。
      final now = DateTime.now();
      final justShown = _lastAdShownAt != null &&
          now.difference(_lastAdShownAt!) < const Duration(seconds: 15);
      if (!justShown) {
        _scheduleOnceAd();
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _adTimer?.cancel();
      _adScheduled = false;
      // 使用者若未開啟「背景持續記錄」，退到背景時停止定位串流，避免仍在背景回報
      _getBgRecordingPref().then((bg) async {
        if (!bg) {
          await svc.stop();
        }
      });
    }
  }

  Future<void> _checkLocationPermissionOnLaunch() async {
    // 1) 先檢查系統定位是否開啟
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      await _showPermissionDialog(
        title: L10n.t('need_location_service_title'),
        message: L10n.t('need_location_service_msg'),
        goSettings: () async {
          await Geolocator.openLocationSettings();
        },
      );
      return;
    }

    // 2) 檢查/要求 App 定位權限
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      // 要求權限（首次安裝或先前拒絕）
      perm = await Geolocator.requestPermission();
      // 若這次獲得授權，立刻更新一次天氣，避免右上角空白
      if (perm != LocationPermission.denied &&
          perm != LocationPermission.deniedForever) {
        // 不阻塞對話框流程，靜默觸發
        // ignore: unawaited_futures
        _fetchWeather();
      }
    }

    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (!mounted) return;
      await _showPermissionDialog(
        title: L10n.t('need_location_permission_title'),
        message: L10n.t('need_location_permission_msg'),
        goSettings: () async {
          // iOS 被拒後通常需前往系統設定調整
          await Geolocator.openAppSettings();
        },
      );
    } else {
      // 權限已就緒（原本就有或剛拿到），再嘗試刷新一次天氣
      // ignore: unawaited_futures
      _fetchWeather();
    }
  }

  Future<void> _showPermissionDialog({
    required String title,
    required String message,
    required Future<void> Function() goSettings,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(message, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(L10n.t('later')),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await goSettings();
              },
              child: Text(L10n.t('go_settings')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final big = Theme.of(context).textTheme.displayLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        );

    return Scaffold(
      appBar: null,
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  // 頂部狀態列（避免被動態島蓋住）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 左：時間
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _clockText,
                            style: TextStyle(
                              fontSize: 18,
                              color: Theme.of(context).colorScheme.onBackground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      // 中：方位（僅在移動且偵測到方向時顯示）
                      Expanded(
                        child: Align(
                          alignment: Alignment.center,
                          child: ValueListenableBuilder2<double, double?>(
                            a: svc.speedMps,
                            b: svc.headingDeg,
                            builder: (context, sp, hdg, __) {
                              final hasSpeed =
                                  _mpsToDisplay(sp) > 0.0; // 只要有時速就顯示
                              if (!hasSpeed || hdg == null) {
                                return const SizedBox.shrink();
                              }
                              final label = _cardinalFromDeg(hdg);
                              return Text(
                                '$label ${hdg.round()}°',
                                style: TextStyle(
                                  fontSize: 18,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onBackground,
                                  fontWeight: FontWeight.w700,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      // 右：溫度
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            _tempText,
                            style: TextStyle(
                              fontSize: 18,
                              color: Theme.of(context).colorScheme.onBackground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 中段自適應區域（無捲動、無溢出）
                  Expanded(
                    child: Column(
                      children: [
                        // 儀表：在可用空間內維持正方形，盡量放大
                        Expanded(
                          flex: 7,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final size = math.min(constraints.maxWidth * 0.99,
                                  constraints.maxHeight * 0.99);
                              // 指針與色條採用固定最大速率「滑動」到目標值（_gaugeDisplayKmh）
                              final maxDisplay = _kmhToDisplay(maxKmh);
                              final color = _speedColor(
                                  (_gaugeDisplayKmh / maxDisplay)
                                      .clamp(0.0, 1.0));
                              return Center(
                                child: SpeedGauge(
                                  value: _gaugeDisplayKmh,
                                  maxValue: maxDisplay,
                                  size: size,
                                  primaryColor: color,
                                  backgroundColor: Colors.grey.shade800,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 0),
                        // 大數字 + 單位：往上微移，貼近儀表
                        Builder(
                          builder: (context) {
                            // 動態拉近儀表：依螢幕高自適應（-28 ~ -64）
                            final screenH = MediaQuery.of(context).size.height;
                            final lift =
                                -math.min(64.0, math.max(28.0, screenH * 0.05));
                            return Transform.translate(
                              offset: Offset(0, lift),
                              child: LayoutBuilder(
                                builder: (context, box) {
                                  // 以可用寬度為基準取 24% 做字體大小，限制在 80~200 之間
                                  final fs =
                                      (box.maxWidth * 0.2).clamp(80.0, 200.0);
                                  final unitFs = (fs * 0.2).clamp(16.0, 36.0);
                                  return ValueListenableBuilder<double>(
                                    valueListenable: svc.speedMps,
                                    builder: (_, v, __) {
                                      final targetDisplay = _booting
                                          ? _kmhToDisplay(_bootKmh)
                                          : _mpsToDisplay(v);
                                      // 停車時（< 1 km/h / 或 < 0.6 mph）立即收斂到 0，讓 0 來得更乾脆
                                      final snapToZeroThreshold = _useMiles
                                          ? 1.24
                                          : 2.0; // 2 km/h 或 1.24 mph
                                      final endDisplay =
                                          (targetDisplay < snapToZeroThreshold)
                                              ? 0.0
                                              : targetDisplay;
                                      // 無補間：直接顯示即時速度文字
                                      final text =
                                          endDisplay.round().toString();
                                      return Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.baseline,
                                        textBaseline: TextBaseline.alphabetic,
                                        children: [
                                          Text(
                                            text,
                                            style: TextStyle(
                                              fontSize: fs,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1.0,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onBackground
                                                  .withOpacity(0.92),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _speedUnit,
                                            style: TextStyle(
                                              fontSize: unitFs,
                                              color: Colors.grey,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              ),
                            );
                          },
                        ),

                        // 狀態標籤跟著大數字一起上移
                        Builder(
                          builder: (context) {
                            final screenH = MediaQuery.of(context).size.height;
                            final lift =
                                -math.min(64.0, math.max(28.0, screenH * 0.05));
                            // 比大數字少一點（保留間距），因此乘上 0.85
                            final labelLift = lift * 0.85;
                            return Transform.translate(
                              offset: Offset(0, labelLift),
                              child: ValueListenableBuilder<bool>(
                                valueListenable: svc.hasStarted,
                                builder: (_, started, ___) {
                                  return ValueListenableBuilder2<double, bool>(
                                    a: svc.speedMps,
                                    b: svc.isManuallyPaused,
                                    builder: (_, mps, manualPaused, __) {
                                      if (manualPaused || !started) {
                                        return Text(
                                          L10n.t('paused'),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Colors.orange,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        );
                                      }
                                      final rawDisplay = _mpsToDisplay(mps);
                                      final currentDisplay = (_booting
                                          ? _kmhToDisplay(_bootKmh)
                                          : rawDisplay);
                                      final bool isMoving = currentDisplay >=
                                          (_useMiles
                                              ? (kStrictStopKmh * 0.621371)
                                              : kStrictStopKmh);
                                      return Text(
                                        isMoving
                                            ? L10n.t('moving')
                                            : L10n.t('auto_paused'),
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: isMoving
                                              ? Colors.green
                                              : Colors.orange,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                        // 六項統計：使用 FittedBox 以避免小螢幕溢出
                        Expanded(
                          flex: 3,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _showControlsSheet,
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16.0),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 左欄
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            _Stat(
                                              title: L10n.t('distance'),
                                              child: ValueListenableBuilder<
                                                  double>(
                                                valueListenable:
                                                    svc.distanceMeters,
                                                builder: (_, m, __) => Text(
                                                  formatDistance(m),
                                                  style: const TextStyle(
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.w700),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            _Stat(
                                              title: L10n.t('altitude'),
                                              child: ValueListenableBuilder<
                                                  double>(
                                                valueListenable:
                                                    svc.altitudeMeters,
                                                builder: (_, alt, __) => Text(
                                                  _formatAltitudeHome(
                                                      alt), // ← 依 _useMiles 顯示 ft 或 m
                                                  style: const TextStyle(
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.w700),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            _Stat(
                                              title: L10n.t('stopped_time'),
                                              child:
                                                  ValueListenableBuilder<int>(
                                                valueListenable:
                                                    svc.stoppedSeconds,
                                                builder: (_, s, __) => Text(
                                                  _fmtHms(s),
                                                  style: const TextStyle(
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.w700),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 32),
                                      // 右欄
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            _Stat(
                                              title: L10n.t('max_speed'),
                                              child: ValueListenableBuilder<
                                                  double>(
                                                valueListenable:
                                                    svc.maxSpeedMps,
                                                builder: (_, mps, __) => Text(
                                                  formatSpeedFromMps(mps),
                                                  style: const TextStyle(
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.w700),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            _Stat(
                                              title: L10n.t('avg_speed'),
                                              child: ValueListenableBuilder2<
                                                  double, int>(
                                                a: svc.distanceMeters,
                                                b: svc.movingSeconds,
                                                builder: (_, m, s, __) {
                                                  final vMps =
                                                      (s > 0) ? (m / s) : 0.0;
                                                  return Text(
                                                    formatSpeedFromMps(vMps),
                                                    style: const TextStyle(
                                                        fontSize: 18,
                                                        fontWeight:
                                                            FontWeight.w700),
                                                  );
                                                },
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            _Stat(
                                              title: L10n.t('total_time'),
                                              child: ValueListenableBuilder2<
                                                  int, int>(
                                                a: svc.movingSeconds,
                                                b: svc.stoppedSeconds,
                                                builder: (_, ms, stopS, __) {
                                                  final total = ms +
                                                      stopS; // 全部停止（自動+手動）都計入總時間
                                                  return Text(
                                                    _fmtHms(total),
                                                    style: const TextStyle(
                                                        fontSize: 18,
                                                        fontWeight:
                                                            FontWeight.w700),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 控制列改由點擊統計區呼叫底部選單，不常駐顯示
                  const SizedBox.shrink(),
                ],
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: FloatingActionButton(
                heroTag: 'settings_fab',
                mini: false,
                backgroundColor: Theme.of(context)
                    .colorScheme
                    .surfaceVariant
                    .withOpacity(0.3),
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                elevation: 0,
                onPressed: () async {
                  final bool prevMock = svc.enableMockRoute;
                  final result = await Navigator.of(context).push<SettingsData>(
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(
                        initialMaxKmh: maxKmh,
                        initialThemeColor: _themeColor,
                        initialEnableBootAnimation: _enableBootAnimation,
                        initialEnableMockRoute: svc.enableMockRoute,
                        initialUseMiles: _useMiles,
                        initialLanguage: _language,
                      ),
                    ),
                  );
                  if (result != null && mounted) {
                    setState(() {
                      _useMiles = result.useMiles;
                      final currentDisplay = _mpsToDisplay(svc.speedMps.value);
                      _gaugeFromKmh = currentDisplay;
                      _numberFromKmh = currentDisplay;
                      _displayInt = currentDisplay.round();
                      _lastTargetKmh = currentDisplay;
                      _gaugeDisplayKmh = _mpsToDisplay(svc.speedMps.value);

                      maxKmh = result.maxKmh;
                      _themeColor = result.themeColor;
                      _enableBootAnimation = result.enableBootAnimation;
                      svc.enableMockRoute = result.enableMockRoute;
                      _language = result.language;
                    });
                    // 同步語言到全域並保存
                    Setting.instance.setLanguage(_language);
                    // 更新全局主題色
                    // 更新全局主題色
                    Setting.instance.setThemeSeed(_themeColor);
                    await _saveSettings();
                    // 若切換了模擬模式，重新啟動追蹤以套用資料來源（GPS ⇄ 模擬）
                    if (prevMock != svc.enableMockRoute) {
                      try {
                        if (svc.isRunning.value) {
                          await svc.stop();
                        }
                        await svc.start();
                      } catch (_) {
                        // 忽略：可能權限/背景等因素；使用者可手動開始
                      }
                    }
                    // 若關閉再開啟自檢，返回後可立即以新上限重跑一次
                    if (_enableBootAnimation) {
                      _initBootAnimation();
                    }
                  }
                },
                child: const Icon(Icons.settings, size: 30),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//錄影模式 ios通道

class ScreenRecorder {
  static const _ch = MethodChannel('screen_recorder');

  static Future<bool> start({bool mic = true}) async {
    final ok = await _ch.invokeMethod<bool>('startRecording', {'mic': mic});
    return ok ?? false;
  }

  /// 停止錄影；iOS 會跳出 Apple 的預覽/儲存面板
  static Future<bool> stop() async {
    final ok = await _ch.invokeMethod<bool>('stopRecording');
    return ok ?? false;
  }
}

//錄影模式
/// === Camera HUD Overlay (疊在相機畫面上) ===
class CameraHudOverlay extends StatelessWidget {
  final ValueListenable<double> speedMps;
  final ValueListenable<double?> headingDeg;
  final bool useMiles;
  // 新增：把主頁的統計也帶進來
  final ValueListenable<double> maxSpeedMps;
  final ValueListenable<double> altitudeMeters;
  final ValueListenable<double> distanceMeters;
  final ValueListenable<int> movingSeconds;
  final ValueListenable<int> stoppedSeconds;

  const CameraHudOverlay({
    super.key,
    required this.speedMps,
    required this.headingDeg,
    required this.useMiles,
    required this.maxSpeedMps,
    required this.altitudeMeters,
    required this.distanceMeters,
    required this.movingSeconds,
    required this.stoppedSeconds,
  });
  String _cardinalFromDeg(double deg) {
    final d = (deg % 360 + 360) % 360; // 0..360
    if (d >= 45 && d < 135) return 'E';
    if (d >= 135 && d < 225) return 'S';
    if (d >= 225 && d < 315) return 'W';
    return 'N';
  }

  String _unit(bool miles) => miles ? 'mph' : 'km/h';
  double _mpsToDisplay(double mps) => useMiles ? (mps * 2.23694) : (mps * 3.6);
  String _formatSpeedFromMps(double mps, {int fractionDigits = 1}) {
    final v = _mpsToDisplay(mps);
    return '${v.toStringAsFixed(fractionDigits)} ${_unit(useMiles)}';
  }

  String _formatDistance(double meters) {
    if (useMiles) {
      return '${(meters / 1609.34).toStringAsFixed(2)} mi';
    } else {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
  }

  String _fmtHms(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // 讓整個 HUD 不攔截觸控（相機頁面自己處理）
    return IgnorePointer(
      child: Stack(
        children: [
          // ====== 上方：方向小膠囊 + 大速度，靠近瀏海 ======
          SafeArea(
            top: true,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 方向（有速度與方位時才顯示）
                  Center(
                    child: ValueListenableBuilder2<double, double?>(
                      a: speedMps,
                      b: headingDeg,
                      builder: (_, sp, hdg, __) {
                        final hasSpeed = _mpsToDisplay(sp) > 0.0;
                        if (!hasSpeed || hdg == null)
                          return const SizedBox.shrink();
                        final deg = hdg.round();
                        final label = _cardinalFromDeg(hdg);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$label $deg°',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 大速度：直接放在瀏海下方
                  Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: speedMps,
                      builder: (_, v, __) {
                        final display = _mpsToDisplay(v);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              display.round().toString(),
                              style: const TextStyle(
                                fontSize: 120,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                shadows: [
                                  Shadow(
                                      blurRadius: 8,
                                      color: Colors.black54,
                                      offset: Offset(0, 1)),
                                  Shadow(
                                      blurRadius: 16,
                                      color: Colors.black54,
                                      offset: Offset(0, 2)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _unit(useMiles),
                              style: const TextStyle(
                                fontSize: 22,
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(
                                      blurRadius: 8,
                                      color: Colors.black54,
                                      offset: Offset(0, 1)),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ====== 下方：資訊面板（模仿主頁六項統計） ======
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _hudStat(
                            title: '距離',
                            child: ValueListenableBuilder<double>(
                              valueListenable: distanceMeters,
                              builder: (_, m, __) => Text(_formatDistance(m),
                                  style: const TextStyle(fontSize: 16)),
                            ),
                          ),
                          _hudStat(
                            title: '海拔',
                            child: ValueListenableBuilder<double>(
                              valueListenable: altitudeMeters,
                              builder: (_, alt, __) => Text(
                                  '${alt.toStringAsFixed(1)} m',
                                  style: const TextStyle(fontSize: 16)),
                            ),
                          ),
                          _hudStat(
                            title: '停止時間',
                            child: ValueListenableBuilder<int>(
                              valueListenable: stoppedSeconds,
                              builder: (_, s, __) => Text(_fmtHms(s),
                                  style: const TextStyle(fontSize: 16)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _hudStat(
                            title: '最高速',
                            child: ValueListenableBuilder<double>(
                              valueListenable: maxSpeedMps,
                              builder: (_, mps, __) => Text(
                                  _formatSpeedFromMps(mps),
                                  style: const TextStyle(fontSize: 16)),
                            ),
                          ),
                          _hudStat(
                            title: '平均速',
                            child: ValueListenableBuilder2<double, int>(
                              a: distanceMeters,
                              b: movingSeconds,
                              builder: (_, m, s, __) {
                                final vMps = (s > 0) ? (m / s) : 0.0;
                                return Text(_formatSpeedFromMps(vMps),
                                    style: const TextStyle(fontSize: 16));
                              },
                            ),
                          ),
                          _hudStat(
                            title: '總時間',
                            child: ValueListenableBuilder2<int, int>(
                              a: movingSeconds,
                              b: stoppedSeconds,
                              builder: (_, ms, stopS, __) {
                                final total = ms + stopS;
                                return Text(_fmtHms(total),
                                    style: const TextStyle(fontSize: 16));
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hudStat({required String title, required Widget child}) {
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }
}

/// ==== Speed Gauge (CustomPainter, 270°) ====
class SpeedGauge extends StatelessWidget {
  final double value; // km/h
  final double maxValue; // km/h
  final double size; // widget size (square)
  final Color primaryColor;
  final Color backgroundColor;

  const SpeedGauge({
    super.key,
    required this.value,
    required this.maxValue,
    this.size = 240,
    this.primaryColor = Colors.green,
    this.backgroundColor = const Color(0xFF424242),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(
          value: value,
          maxValue: maxValue,
          primaryColor: primaryColor,
          backgroundColor: backgroundColor,
          labelColor: Theme.of(context).colorScheme.onBackground,
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value; // km/h
  final double maxValue; // km/h
  final Color primaryColor;
  final Color backgroundColor;
  final Color labelColor;

  _GaugePainter({
    required this.value,
    required this.maxValue,
    required this.primaryColor,
    required this.backgroundColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // 270° 弧：從 135° 開始掃到 405°
    final double startAngle = 3 * math.pi / 4; // 135°
    final double sweepAngle = 3 * math.pi / 2; // 270°

    // === 動態刻度密度 ===
    double majorStep; // 主刻度的 km/h 間隔
    double minorStep; // 細刻度的 km/h 間隔
    double labelFontScale; // 高上限時縮小字體
    if (maxValue <= 200) {
      majorStep = 20;
      minorStep = 10;
      labelFontScale = 1.0;
    } else if (maxValue <= 300) {
      majorStep = 40;
      minorStep = 20;
      labelFontScale = 0.92;
    } else {
      majorStep = 60;
      minorStep = 20; // 或 30，這裡維持 20 以兼顧細節
      labelFontScale = 0.85;
    }

    final Rect arcRect = Rect.fromCircle(center: center, radius: radius * 0.95);

    // 背景弧
    final Paint bgArc = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.1
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, startAngle, sweepAngle, false, bgArc);

    // 值弧
    final double ratio = (value / maxValue).clamp(0.0, 1.0);
    final Paint valArc = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.1
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, startAngle, sweepAngle * ratio, false, valArc);

    // === 刻度設定 ===
    final double tickOuter = radius * 0.95;
    final double tickInnerMajor = radius * 0.78;
    final double tickInnerMinor = radius * 0.86; // 細刻度較短

    final Paint minorTickPaint = Paint()
      ..color = Colors.grey.shade500
      ..strokeWidth = 2.0;
    final Paint majorTickPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 3.0;

    // === 細刻度（不顯示數字） ===
    for (double v = 0.0; v <= maxValue + 0.001; v += minorStep) {
      final double t = (v / maxValue).clamp(0.0, 1.0);
      final double a = startAngle + sweepAngle * t;
      final bool isMajor = (v % majorStep).abs() < 0.001 ||
          v == 0.0 ||
          (v - maxValue).abs() < 0.001;
      final Offset p1 = center + Offset(math.cos(a), math.sin(a)) * tickOuter;
      final Offset p2 = center +
          Offset(math.cos(a), math.sin(a)) *
              (isMajor ? tickInnerMajor : tickInnerMinor);
      canvas.drawLine(p1, p2, minorTickPaint);
    }

    // === 主刻度 + 數字（只顯示 majorStep） ===
    final double labelR = radius * 0.63;
    for (double v = 0.0; v <= maxValue + 0.001; v += majorStep) {
      final double t = (v / maxValue).clamp(0.0, 1.0);
      final double a = startAngle + sweepAngle * t;
      final Offset p1 = center + Offset(math.cos(a), math.sin(a)) * tickOuter;
      final Offset p2 =
          center + Offset(math.cos(a), math.sin(a)) * tickInnerMajor;
      canvas.drawLine(p1, p2, majorTickPaint);

      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: v.round().toString(),
          style: TextStyle(
            color: labelColor,
            fontSize: radius * 0.08 * labelFontScale,
            fontWeight: FontWeight.w600,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: ui.TextDirection.ltr,
      )..layout();

      final Offset labelPos =
          center + Offset(math.cos(a), math.sin(a)) * labelR;
      tp.paint(canvas, labelPos - Offset(tp.width / 2, tp.height / 2));
    }

    // 指針
    final double needleAngle = startAngle + sweepAngle * ratio;
    final double needleLen = radius * 0.75;
    final Paint needlePaint = Paint()
      ..color = primaryColor
      ..strokeWidth = radius * 0.02
      ..strokeCap = StrokeCap.round;
    final Offset needleEnd = center +
        Offset(math.cos(needleAngle), math.sin(needleAngle)) * needleLen;
    canvas.drawLine(center, needleEnd, needlePaint);

    // 中心旋鈕
    canvas.drawCircle(center, radius * 0.05, Paint()..color = primaryColor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _Stat extends StatelessWidget {
  final String title;
  final Widget child;
  const _Stat({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // 基於寬度做簡單縮放：iPhone 390pt 為基準
    final scale = (w / 390.0).clamp(0.85, 1.4);
    final titleSize = 14.0 * scale;
    final valueSize = 24.0 * scale; // 原本 16 → 放大並可自適應
    return Column(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: titleSize,
            color: Colors.grey,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 6),
        DefaultTextStyle(
          style: TextStyle(
            fontSize: valueSize,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onBackground,
            letterSpacing: 0.4,
          ),
          child: child,
        ),
      ],
    );
  }
}

class TripsListPage extends StatelessWidget {
  const TripsListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t('trip_list')),
      ),
      body: const TripsListBody(),
      backgroundColor: Colors.black,
    );
  }
}

/// 兩個 ValueListenable 同步監聽的小幫手
class ValueListenableBuilder2<A, B> extends StatelessWidget {
  final ValueListenable<A> a;
  final ValueListenable<B> b;
  final Widget Function(BuildContext, A, B, Widget?) builder;
  final Widget? child;
  const ValueListenableBuilder2({
    super.key,
    required this.a,
    required this.b,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<A>(
      valueListenable: a,
      builder: (context, va, _) {
        return ValueListenableBuilder<B>(
          valueListenable: b,
          builder: (context, vb, __) => builder(context, va, vb, child),
        );
      },
    );
  }
}

// 新版速度腳本：等待 5s → (加速 10s 到 vmax → 減速 10s → 等待 2s) ×2 → 加速 10s → 減速 10s
double _mockSpeedForTickV2(
  int tick, {
  required int ticksWait0,
  required int ticksAcc,
  required int ticksDec,
  required int ticksPause,
  required double vmax,
  required double dtSec,
}) {
  // 區段長度
  final int lenCycleDynamic = ticksAcc + ticksDec; // 單輪動態時長
  final int lenCycleWithPause = lenCycleDynamic + ticksPause; // 含等待

  // 邊界
  final int b0 = ticksWait0; // 0..b0：等待
  final int b1 = b0 + lenCycleDynamic; // 第一輪動態
  final int b1w = b0 + lenCycleWithPause; // 第一輪 + 等待
  final int b2 = b1w + lenCycleDynamic; // 第二輪動態
  final int b2w = b1w + lenCycleWithPause; // 第二輪 + 等待
  final int b3 = b2w + lenCycleDynamic; // 第三輪動態（最終）

  // 等待 5 秒
  if (tick <= b0) return 0.0;

  // 第一輪（無巡航）：加速 10s → 減速 10s
  if (tick <= b1) {
    final k = tick - b0; // 0..lenCycleDynamic
    if (k <= ticksAcc) {
      // 線性加速：0 → vmax
      final double a = vmax / (ticksAcc * dtSec);
      final double t = k * dtSec;
      return a * t;
    } else {
      // 線性減速：vmax → 0
      final int k2 = k - ticksAcc;
      final double a = vmax / (ticksDec * dtSec);
      final double t = k2 * dtSec;
      return math.max(0.0, vmax - a * t);
    }
  }

  // 第一輪等待 2 秒
  if (tick <= b1w) return 0.0;

  // 第二輪（無巡航）
  if (tick <= b2) {
    final k = tick - b1w;
    if (k <= ticksAcc) {
      final double a = vmax / (ticksAcc * dtSec);
      final double t = k * dtSec;
      return a * t;
    } else {
      final int k2 = k - ticksAcc;
      final double a = vmax / (ticksDec * dtSec);
      final double t = k2 * dtSec;
      return math.max(0.0, vmax - a * t);
    }
  }

  // 第二輪等待 2 秒
  if (tick <= b2w) return 0.0;

  // 第三輪（無等待收尾）
  if (tick <= b3) {
    final k = tick - b2w;
    if (k <= ticksAcc) {
      final double a = vmax / (ticksAcc * dtSec);
      final double t = k * dtSec;
      return a * t;
    } else {
      final int k2 = k - ticksAcc;
      final double a = vmax / (ticksDec * dtSec);
      final double t = k2 * dtSec;
      return math.max(0.0, vmax - a * t);
    }
  }

  // 結束後保持 0
  return 0.0;
}
