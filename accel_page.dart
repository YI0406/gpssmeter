// lib/accel/accel_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
// import 'setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'accel_records_page.dart';
import 'package:gps_speedometer_min/setting.dart'; // ensure single Setting singleton across app

/// ====== 模式 ======
enum AccelMode {
  zeroTo50,
  zeroTo60,
  zeroTo100,
  zeroTo400m,
  hundredTo200,
}

extension AccelModeLabel on AccelMode {
  String get title {
    final useMph = Setting.instance.useMph;
    String uSpeed = useMph ? 'mph' : 'km/h';
    int toMph(num kmh) => (kmh * 0.621371).round();
    switch (this) {
      case AccelMode.zeroTo50:
        return useMph ? '0–${toMph(50)} $uSpeed' : '0–50 $uSpeed';
      case AccelMode.zeroTo60:
        return useMph ? '0–${toMph(60)} $uSpeed' : '0–60 $uSpeed';
      case AccelMode.zeroTo100:
        return useMph ? '0–${toMph(100)} $uSpeed' : '0–100 $uSpeed';
      case AccelMode.zeroTo400m:
        // 距離模式維持公制顯示（m），不受 useMph 影響
        return '0–400 m';
      case AccelMode.hundredTo200:
        return useMph
            ? '${toMph(100)}–${toMph(200)} $uSpeed'
            : '100–200 $uSpeed';
    }
  }
}

/// ====== 記錄模型 ======
class AccelRecord {
  final String id; // yyyyMMdd_HHmmss_隨機
  String name; // 可改名
  final AccelMode mode;
  final DateTime startedAt;
  final int elapsedMs; // 成績（毫秒）
  final double startSpeedKmh;
  final double endSpeedKmh;
  final double distanceM; // 實際跑出距離
  final List<_Point> samples; // 可選：保留路徑/速度
  final bool useMph; // 當時的單位 true=mph, false=km/h

  AccelRecord({
    required this.id,
    required this.name,
    required this.mode,
    required this.startedAt,
    required this.elapsedMs,
    required this.startSpeedKmh,
    required this.endSpeedKmh,
    required this.distanceM,
    required this.samples,
    required this.useMph,
  });

  /// Minimal constructor used by import/export when only summary fields exist.
  factory AccelRecord.minimal({
    required String id,
    required String name,
    required AccelMode mode,
    required DateTime startedAt,
    required int elapsedMs,
    required double endSpeedKmh,
    required double distanceM,
    required bool useMph,
  }) {
    return AccelRecord(
      id: id,
      name: name,
      mode: mode,
      startedAt: startedAt,
      elapsedMs: elapsedMs,
      startSpeedKmh: 0.0, // 匯入的扁平資料沒有起始速度 → 給 0
      endSpeedKmh: endSpeedKmh, // 已有
      distanceM: distanceM, // 0–400m 可給 400，其他給 0
      samples: <_Point>[], // 扁平資料不含軌跡 → 空陣列
      useMph: useMph,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode.name,
        'useMph': useMph,
        'startedAt': startedAt.toIso8601String(),
        'elapsedMs': elapsedMs,
        'startSpeedKmh': startSpeedKmh,
        'endSpeedKmh': endSpeedKmh,
        'distanceM': distanceM,
        'samples': samples.map((e) => e.toJson()).toList(),
      };

  static AccelRecord fromJson(Map<String, dynamic> j) => AccelRecord(
        id: j['id'],
        name: j['name'],
        useMph: (j['useMph'] as bool?) ?? false,
        mode: AccelMode.values.firstWhere((m) => m.name == j['mode']),
        startedAt: DateTime.parse(j['startedAt']),
        elapsedMs: j['elapsedMs'],
        startSpeedKmh: (j['startSpeedKmh'] as num).toDouble(),
        endSpeedKmh: (j['endSpeedKmh'] as num).toDouble(),
        distanceM: (j['distanceM'] as num).toDouble(),
        samples: (j['samples'] as List).map((e) => _Point.fromJson(e)).toList(),
      );
}

class _Point {
  final double speedKmh;
  final double distanceM;
  final DateTime ts;
  _Point(this.speedKmh, this.distanceM, this.ts);
  Map<String, dynamic> toJson() => {
        'v': speedKmh,
        'd': distanceM,
        't': ts.toIso8601String(),
      };
  static _Point fromJson(Map<String, dynamic> j) => _Point(
      (j['v'] as num).toDouble(),
      (j['d'] as num).toDouble(),
      DateTime.parse(j['t']));
}

/// ====== 本地儲存 ======
class AccelStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/accel_records.json');
  }

  static Future<List<AccelRecord>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final txt = await f.readAsString();
      final List arr = jsonDecode(txt);
      return arr.map((e) => AccelRecord.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<AccelRecord> list) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<void> append(AccelRecord r) async {
    final list = await load();
    list.add(r);
    await saveAll(list);
  }

  static Future<void> delete(String id) async {
    final list = await load();
    list.removeWhere((e) => e.id == id);
    await saveAll(list);
  }

  static Future<void> rename(String id, String newName) async {
    final list = await load();
    final i = list.indexWhere((e) => e.id == id);
    if (i >= 0) {
      list[i].name = newName;
      await saveAll(list);
    }
  }
}

/// ====== 速度來源（改為 GPS 真實速度）======
/// 會先檢查並請求權限；優先使用 Position.speed（m/s），
/// 若 speed 不可用則以兩點距離 / Δt 推算速度。
class SpeedSource {
  Stream<double> getStream() async* {
    await _ensureLocationReady();

    Position? last;
    DateTime? lastTs;

    const settings = LocationSettings(
      accuracy: LocationAccuracy.best, // 最高精度
      distanceFilter: 0, // 不以距離節流，交給上層濾波
      timeLimit: null,
    );

    await for (final p
        in Geolocator.getPositionStream(locationSettings: settings)) {
      final now = DateTime.now();

      // 1) 優先用裝置回報的瞬時速度（m/s -> km/h）
      double vKmh =
          (p.speed.isNaN || p.speed.isInfinite) ? 0 : (p.speed ?? 0) * 3.6;

      // 2) 若 speed 不可用或為 0，則用距離/時間推算
      if ((p.speed == null || p.speed == 0) && last != null && lastTs != null) {
        final dt = now.difference(lastTs!).inMilliseconds / 1000.0;
        if (dt > 0) {
          final d = Geolocator.distanceBetween(
            last!.latitude,
            last!.longitude,
            p.latitude,
            p.longitude,
          ); // 公尺
          final vMs = d / dt;
          vKmh = vMs * 3.6;
        }
      }

      // 3) 簡單的異常值過濾（過大抖動剔除：> 350km/h 視為無效）
      if (vKmh.isNaN || vKmh.isInfinite || vKmh > 350) {
        // 丟棄這筆，繼續等下一筆
        last = p;
        lastTs = now;
        continue;
      }

      // 更新 last
      last = p;
      lastTs = now;

      yield vKmh;
    }
  }

  static Future<void> _ensureLocationReady() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // 可選：這裡不直接丟錯，交由 UI 告知使用者開啟定位服務
      // 為了不中斷流程，先嘗試仍然繼續，實務上建議在進入頁面前就提示。
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      throw Exception('定位權限被拒絕，無法取得 GPS 速度');
    }
  }
}

/// ====== G 值資料類 ======
class GReading {
  final double gx; // 水平 X（螢幕左負右正）
  final double gy; // 垂直 Y（螢幕上正下負，採用 -userY 讓上為正）
  final double g; // 平面合成(√(gx^2+gy^2))
  const GReading(this.gx, this.gy, this.g);
}

/// ====== G 值來源（使用 userAccelerometer 去除重力，單位 g）======
class GSource {
  /// 輸出為 2D G 值（gx, gy, g），每次取樣做中位數去抖。
  Stream<GReading> getStream() async* {
    const g0 = 9.80665;
    final winX = <double>[];
    final winY = <double>[];
    const winSize = 5;
    await for (final e in userAccelerometerEvents) {
      final gxRaw = e.x / g0;
      final gyRaw = -e.y / g0; // 讓螢幕上方為正
      if (gxRaw.isNaN || gyRaw.isNaN) continue;
      winX.add(gxRaw);
      winY.add(gyRaw);
      if (winX.length > winSize) winX.removeAt(0);
      if (winY.length > winSize) winY.removeAt(0);
      final sx = [...winX]..sort();
      final sy = [...winY]..sort();
      final gx = sx[sx.length ~/ 2];
      final gy = sy[sy.length ~/ 2];
      final g = sqrt(gx * gx + gy * gy);
      yield GReading(gx, gy, g);
    }
  }
}

// Helper for recent move accumulation (top-level; Dart doesn't allow nested classes)
class _RecentMove {
  final DateTime ts;
  final double d;
  const _RecentMove(this.ts, this.d);
}

// Helper for still-window accumulation using absolute distance (always integrated)
class _StillPoint {
  final double absM;
  final DateTime ts;
  _StillPoint(this.absM, this.ts);
}

/// ====== 抗抖＆啟停判定器 ======
/// - 速度以「中位數濾波+EMA」去抖
/// - 以最近3秒位移<1.5m 當作靜止 → 顯示 0（你之前喜歡的規則）
/// - 啟動：連續樣本速度 >= startGateKmh（預設 5 km/h）
/// - 0~400m 用距離積分，100~200 用跨越門檻的時間戳
class AccelEngine with ChangeNotifier {
  // 來自主頁的「總里程（公尺）」；若提供，0–400m 以它為準
  final ValueListenable<double>? externalTotalDistanceM;
  VoidCallback? _extDistDetach;
  double? _startBaseDistM; // 起跑當下的基準總里程（公尺）
  final AccelMode mode;
  final Stream<double> speedKmhStream;
  // G 感測 G值門檻
  final Stream<GReading>? gStream;
  GReading _g = const GReading(0, 0, 0);
  GReading get currentG => _g;
  final double gStartThreshold = 0.08; // ≈0.08 g ~ 0.78 m/s^2
  final Duration gConfirm = const Duration(milliseconds: 100);
  DateTime? _gArmSince;
  StreamSubscription<GReading>? _gSub;

  final _medianWin = <double>[];
  final int _medianWinSize = 5;
  double _ema = 0;
  final double emaAlpha = 0.45;

  // 靜止偵測
  final _lastPoints = <_Point>[];
  final Duration stillWindow = const Duration(seconds: 3);
  final double stillDistanceM = 1.5;

  // 絕對位移積分（不論是否在跑都會積分，供 still-window 用）
  double _absDistM = 0; // 累積的絕對位移（不論是否在跑都會積分）
  final List<_StillPoint> _stillBuf = <_StillPoint>[];

  // 啟停門檻
  final double startGateKmh = 3; // >=3 km/h 視為開始移動
  final double target50 = 50;
  final double target60 = 60;
  final double target100 = 100;
  final double target200 = 200;
  final double target400m = 400; //  0~400距離設定
  final double gateEps = 0.01; // 目標門檻容差（km/h）
  // 100–200 專用回滯門檻（依你的規則）
  final double startCross100 = 100.0; // 必須上穿 100 起跑
  final double abortDrop100 = 99.9; // 未達標前 ≤99.9 立刻作廢
  // 與主頁一致：顯示層 < 2 km/h 視為 0
  final double snapZeroKmh = 2.0;

  // 觸發確認（抗抖）：
  final Duration startConfirm = Duration.zero; // 起步門檻需連續滿足（已移除延遲）
  final Duration crossConfirm = Duration.zero; // 跨越門檻需連續滿足（已移除延遲）
  final Duration stopConfirm = const Duration(milliseconds: 1200); // 停車需連續靜止
  // 在加速模式中，停住時希望更快結束：連續 400ms 速度為 0 即視為真的停住
  final Duration stopConfirmRunning = const Duration(milliseconds: 400);
  DateTime? _zeroSince; // 速度為 0 的起始時間
  // 若在計時中且速度掉到起步門檻以下，連續一小段時間就視為放棄本次（直接重置）
  final Duration lowSpeedAbort = const Duration(milliseconds: 400);
  DateTime? _lowSince; // raw 低於起步門檻(startGateKmh) 的起始時間
  // 100–200 模式：掉回 <=100 的確認時間，避免單點抖動誤清零
  final Duration drop100Confirm = const Duration(milliseconds: 150);
  DateTime? _drop100Since;

  // 更寬鬆的 0 速容忍：0–400m 允許短暫掉到 0，不立即重置
  Duration get _stopZeroDuringRun => mode == AccelMode.zeroTo400m
      ? const Duration(seconds: 2)
      : stopConfirmRunning;

  Duration get _rawZeroHardStopDur => mode == AccelMode.zeroTo400m
      ? const Duration(seconds: 2)
      : const Duration(milliseconds: 300);

  // 原始速度為 0 的確認（避免 EMA 尾巴把速度拖住）
  final Duration rawZeroConfirm = const Duration(milliseconds: 600);
  DateTime? _rawZeroSince; // 連續偵測到 vKmhRaw <= 0.5 的起始時間
  // 0 速看門狗：連續原始 0 速達 1.2s 無條件 reset（防一切卡表）
  final Duration zeroWatchdog = const Duration(milliseconds: 1200);

  DateTime? _startArmSince;
  DateTime? _stillSince;

  // 狀態
  bool get isRunning => _running;
  bool _running = false;
  // READY：不在跑且顯示速度為 0 就顯示（避免依賴中介旗標而漏顯示）
  bool get isReady => !_running && (_lastSpeed == 0.0);
  bool _isStoppedZero = true;
  bool _pendingResetAfterSave = false; // 儲存完成後等待「停車且 G=0」再立刻回 READY

  int _elapsedMs = 0;
  int get elapsedMs => _elapsedMs;

  // 保留上一筆成績的時間，直到下一次起步才清零
  bool _holdLast = false;

  double _lastSpeed = 0;
  double _distanceM = 0;
  double get distanceM => _distanceM;

  DateTime? _tStart;
  DateTime? _tHit100;
  DateTime? _tFinish;

  double _startSpeed = 0;
  double _endSpeed = 0;

  final List<_Point> _samples = [];
  StreamSubscription<double>? _sub;
  Timer? _ticker;
  DateTime? _lastSpeedUpdateAt; // 最後一次 _onSpeed() 更新時間

  // ---- DEBUG: 0–400m 距離追蹤 ----
  DateTime? _dbgLastLog;
  double _dbgLastDist = -1;

  // 加速有效性檢查
  double _peakSpeedKmh = 0; // 目前為止的最高速
  bool _invalidDecel = false; // 期間發生減速 → 作廢
  bool _reachedGoal = false; // 是否已達成目標（速度或距離）
  DateTime? _decelSince; // 連續減速起始時間（抗抖用）
  double get decelEpsKmh => 0.8;
  // 達標當下的速度（km/h），供 UI 顯示
  double _lastGoalSpeedKmh = double.nan;
  double get lastGoalSpeedKmh => _lastGoalSpeedKmh;

  // for script runs: allow first start without READY in debug
  bool _everStarted = false;

  // For 100–200 re-arm: must drop below 100 before a new run
  bool _needDropBelow100 = false;
  double _prevRawKmh = 0.0; // previous raw speed (km/h) for edge detection

  // 防止同一輪重複 finish
  bool _hasFinished = false;

  // --- SFX: ding (play once, clamp to 1s) ---
  final AudioPlayer _sfxDing = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  Future<void> _playDing1s() async {
    try {
      await _sfxDing.stop();
      // 播放專案 assets/audio/ding.mp3 （需在 pubspec.yaml 宣告）
      await _sfxDing.play(AssetSource('audio/ding.mp3'));
      // 最多播 1 秒就停止
      Future.delayed(const Duration(seconds: 1), () {
        _sfxDing.stop();
      });
    } catch (_) {}
  }

  AccelEngine({
    required this.mode,
    required this.speedKmhStream,
    this.gStream,
    this.externalTotalDistanceM,
  });

  void start() {
    _reset();
    _sub = speedKmhStream.listen(_onSpeed);
    if (gStream != null) {
      _gSub = gStream!.listen(_onG);
    }
    if (externalTotalDistanceM != null) {
      void push() {
        _onExternalDistance(externalTotalDistanceM!.value);
      }

      // seed once
      push();
      externalTotalDistanceM!.addListener(push);
      _extDistDetach = () {
        try {
          externalTotalDistanceM!.removeListener(push);
        } catch (_) {}
      };
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = DateTime.now();
      if (_running && _tStart != null) {
        _elapsedMs = now.difference(_tStart!).inMilliseconds;
        // --- 追加：即時看門狗，避免任何卡表 ---
        // 1) 若原始 0 速已持續達 zeroWatchdog，強制結束/重置
        if (_rawZeroSince != null &&
            now.difference(_rawZeroSince!) >= zeroWatchdog) {
          if (_reachedGoal) {
            _finish(now, _lastSpeed);
          }
          _reset();
          return;
        }
        // 2) 若顯示速度為 0 且 0 速持續超過 _stopZeroDuringRun，也結束/重置
        if (_zeroSince != null &&
            now.difference(_zeroSince!) >= _stopZeroDuringRun) {
          if (_reachedGoal) {
            _finish(now, _lastSpeed);
          } else {
            _reset();
          }
          return;
        }
        // 3) 若速度來源停止更新超過 2 秒且顯示速度為 0，也重置（防資料流斷線）
        if (_lastSpeedUpdateAt != null &&
            now.difference(_lastSpeedUpdateAt!) >= const Duration(seconds: 2) &&
            _lastSpeed == 0.0) {
          _reset();
          return;
        }
        notifyListeners();
      } else {
        // 若不在跑，仍確保畫面碼表為 0
        if (!_running && _elapsedMs != 0 && _lastSpeed == 0.0 && !_holdLast) {
          _elapsedMs = 0;
          notifyListeners();
        }
      }
    });
  }

  void disposeEngine() {
    _ticker?.cancel();
    _sub?.cancel();
    _gSub?.cancel();
    _extDistDetach?.call();
    _extDistDetach = null;
  }

  void _reset({bool preserveElapsed = false, bool keepRearm = false}) {
    _medianWin.clear();
    _ema = 0;
    _lastPoints.clear();
    _running = false;
    _isStoppedZero = true;
    if (!preserveElapsed) {
      _elapsedMs = 0;
    }
    _distanceM = 0;
    _absDistM = 0;
    _stillBuf.clear();
    _tStart = null;
    _tHit100 = null;
    _tFinish = null;
    _startSpeed = 0;
    _endSpeed = 0;
    _samples.clear();
    _lastSpeed = 0;
    _startArmSince = null;
    _stillSince = null;
    _zeroSince = null;
    _rawZeroSince = null;
    _lowSince = null;
    _g = const GReading(0, 0, 0);
    _gArmSince = null;
    _peakSpeedKmh = 0;
    _invalidDecel = false;
    _reachedGoal = false;
    _decelSince = null;
    _drop100Since = null;
    // 確保 READY 狀態乾淨
    _isStoppedZero = true;
    _holdLast = preserveElapsed;
    _pendingResetAfterSave = false;
    // DEBUG 清理
    _dbgLastLog = null;
    _dbgLastDist = -1;
    _startBaseDistM = null;
    // re-arm 行為：若 keepRearm=true 且模式為 100–200，則保留「必須先掉回 ≤99.9」的要求
    if (!(keepRearm && mode == AccelMode.hundredTo200)) {
      _needDropBelow100 = false;
    }
    _prevRawKmh = 0.0;
    _hasFinished = false;
    notifyListeners();
  }

  void _onG(GReading r) {
    // 僅更新顯示用途，不參與啟動/停止判定
    _g = r;
    notifyListeners();
  }

  void _onExternalDistance(double totalMeters) {
    if (!totalMeters.isFinite) return;
    // 僅在 0–400m 模式採用外部距離作為進度
    if (mode != AccelMode.zeroTo400m) return;

    final now = DateTime.now();
    if (_running) {
      _startBaseDistM ??= totalMeters; // 起跑當下紀錄基準
      _distanceM = max(0.0, totalMeters - (_startBaseDistM ?? totalMeters));
      // 檢查達標（用外部距離）
      if (!_reachedGoal && _distanceM >= target400m) {
        _reachedGoal = true;
        // 記錄達標瞬間速度（沿用當前顯示速度）
        _lastGoalSpeedKmh = _lastSpeed;
        _finish(now, _lastSpeed);
        return;
      }
      notifyListeners();
    } else {
      // 未在跑時重置基準，避免舊基準影響下一次
      _startBaseDistM = null;
    }
  }

  void _onSpeed(double vKmhRaw) {
    final now = DateTime.now();
    // 1) 取『真實速度』：以輸入的 raw 值為準（已是 km/h）
    double raw = vKmhRaw.isFinite ? max(0.0, vKmhRaw) : 0.0;
    // 2) 顯示層與判定層僅做「<2 km/h → 0」的快照規則
    double vKmh = (raw < snapZeroKmh) ? 0.0 : raw;
    // 100–200 模式：達標後需要先掉到 ≤99.9 再次上穿 100 才能重新開始
    if (mode == AccelMode.hundredTo200 &&
        _needDropBelow100 &&
        raw <= abortDrop100) {
      _needDropBelow100 = false; // 已掉回到 100 以下，允許下一次觸發
      // ignore: avoid_print
      print(
          'ACCEL[rearm] cleared: raw<=${abortDrop100.toStringAsFixed(1)}, allow next start');
    }
    // 100–200 模式：一旦已啟動且尚未達標，期間速度『≤99.9』→ 立刻清零並回到等待狀態（此次作廢，不保存）
    if (mode == AccelMode.hundredTo200 &&
        _running &&
        !_reachedGoal &&
        (raw <= abortDrop100)) {
      // 立即作廢：清空樣本、旗標，直接 reset（不保存）
      _samples.clear();
      _holdLast = false;
      _reachedGoal = false;
      _hasFinished = false;
      // ignore: avoid_print
      print(
          'ACCEL[abort] drop<=${abortDrop100.toStringAsFixed(1)} during run (raw=${raw.toStringAsFixed(2)}, v=${vKmh.toStringAsFixed(2)}) → reset');
      _reset(preserveElapsed: false);
      return;
    }
    // 追蹤 raw 低於起步門檻的持續時間（用於快速放棄本次計時）
    if (raw < startGateKmh) {
      _lowSince ??= now;
    } else {
      _lowSince = null;
    }

    // 10.0) Watchdog：原始速度連續為 0 達 1.2s → 無條件 reset（防一切卡表），不受當前 raw 大小影響
    if (_running &&
        _rawZeroSince != null &&
        now.difference(_rawZeroSince!) >= zeroWatchdog) {
      // ignore: avoid_print
      print(
          'ACCEL[watchdog] rawZero >= ${zeroWatchdog.inMilliseconds}ms, force ${_reachedGoal ? 'finish' : 'reset'}');
      if (_reachedGoal) {
        _finish(now, (raw < snapZeroKmh) ? 0.0 : raw);
      }
      _reset();
      return;
    }

    // 追蹤『原始速度≈0』的持續時間（避免任何濾波或顯示層影響）
    if (raw <= 0.1) {
      _rawZeroSince ??= now;
    } else {
      _rawZeroSince = null;
    }

    // 3) 減速作廢＆峰值追蹤（僅在計時中）
    if (_running) {
      // 以顯示速度（已 snap-to-zero）追蹤峰值，避免極小抖動
      if (vKmh > _peakSpeedKmh) _peakSpeedKmh = vKmh;
      // 移除「減速作廢」：所有模式都不再以減速判作廢
      _decelSince = null;
      _invalidDecel = false;
    }

    // 4) 距離積分：使用「原始速度」積分，並對 dt 做上下限夾制
    double dt = _samples.isEmpty
        ? 0.2
        : now.difference(_samples.last.ts).inMilliseconds / 1000.0;
    // 夾範圍：避免 time glitch 讓 dt=0（不累積）或過大（瞬間跳躍）
    const double kDtMin = 0.05; // 至少 50ms
    const double kDtMax = 0.50; // 最多 500ms（位置流一般 10Hz 左右）
    if (!dt.isFinite || dt <= 0) dt = kDtMin;
    if (dt > kDtMax) dt = kDtMax;

    // 重要：距離一律用 RAW 速度積分（不受顯示層 <2km/h=0 的影響）
    final vMs = (raw <= 0.0) ? 0.0 : (raw / 3.6);
    final addDist = vMs * dt;

    // ---- DEBUG: dt 與積分輸入
    // ignore: avoid_print
    if (mode == AccelMode.zeroTo400m) {
      print(
          'ACCEL[dt] ts=${now.toIso8601String()} raw=${raw.toStringAsFixed(2)} '
          'dt=${dt.toStringAsFixed(3)} vMs=${vMs.toStringAsFixed(2)} add=${addDist.toStringAsFixed(2)}m '
          'running=${_running}');
    }

    _absDistM += addDist; // 絕對位移（供 still/停車用途）
    // 若提供了外部總距離（主頁），0–400m 不再使用內部積分
    if (!(_running &&
        mode == AccelMode.zeroTo400m &&
        externalTotalDistanceM != null)) {
      if (_running) _distanceM += addDist; // 成績距離（僅在跑時）
    }

    // 5) 記錄樣本（顯示速度 + 成績距離）
    _samples.add(_Point(vKmh, _distanceM, now));

    // ---- DEBUG: 0–400m 距離追蹤列印（節流）----
    if (mode == AccelMode.zeroTo400m) {
      final bool shouldLogTime = _dbgLastLog == null ||
          now.difference(_dbgLastLog!) >= const Duration(milliseconds: 400);
      final bool shouldLogDist =
          _dbgLastDist < 0 || (_distanceM - _dbgLastDist).abs() >= 10; // 每 10m
      if (shouldLogTime || shouldLogDist) {
        final total = _distanceM;
        final absTotal = _absDistM;
        // 將速度/距離/積分資訊完整列印，便於追查是否有距離被吃掉
        // raw=原始 km/h, vKmh=顯示 km/h, addDist=本次積分(m), total=成績距離(m), abs=絕對距離(m)
        // running/reached=狀態旗標
        // ts=樣本時間
        // ignore: avoid_print
        print(
            'ACCEL[400m] ts=${now.toIso8601String()} raw=${raw.toStringAsFixed(2)} '
            'v=${vKmh.toStringAsFixed(2)} add=${addDist.toStringAsFixed(2)}m '
            'dt=${dt.toStringAsFixed(3)} '
            'dist=${total.toStringAsFixed(2)}m abs=${absTotal.toStringAsFixed(2)}m '
            'running=${_running} reached=${_reachedGoal}');
        _dbgLastLog = now;
        _dbgLastDist = _distanceM;
      }
    }

    // 6) 零速持續時間（提供更快停表）
    if (vKmh == 0.0) {
      _zeroSince ??= now;
    } else {
      _zeroSince = null;
    }

    // 7) 若已保存且等待復位：非計時中且速度為 0 → 立刻回 READY
    if (!_running && _pendingResetAfterSave && vKmh == 0.0) {
      _pendingResetAfterSave = false;
      _reset(preserveElapsed: true); // 保留剛剛的成績時間
      return;
    }

    // 8) Ready 標籤與安全復位（與主頁一致）
    // --- Preserve previous READY state for start logic ---
    final bool wasStoppedZero = _isStoppedZero;
    if (!_running && vKmh == 0.0) {
      _isStoppedZero = true;
      if (!_holdLast) _elapsedMs = 0;
      _tStart = null;
      _tHit100 = null;
      _tFinish = null;
    } else {
      _isStoppedZero = false;
    }

    // 9) 啟動邏輯：用『原始速度』判斷（避免濾波延遲）
    // 在 100–200 模式，不需要先進入 READY（允許行進間跨越 100 即開始）
    final readyOk = (mode == AccelMode.hundredTo200)
        ? true
        : (wasStoppedZero || (kDebugMode && !_everStarted));
    if (!_running && readyOk) {
      if (mode == AccelMode.hundredTo200) {
        // 需要「上穿 100」且不在待降速狀態
        if (!_needDropBelow100 &&
            _prevRawKmh < startCross100 &&
            raw >= startCross100) {
          _tHit100 = now;
          _tStart = now;
          _startSpeed = 100;
          _running = true;
          _holdLast = false;
          _lastGoalSpeedKmh = double.nan;
          _elapsedMs = 0;
          _everStarted = true;
          _hasFinished = false; // 新一輪開始，清除完成旗標
          _hasFinished = false;
          // ---- 在 100–200 模式，不重置以下旗標 ----
          // _reachedGoal = false;        // 清除上輪達標狀態
          // _peakSpeedKmh = 0;           // 重新計算峰值
          // _invalidDecel = false;       // 清除減速作廢旗標
        } else if (_needDropBelow100) {
          // ignore: avoid_print
          print(
              'ACCEL[blockStart] needDropBelow100=true (raw=${raw.toStringAsFixed(2)})');
        }
      } else {
        if (raw >= startGateKmh) {
          _tStart = now;
          _startSpeed = raw;
          _running = true;
          // --- Ensure a clean second (and later) run for 0–400m ---
          if (mode == AccelMode.zeroTo400m) {
            // Always reset progress and samples at the moment of (re)start
            _distanceM = 0; // progress for this run
            _absDistM = 0; // also reset absolute move accumulator
            _samples.clear(); // avoid huge dt from previous run's tail
            _dbgLastLog = null; // clear debug throttles
            _dbgLastDist = -1;
            _reachedGoal = false; // clear any lingering goal state
            _hasFinished = false;

            if (externalTotalDistanceM != null) {
              // With external odometer, establish a fresh baseline now
              final cur = externalTotalDistanceM!.value;
              if (cur.isFinite) {
                _startBaseDistM = cur;
              } else {
                _startBaseDistM = null;
              }
            } else {
              // Internal integration path: ensure no old baseline influences this run
              _startBaseDistM = null;
            }
          }
          // --- Capture 0–400m baseline immediately at start when using external distance ---
          if (mode == AccelMode.zeroTo400m && externalTotalDistanceM != null) {
            final cur = externalTotalDistanceM!.value;
            if (cur.isFinite) {
              _startBaseDistM = cur; // use current total distance as baseline
              _distanceM = 0; // reset progress for this run
              // ignore: avoid_print
              print(
                  'ACCEL[400m] baseline set at start: base=${_startBaseDistM!.toStringAsFixed(1)}m');
            }
          }
          _holdLast = false;
          _lastGoalSpeedKmh = double.nan;
          _elapsedMs = 0;
          _everStarted = true;
          // 起跑時清乾淨旗標（0–50 / 0–60 / 0–100 / 0–400m），避免第二輪殘留造成無法 finish
          if (mode == AccelMode.zeroTo50 ||
              mode == AccelMode.zeroTo60 ||
              mode == AccelMode.zeroTo100 ||
              mode == AccelMode.zeroTo400m) {
            _reachedGoal = false;
            _hasFinished = false;
            _peakSpeedKmh = 0;
            _invalidDecel = false;
          }
        }
      }
    }
    // 若未在跑且速度=0，確保碼表顯示為 0（避免偶發未觸發的 redraw）
    if (!_running && vKmh == 0.0 && _elapsedMs != 0) {
      _elapsedMs = 0;
      notifyListeners();
    } else {
      // ---- DEBUG: 起跑訊息（僅在 _tStart 設定後的第一個樣本列印）----
      if (_running && _tStart != null && (_samples.isNotEmpty)) {
        final justStarted = _samples.length == 1; // 第一筆樣本
        if (justStarted) {
          // ignore: avoid_print
          print(
              'ACCEL[start] mode=${mode.name} tStart=${_tStart!.toIso8601String()} '
              'startSpeedKmh=${_startSpeed.toStringAsFixed(2)}');
        }
      }
      // 10.5) 低速放棄：在計時中但原始速度持續掉到起步門檻以下 → 直接 reset
      if (_running &&
          !_reachedGoal &&
          _lowSince != null &&
          now.difference(_lowSince!) >= lowSpeedAbort &&
          mode != AccelMode.zeroTo400m) {
        _reset();
        return;
      }

      // 10.4) 原始速度為 0 持續一小段時間 → 直接結束/重置（更強的保險，避免任何顯示層卡住）
      final rawZeroHardStop = _rawZeroHardStopDur;
      if (_running &&
          _rawZeroSince != null &&
          now.difference(_rawZeroSince!) >= rawZeroHardStop) {
        // ignore: avoid_print
        print(
            'ACCEL[hardStop] rawZero >= ${rawZeroHardStop.inMilliseconds}ms, ${_reachedGoal ? 'finish' : 'reset'}');
        if (_reachedGoal) {
          _finish(now, vKmh);
        } else {
          _reset();
        }
        return;
      }

      // 10) 達標立刻停表（全部用『原始速度/距離』判定）
      // 只在「計時中且尚未達標」時判斷，避免在達標後的後續樣本又覆寫資料（例如 0–400m 的 Max 速度）。
      if (_running && !_reachedGoal) {
        switch (mode) {
          case AccelMode.zeroTo50:
            if (raw >= target50) {
              _reachedGoal = true;
              _finish(now, vKmh);
            }
            break;
          case AccelMode.zeroTo60:
            if (raw >= target60) {
              _reachedGoal = true;
              _finish(now, vKmh);
            }
            break;
          case AccelMode.zeroTo100:
            if (raw >= target100) {
              _reachedGoal = true;
              _finish(now, vKmh);
            }
            break;
          case AccelMode.zeroTo400m:
            if (externalTotalDistanceM == null) {
              if (_distanceM >= target400m) {
                _reachedGoal = true;
                _lastGoalSpeedKmh = raw.isFinite ? max(0.0, raw) : 0.0;
                _finish(now, vKmh);
              }
            }
            break;
          case AccelMode.hundredTo200:
            if (raw >= target200) {
              _reachedGoal = true;
              // 達標後要求先掉到 100 以下才允許下一次起跑
              _needDropBelow100 = true;
              _finish(now, vKmh);
            }
            break;
        }
      }

      // 11) 零速快停：連續為 0 滿 600ms，結束本次（未達標→reset）
      if (_running &&
          _zeroSince != null &&
          now.difference(_zeroSince!) >= _stopZeroDuringRun) {
        // ignore: avoid_print
        print(
            'ACCEL[zeroStop] displayed 0 >= ${_stopZeroDuringRun.inMilliseconds}ms, ${_reachedGoal ? 'finish' : 'reset'}');
        if (_reachedGoal) {
          _finish(now, vKmh);
        } else {
          _reset();
        }
        return;
      }

      // 12) 備援：長一點的停車確認（維持相容）
      if (_running) {
        if (vKmh == 0.0) {
          _stillSince ??= now;
          if (now.difference(_stillSince!) >= stopConfirm) {
            if (_reachedGoal) {
              _finish(now, vKmh);
            }
            _reset();
            return;
          }
        } else {
          _stillSince = null;
        }
      }
    }

    _lastSpeed = vKmh; // UI 顯示用（已做 2km/h snap-to-zero）
    if (_running && _tStart != null) {
      _elapsedMs = DateTime.now().difference(_tStart!).inMilliseconds;
    }
    _lastSpeedUpdateAt = now;
    _prevRawKmh = raw;
    notifyListeners();
  }

  void _finish(DateTime now, double vKmh) async {
    if (_hasFinished) return; // 同一輪已完成，忽略
    if (!_running || _tStart == null) return;
    _tFinish = now;
    _endSpeed = vKmh;
    _elapsedMs = _tFinish!.difference(_tStart!).inMilliseconds;
    // Validation guards for bogus records
    const int minValidMs = 250;
    final bool invalidStart =
        (mode == AccelMode.zeroTo60 && _startSpeed >= target60) ||
            (mode == AccelMode.zeroTo100 && _startSpeed >= target100) ||
            (mode == AccelMode.hundredTo200 && _startSpeed >= target200);
    // ignore: avoid_print
    print('ACCEL[finish] mode=${mode.name} elapsedMs=${_elapsedMs} '
        'distM=${_distanceM.toStringAsFixed(2)} start=${_startSpeed.toStringAsFixed(2)} '
        'end=${vKmh.toStringAsFixed(2)} reached=${_reachedGoal} invalidDecel=${_invalidDecel}');
    if (invalidStart) {
      _invalidDecel = true;
      // 避免卡在 running 造成重複 finish，直接結束並重置
      _running = false;
      _reachedGoal = false;
      _holdLast = false;
      // ignore: avoid_print
      print(
          'ACCEL[drop] reason=invalidStart distM=${_distanceM.toStringAsFixed(2)} elapsedMs=${_elapsedMs} start=${_startSpeed.toStringAsFixed(2)}');
      _reset();
      return;
    }
    _running = false;
    _holdLast = true;
    _hasFinished = true;

    // 強化驗證：100–200 模式需確實達標（raw>=200）且整段峰值也達到 200
    if (mode == AccelMode.hundredTo200) {
      final bool peakOk = _peakSpeedKmh + gateEps >= target200;
      if (!_reachedGoal || !peakOk) {
        // ignore: avoid_print
        print(
            'ACCEL[drop] reason=${!_reachedGoal ? 'notReached' : 'peak<200'} distM=${_distanceM.toStringAsFixed(2)} elapsedMs=$_elapsedMs '
            'peak=${_peakSpeedKmh.toStringAsFixed(2)}');
        return; // 作廢不保存
      }
    }

    // Extend drop rule: also drop when elapsedMs < minValidMs or invalidStart
    if (!_reachedGoal || _elapsedMs < minValidMs || invalidStart) {
      final reason = !_reachedGoal
          ? 'notReached'
          : (invalidStart ? 'invalidStart' : 'tooShort');
      // ignore: avoid_print
      print(
          'ACCEL[drop] reason=$reason distM=${_distanceM.toStringAsFixed(2)} elapsedMs=$_elapsedMs start=${_startSpeed.toStringAsFixed(2)}');
      return; // 直接丟棄此次結果
    }

    // 建立記錄
    final id = _fmtId(now);
    final rec = AccelRecord(
      id: id,
      name: _defaultName(now),
      mode: mode,
      startedAt: _tStart!,
      elapsedMs: _elapsedMs,
      startSpeedKmh: _startSpeed,
      endSpeedKmh: _endSpeed,
      distanceM: _distanceM,
      samples: List.of(_samples),
      useMph: Setting.instance.useMph,
    );
    await AccelStore.append(rec);
    // ignore: avoid_print
    print(
        'ACCEL[append] saved id=$id mode=${mode.name} elapsedMs=${_elapsedMs} peak=${_peakSpeedKmh.toStringAsFixed(2)}');
    // 成功保存 → 播放提示音（限 1 秒）
    //_playDing1s();
    if (mode == AccelMode.hundredTo200) {
      // 100–200：達標後立刻回 READY，並要求先掉回 ≤99.9 才能再起跑
      _needDropBelow100 = true;
      _reset(preserveElapsed: true, keepRearm: true);
    } else {
      // 其他模式（0–60、0–100、0–400m）：
      // 停在完成態，保留成績與 Max/Goal 顯示；等「下一次起跑」時才清零。
      _running = false; // 已在前面設為 false，此處重申語意
      _holdLast = true; // 保留秒數
      // 不呼叫 _reset()，也不設 _pendingResetAfterSave
      // 讓畫面維持完成數據，直到下一次觸發起跑時，才在起跑處清零
    }
    return;
  }

  static String _fmtId(DateTime t) {
    return '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}_${Random().nextInt(9999).toString().padLeft(4, '0')}';
  }

  static String _defaultName(DateTime t) {
    // 你之前偏好：月/日 時:分
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$min';
  }
}

/// ====== UI 頁面 ======
class AccelPage extends StatefulWidget {
  final AccelMode mode;

  // Injected live notifiers from main.dart (all optional)
  final ValueListenable<double>? liveSpeedMps;
  final ValueListenable<double?>? headingDeg;
  final ValueListenable<double>? distanceMeters;
  final ValueListenable<int>? movingSeconds;
  final ValueListenable<int>? stoppedSeconds;
  final ValueListenable<bool>? isAutoPaused;
  final ValueListenable<bool>? isManuallyPaused;
  final VoidCallback? forceStartRecordingNow;

  const AccelPage({
    super.key,
    required this.mode,
    this.liveSpeedMps,
    this.headingDeg,
    this.distanceMeters,
    this.movingSeconds,
    this.stoppedSeconds,
    this.isAutoPaused,
    this.isManuallyPaused,
    this.forceStartRecordingNow,
  });

  @override
  State<AccelPage> createState() => _AccelPageState();
}

class _AccelPageState extends State<AccelPage> {
  late AccelMode _mode;
  late AccelEngine _engine;

  // If liveSpeedMps is injected, we convert it to a km/h stream for AccelEngine.
  StreamController<double>? _liveSpeedCtrl;
  VoidCallback? _detachLiveSpeed;

  // For RAW speed pipeline (when liveSpeedMps == null)
  StreamSubscription<Position>? _rawPosSub;
  Position? _lastPos;
  DateTime? _lastTs;
  final List<_RecentMove> _recentMoves = [];
  final ValueNotifier<double> _rawSpeedMps = ValueNotifier(0.0);

  StreamController<double>? _rawSpeedCtrl;
  VoidCallback? _detachRawSpeed;

  static const double _kMinDtForSpeed = 0.05;
  static const double _kStopWindowSec = 2.0;
  static const double _kStopWindowDist = 1.0;

  // Track useMph change even if Setting isn't a Listenable
  bool _lastUseMph = Setting.instance.useMph;
  Timer? _settingPoll;

  void _onPosition(Position p) {
    final now = DateTime.now();
    final dtSec = (_lastTs != null)
        ? (now.difference(_lastTs!).inMilliseconds / 1000.0)
        : 0.0;
    if (_lastTs != null && dtSec < _kMinDtForSpeed) return;

    double sp = p.speed.isFinite ? p.speed : 0.0;
    double v = sp;
    double d = 0.0;
    if (_lastPos != null && _lastTs != null && dtSec > 0) {
      d = Geolocator.distanceBetween(
          _lastPos!.latitude, _lastPos!.longitude, p.latitude, p.longitude);
      v = d / dtSec;
      _recentMoves.add(_RecentMove(now, d));
      final cutoff = now
          .subtract(Duration(milliseconds: (_kStopWindowSec * 1000).round()));
      while (
          _recentMoves.isNotEmpty && _recentMoves.first.ts.isBefore(cutoff)) {
        _recentMoves.removeAt(0);
      }
    }

    double chosen = sp.isFinite ? sp : (v.isFinite ? v : 0.0);

    double sumRecentD = 0.0;
    for (final rm in _recentMoves) {
      sumRecentD += rm.d;
    }
    if (sumRecentD < _kStopWindowDist) {
      chosen = 0.0;
    }

    _rawSpeedMps.value = chosen;
    _lastPos = p;
    _lastTs = now;
  }

  final List<AccelMode> _modes = const [
    AccelMode.zeroTo50,
    AccelMode.zeroTo60,
    AccelMode.zeroTo100,
    AccelMode.zeroTo400m,
    AccelMode.hundredTo200,
  ];

  void _switchToNextMode() {
    final i = _modes.indexOf(_mode);
    final next = _modes[(i + 1) % _modes.length];
    HapticFeedback.selectionClick();
    _switchMode(next);
  }

  void _switchToPrevMode() {
    final i = _modes.indexOf(_mode);
    final prev = _modes[(i - 1 + _modes.length) % _modes.length];
    HapticFeedback.selectionClick();
    _switchMode(prev);
  }

  // Builds the speed stream for the engine: ValueListenable<double> (m/s) -> Stream<double> (km/h)
  Stream<double> _speedStreamForEngine() {
    if (widget.liveSpeedMps == null) {
      // Use Geolocator.getPositionStream and pipe into _onPosition, output _rawSpeedMps.
      // Cancel any existing subscription first.
      _rawPosSub?.cancel();
      _lastPos = null;
      _lastTs = null;
      _recentMoves.clear();
      _rawSpeedMps.value = 0.0;
      final settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        timeLimit: null,
      );
      _rawPosSub = Geolocator.getPositionStream(locationSettings: settings)
          .listen(_onPosition);
      // Return a stream of km/h (convert ValueNotifier -> Stream)
      _rawSpeedCtrl?.close();
      _rawSpeedCtrl = StreamController<double>.broadcast();
      void pushRaw() {
        final mps = _rawSpeedMps.value;
        _rawSpeedCtrl!.add((mps.isFinite ? mps : 0.0) * 3.6);
      }

      pushRaw(); // seed current
      _rawSpeedMps.addListener(pushRaw);
      _detachRawSpeed = () {
        try {
          _rawSpeedMps.removeListener(pushRaw);
        } catch (_) {}
        _rawSpeedCtrl?.close();
        _rawSpeedCtrl = null;
      };
      return _rawSpeedCtrl!.stream;
    }
    // Convert ValueListenable<double> (m/s) -> Stream<double> (km/h).
    _liveSpeedCtrl = StreamController<double>.broadcast();
    void push() {
      final mps = widget.liveSpeedMps!.value;
      _liveSpeedCtrl!.add((mps.isFinite ? mps : 0.0) * 3.6);
    }

    // seed current value and listen to changes
    push();
    widget.liveSpeedMps!.addListener(push);
    _detachLiveSpeed = () {
      try {
        widget.liveSpeedMps!.removeListener(push);
      } catch (_) {}
      _liveSpeedCtrl?.close();
      _liveSpeedCtrl = null;
    };
    return _liveSpeedCtrl!.stream;
  }

  @override
  void initState() {
    super.initState();
    // DEBUG: verify we are seeing the same Setting singleton and unit on boot
    // Remove or guard with kDebugMode as needed.
    // ignore: avoid_print
    print(
        'ACCEL[init] Setting.instance.hashCode=${Setting.instance.hashCode} useMph=${Setting.instance.useMph}');
    // Force-load persisted unit once at cold start to avoid stale default
    Future.microtask(() async {
      try {
        final sp = await SharedPreferences.getInstance();
        final persisted = sp.getBool('useMph');
        if (persisted != null && persisted != Setting.instance.useMph) {
          // ignore: avoid_print
          print(
              'ACCEL[prefs] correcting useMph from ${Setting.instance.useMph} -> $persisted');
          Setting.instance.useMph = persisted;
          if (mounted) setState(() {});
        } else {
          // ignore: avoid_print
          print(
              'ACCEL[prefs] useMph already ${Setting.instance.useMph} (persisted=$persisted)');
        }
      } catch (e) {
        // ignore: avoid_print
        print('ACCEL[prefs] read failed: $e');
      }
    });
    _mode = widget.mode;
    // (Optionally print mode)
    print('🚀 AccelPage mode: ${widget.mode}');
    final spStream = _speedStreamForEngine(); // km/h stream
    _engine = AccelEngine(
      mode: _mode,
      speedKmhStream: spStream,
      gStream: GSource().getStream(),
      externalTotalDistanceM: widget.distanceMeters,
    )..start();
    // Force a first-frame rebuild so unit (mph/km) reflects persisted Setting
    // even if Setting finishes loading slightly after this widget is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ignore: avoid_print
      print(
          'ACCEL[postFrame] useMph(after first frame)=${Setting.instance.useMph}');
      if (mounted) setState(() {});
    });
    // Poll Setting.useMph in case Setting isn't a Listenable yet.
    _settingPoll = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final v = Setting.instance.useMph;
      if (v != _lastUseMph) {
        // ignore: avoid_print
        print('ACCEL[settingsPoll] useMph changed: $_lastUseMph -> $v');
        _lastUseMph = v;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _engine.disposeEngine();
    _detachLiveSpeed?.call();
    _rawPosSub?.cancel();
    _detachRawSpeed?.call();
    _settingPoll?.cancel();
    _settingPoll = null;
    super.dispose();
  }

  void _switchMode(AccelMode m) {
    setState(() {
      _mode = m;
      _engine.disposeEngine();
      _detachLiveSpeed?.call();
      _rawPosSub?.cancel();
      final spStream = _speedStreamForEngine();
      _engine = AccelEngine(
        mode: _mode,
        speedKmhStream: spStream,
        gStream: GSource().getStream(),
        externalTotalDistanceM: widget.distanceMeters,
      )..start();
    });
  }

  String _fmtElapsedSsMs(int ms) {
    if (ms < 0) ms = 0;
    if (ms < 60000) {
      final s = (ms ~/ 1000).toString().padLeft(2, '0');
      final ms2 = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
      return '$s.$ms2'; // ss.SS
    } else {
      final m = (ms ~/ 60000).toString();
      final rem = ms % 60000;
      final s = (rem ~/ 1000).toString().padLeft(2, '0');
      final ms2 = ((rem % 1000) ~/ 10).toString().padLeft(2, '0');
      return '$m:$s.$ms2'; // mm:ss.SS
    }
  }

  Future<void> _openMenuSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // handle bar
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.history, color: Colors.white),
                title: Text(
                  L10n.t('accel_records'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AccelRecordsPage()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.home, color: Colors.white),
                title: Text(
                  L10n.t('back_home'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final speedStyle = TextStyle(
      fontSize: 120,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.5,
      height: 1.0,
      color: Theme.of(context).colorScheme.onBackground,
    );
    final subStyle = TextStyle(
      fontSize: 16,
      color: Colors.green.shade400,
      fontWeight: FontWeight.w600,
    );
    final timeStyle = TextStyle(
      fontSize: 32,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: Theme.of(context).colorScheme.onBackground.withOpacity(0.9),
      fontWeight: FontWeight.w700,
    );
    // Bridge: Setting may not implement Listenable in some builds; guard at runtime.
    final Listenable settingListenable = (Setting.instance is Listenable)
        ? (Setting.instance as Listenable)
        : _NullListenable.instance;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([_engine, settingListenable]),
          builder: (_, __) {
            final useMph = Setting.instance.useMph;
            final double displaySpeed =
                useMph ? (_engine._lastSpeed * 0.621371) : _engine._lastSpeed;
            final speedInt = displaySpeed.floor(); // 中央速度（依單位顯示）
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (details) {
                final v = details.primaryVelocity ?? 0;
                if (v < -200) {
                  _switchToNextMode();
                } else if (v > 200) {
                  _switchToPrevMode();
                }
              },
              onTapUp: (details) {
                final size = MediaQuery.of(context).size;
                // 若點擊位置在螢幕下半部，打開選單
                if (details.globalPosition.dy > size.height / 2) {
                  _openMenuSheet();
                }
              },
              child: Stack(
                children: [
                  // 中央速度（純顯示，不再各別包 GestureDetector）
                  Align(
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_mode == AccelMode.zeroTo400m &&
                            !_engine.lastGoalSpeedKmh.isNaN)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Builder(builder: (context) {
                              final useMph = Setting.instance.useMph;
                              final unit = useMph ? 'mph' : 'km/h';
                              final v = _engine.lastGoalSpeedKmh;
                              final disp = useMph ? (v * 0.621371) : v;
                              return Text(
                                'Max: ${disp.toStringAsFixed(0)} $unit',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onBackground
                                      .withOpacity(0.8),
                                  fontWeight: FontWeight.w700,
                                ),
                              );
                            }),
                          ),
                        if (_engine.isReady)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(L10n.t('ready'), style: subStyle),
                          ),
                        // --- Inserted: Show distance for 0–400m mode while running ---
                        if (_mode == AccelMode.zeroTo400m && _engine.isRunning)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '${_engine.distanceM.toStringAsFixed(1)} m',
                              style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onBackground
                                    .withOpacity(0.8),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        Text('$speedInt', style: speedStyle),
                        // const SizedBox(height: 6),
                        // _GBar(g: _engine.currentG),
                        // const SizedBox(height: 10),
                        Text(_mode.title,
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onBackground
                                  .withOpacity(0.6),
                            )),
                        const SizedBox(height: 10),
                        _ModePagerDots(
                            count: _modes.length, index: _modes.indexOf(_mode)),
                        const SizedBox(height: 48),
                        _GBall(reading: _engine.currentG),
                      ],
                    ),
                  ),

                  // 右下角功能選單
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _MenuButton(
                      onSelectRecords: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AccelRecordsPage()),
                        );
                      },
                      onBackHome: () => Navigator.of(context).pop(),
                    ),
                  ),

                  // 下方時間 ss:ms
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Center(
                      child: Text(
                        _fmtElapsedSsMs(_engine.elapsedMs),
                        style: timeStyle,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NullListenable implements Listenable {
  const _NullListenable._();
  static const _NullListenable instance = _NullListenable._();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _ModeChips extends StatelessWidget {
  final AccelMode current;
  final ValueChanged<AccelMode> onChanged;
  const _ModeChips({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final modes = const [
      AccelMode.zeroTo50,
      AccelMode.zeroTo60,
      AccelMode.zeroTo100,
      AccelMode.zeroTo400m,
      AccelMode.hundredTo200,
    ];
    return Wrap(
      spacing: 8,
      children: modes.map((m) {
        final sel = m == current;
        return ChoiceChip(
          label: Text(m.title),
          selected: sel,
          onSelected: (_) => onChanged(m),
        );
      }).toList(),
    );
  }
}

class _ModePagerDots extends StatelessWidget {
  final int count;
  final int index;
  const _ModePagerDots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 10 : 6,
          height: active ? 10 : 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context)
                .colorScheme
                .onBackground
                .withOpacity(active ? 0.9 : 0.35),
          ),
        );
      }),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final VoidCallback onSelectRecords;
  final VoidCallback onBackHome;
  const _MenuButton({required this.onSelectRecords, required this.onBackHome});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.menu),
      onPressed: () async {
        // 由外層頁面（_AccelPageState）也能呼叫同一套選單
        // 這裡簡化：轉呼叫外層的 bottom sheet
        // 因為這個 widget 無法直接存取 _openMenuSheet()，
        // 改由把原本行為委派回父層透過 Navigator 取得 context。
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: const Color(0xFF111111),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (ctx) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.history, color: Colors.white),
                    title: Text(
                      L10n.t('accel_records'),
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onSelectRecords();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.home, color: Colors.white),
                    title: Text(
                      L10n.t('back_home'),
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onBackHome();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// 保留 _GBar 以備不時之需
class _GBar extends StatelessWidget {
  final double g; // 目前 g 值（|a|）
  const _GBar({required this.g});

  @override
  Widget build(BuildContext context) {
    // 垂直條：0g ~ 1.5g 映射到填充高度
    final clampG = g.clamp(0.0, 1.5);
    final barH = 80.0;
    final fillH = barH * (clampG / 1.5);
    final onBg = Theme.of(context).colorScheme.onBackground;
    return Column(
      children: [
        SizedBox(
          height: barH,
          width: 18,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: onBg.withOpacity(0.35), width: 1),
                  color: onBg.withOpacity(0.08),
                ),
              ),
              Container(
                height: fillH,
                decoration: BoxDecoration(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(6)),
                  color: Colors.greenAccent.withOpacity(0.9),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'G: ${g.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: 14,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: onBg.withOpacity(0.8),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _GBall extends StatelessWidget {
  final GReading reading;
  const _GBall({required this.reading});

  @override
  Widget build(BuildContext context) {
    // 畫布大小與比例設定
    const size = 160.0; // 直徑
    const maxG = 1.5; // 外圈標示 1.5g
    final onBg = Theme.of(context).colorScheme.onBackground.withOpacity(0.6);

    // 位置：把 gx, gy 映射到 [-1,1] 再乘以半徑
    final r = size / 2 - 8; // 內縮 8 避免貼邊
    final x = (reading.gx / maxG).clamp(-1.0, 1.0) * r;
    final y = (reading.gy / maxG).clamp(-1.0, 1.0) * r;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 底層：圓環 + 十字線 + 刻度 1G
          CustomPaint(
            size: const Size(size, size),
            painter: _GBallGridPainter(color: onBg),
          ),
          // 中心黃點隨加速度移動
          Transform.translate(
            offset: Offset(x, -y), // 直覺：上正 -> 畫面 Y 要取反
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Colors.amber,
                shape: BoxShape.circle,
              ),
            ),
          ),
          // 跟隨黃點右下角顯示 G 值
          Builder(builder: (context) {
            final onBg =
                Theme.of(context).colorScheme.onBackground.withOpacity(0.8);
            // 文字相對點的位移（像素）
            const dx = 14.0;
            const dy = 14.0;
            // 以 r 為可視邊界（和黃點一樣扣 8px 邊距），避免文字超出畫布
            final limit = r;
            double tx = x + dx;
            double ty = -y + dy; // 螢幕座標向下為正
            tx = tx.clamp(-limit, limit);
            ty = ty.clamp(-limit, limit);
            return Transform.translate(
              offset: Offset(tx, ty),
              child: Text(
                'G: ${reading.g.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 14,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: onBg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _GBallGridPainter extends CustomPainter {
  final Color color;
  _GBallGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;

    final center = Offset(size.width / 2, size.height / 2);
    final rOuter = min(size.width, size.height) / 2 - 4;
    final rInner = rOuter * 0.6;

    // 圓環
    canvas.drawCircle(center, rOuter, paint);
    canvas.drawCircle(center, rInner, paint);

    // 十字線
    canvas.drawLine(Offset(center.dx - rOuter, center.dy),
        Offset(center.dx + rOuter, center.dy), paint);
    canvas.drawLine(Offset(center.dx, center.dy - rOuter),
        Offset(center.dx, center.dy + rOuter), paint);

    // 1G 文字（上下左右）
    final textPainter = (String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: color, fontSize: 12)),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    };
    final t = textPainter('1G');
    t.paint(canvas,
        Offset(center.dx - t.width / 2, center.dy - rOuter - 2 - t.height));
    t.paint(canvas, Offset(center.dx - t.width / 2, center.dy + rOuter + 2));
    t.paint(canvas,
        Offset(center.dx - rOuter - t.width - 2, center.dy - t.height / 2));
    t.paint(canvas, Offset(center.dx + rOuter + 2, center.dy - t.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
