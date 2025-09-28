import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'dart:ui' as ui; // for drawing bitmap icons in AppleMap annotations
import 'dart:async';
import 'package:geocoding/geocoding.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:path_provider/path_provider.dart';
import 'dart:math' as math;
import 'trip.dart';
import 'total.dart';
import 'package:gps_speedometer_min/setting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'dart:io' show Platform;
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as am; // iOS only
import 'package:share_plus/share_plus.dart';

// === Local dir helpers (avoid using private members of TripStore in trip.dart) ===
Future<Directory> _tdRootDir() async {
  final base = await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/trips');
  if (!await d.exists()) {
    await d.create(recursive: true);
  }
  return d;
}

Future<Directory> _tdLegacyRootDir() async {
  return getApplicationDocumentsDirectory();
}

Future<void> _tdWriteIndex(List<TripSummary> items) async {
  final dir = await _tdRootDir();
  final f = File('${dir.path}/index.json');
  final data = items.map((e) => e.toJson()).toList();
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

/// ===== 詳情頁使用的完整資料模型 =====
class TripFull {
  final String id;
  String name;
  final DateTime start;
  final DateTime end;
  final double distanceMeters;
  final int movingSeconds;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final double? weatherTempC;
  final DateTime? weatherAt;
  final double? weatherLat;
  final double? weatherLon;
  final List<DateTime> ts;
  final List<double> lat;
  final List<double> lon;
  final List<double?> alt;
  final List<double> speedMps;
  final String? preferredUnit;

  TripFull({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    required this.distanceMeters,
    required this.movingSeconds,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.weatherTempC,
    required this.weatherAt,
    required this.weatherLat,
    required this.weatherLon,
    required this.ts,
    required this.lat,
    required this.lon,
    required this.alt,
    required this.speedMps,
    required this.preferredUnit,
  });

  bool get useMiles => preferredUnit == 'mi';
}

extension on Duration {
  String fmtHms() {
    final h = inHours;
    final m = inMinutes % 60;
    final s = inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// ====== TripStore helpers for detail page ======
extension TripStoreDetail on TripStore {
  List<List<dynamic>> _parseSamplesRaw(Map<String, dynamic> m) {
    final raw = <List<dynamic>>[];
    final samples = (m['samples'] as List?) ?? const [];
    for (final s in samples) {
      if (s is Map) {
        final t = DateTime.tryParse(s['ts']?.toString() ?? '');
        final la = (s['lat'] as num?)?.toDouble();
        final lo = (s['lon'] as num?)?.toDouble();
        final al = (s['alt'] as num?)?.toDouble();
        final v = (s['speedMps'] as num?)?.toDouble() ?? 0.0;
        if (t != null && la != null && lo != null) {
          raw.add([t, la, lo, al, v]);
        }
      }
    }
    return raw;
  }

  Future<TripFull?> loadTripFull(String id) async {
    // 1) 優先讀 trips/{id}.json
    final tripsDir = await _tdRootDir();
    File f = File('${tripsDir.path}/$id.json');
    if (!await f.exists()) {
      // 2) 嘗試 legacy: trip_*.json at root
      final legacy = await _tdLegacyRootDir();
      final guess = File('${legacy.path}/$id.json');
      if (await guess.exists()) {
        f = guess;
      } else {
        // 再試：已包含前綴 'trip_' 的 id 或缺前綴
        final alt1 = File('${legacy.path}/trip_$id.json');
        if (await alt1.exists())
          f = alt1;
        else
          return null;
      }
    }
    try {
      final txt = await f.readAsString();
      final m = jsonDecode(txt) as Map<String, dynamic>;
      String name = (m['name'] as String?)?.trim() ?? '';
      final start =
          DateTime.tryParse(m['startAt']?.toString() ?? '') ?? DateTime.now();
      final end = DateTime.tryParse(m['endAt']?.toString() ?? '') ?? start;
      final distance = (m['distanceMeters'] as num?)?.toDouble() ?? 0.0;
      final movingSec = (m['movingSeconds'] as num?)?.toInt() ?? 0;
      final maxSp = (m['maxSpeedMps'] as num?)?.toDouble() ?? 0.0;
      final avgSp = (m['avgSpeedMps'] as num?)?.toDouble() ?? 0.0;
      final wTemp = (m['weatherTempC'] as num?)?.toDouble();
      final wAt = DateTime.tryParse(m['weatherAt']?.toString() ?? '');
      final wLat = (m['weatherLat'] as num?)?.toDouble();
      final wLon = (m['weatherLon'] as num?)?.toDouble();

      final unitSaved =
          (m['preferredUnit'] as String?) ?? (m['unit'] as String?);

      // First, parse samples from the primary file (may be minimal stub without samples)
      List<DateTime> ts = [];
      List<double> lat = [];
      List<double> lon = [];
      List<double?> alt = [];
      List<double> sp = [];

      List<List<dynamic>> raw = _parseSamplesRaw(m);

      // If the primary file has no samples (some migrated files contain only points/bounds),
      // try to open the legacy root JSON (trip_*.json) and parse samples from there.
      if (raw.isEmpty) {
        try {
          final legacyDir = await _tdLegacyRootDir();
          // Prefer exact id.json; also try with/without the 'trip_' prefix.
          final candidates = <File>[
            File('${legacyDir.path}/$id.json'),
            if (!id.startsWith('trip_'))
              File('${legacyDir.path}/trip_$id.json'),
          ];
          for (final cand in candidates) {
            if (await cand.exists()) {
              final lm =
                  jsonDecode(await cand.readAsString()) as Map<String, dynamic>;
              raw = _parseSamplesRaw(lm);
              if (raw.isNotEmpty) break;
            }
          }
        } catch (_) {}
      }

      // Parse normalized arrays if present and raw is still empty
      if (raw.isEmpty) {
        final hasArr = m['ts'] is List &&
            m['lat'] is List &&
            m['lon'] is List &&
            m['speedMps'] is List;
        if (hasArr) {
          try {
            final List<dynamic> tsArr = (m['ts'] as List);
            final List<dynamic> latArr = (m['lat'] as List);
            final List<dynamic> lonArr = (m['lon'] as List);
            final List<dynamic> spArr = (m['speedMps'] as List);
            final List<dynamic>? altArr = (m['alt'] as List?);
            for (int i = 0; i < tsArr.length; i++) {
              final t = DateTime.tryParse(tsArr[i].toString());
              final la =
                  (i < latArr.length) ? (latArr[i] as num?)?.toDouble() : null;
              final lo =
                  (i < lonArr.length) ? (lonArr[i] as num?)?.toDouble() : null;
              final al = (altArr != null && i < altArr.length)
                  ? (altArr[i] as num?)?.toDouble()
                  : null;
              final v = (i < spArr.length)
                  ? (spArr[i] as num?)?.toDouble() ?? 0.0
                  : 0.0;
              if (t != null && la != null && lo != null) {
                raw.add([t, la, lo, al, v]);
              }
            }
          } catch (_) {}
        }
      }

      for (final r in raw) {
        ts.add(r[0] as DateTime);
        lat.add(r[1] as double);
        lon.add(r[2] as double);
        alt.add(r[3] as double?);
        sp.add(r[4] as double);
      }
      return TripFull(
        id: id,
        name: name,
        start: start,
        end: end,
        distanceMeters: distance,
        movingSeconds: movingSec,
        maxSpeedMps: maxSp,
        avgSpeedMps: avgSp,
        weatherTempC: wTemp,
        weatherAt: wAt,
        weatherLat: wLat,
        weatherLon: wLon,
        ts: ts,
        lat: lat,
        lon: lon,
        alt: alt,
        speedMps: sp,
        preferredUnit: unitSaved,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> renameTrip(String id, String newName) async {
    bool ok = false;
    try {
      // update trips/{id}.json if exists
      final tripsDir = await _tdRootDir();
      final f1 = File('${tripsDir.path}/$id.json');
      if (await f1.exists()) {
        final m = jsonDecode(await f1.readAsString()) as Map<String, dynamic>;
        m['name'] = newName;
        await f1.writeAsString(jsonEncode(m));
        ok = true;
      }
      // update legacy if exists
      final legacy = await _tdLegacyRootDir();
      final f2a = File('${legacy.path}/$id.json');
      final f2b = File('${legacy.path}/trip_$id.json');
      final f2 = await f2a.exists() ? f2a : (await f2b.exists() ? f2b : null);
      if (f2 != null) {
        final m = jsonDecode(await f2.readAsString()) as Map<String, dynamic>;
        m['name'] = newName;
        await f2.writeAsString(jsonEncode(m));
        ok = true;
      }
      // update index.json entry (best effort)
      try {
        final list = await TripStore.instance.loadSummaries();
        final i = list.indexWhere((e) => e.id == id);
        if (i != -1) {
          final s = list[i];
          list[i] = TripSummary(
            id: s.id,
            name: newName,
            startTime: s.startTime,
            endTime: s.endTime,
            totalDistanceMeters: s.totalDistanceMeters,
            movingTime: s.movingTime,
            previewPath: s.previewPath,
            geoPoints: s.geoPoints,
            geoBounds: s.geoBounds,
          );
          await _tdWriteIndex(list);
        }
      } catch (_) {}
    } catch (_) {}
    return ok;
  }
}

/// 旅程詳情頁（含播放、倍速、統計、曲線圖）
class TripDetailPage extends StatefulWidget {
  final TripSummary summary;
  const TripDetailPage({super.key, required this.summary});
  @override
  State<TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<TripDetailPage> {
  TripFull? data;
  bool loading = true;

  // 播放控制
  bool playing = false;
  double speed = 1.0; // 倍速
  int idx = 0; // 目前索引（samples）
  Timer? _tick;
  String? _startAddr;
  String? _endAddr;
  bool _scrubbing = false; // 使用者拖動進度條中，暫停自動追蹤

  // 播放起點（用時間軸對齊 1x/2x 等速）
  DateTime? _playStartWall; // 牆鐘時間（開始播放當下）
  DateTime? _playStartTs; // 對應資料的時間戳
  int _playStartIdx = 0; // 當下索引
  DateTime? _lastDisplayTime; // 最近一次用於顯示的時間（播放中會持續更新；暫停時維持）

  // 總爬升（公尺）：連續樣本的「正向高度差」總和（含雜訊門檻與跳點過濾）
  double _elevationGainMeters(List<double?> alt) {
    const double noiseFloor = 0.2; // <0.2m 視為雜訊
    const double jumpCap = 100.0; // >100m/筆 視為異常

    double total = 0.0;
    double? prev;
    double minV = double.infinity;
    double maxV = -double.infinity;

    for (final v in alt) {
      if (v == null) continue;
      // 記錄 min/max 供後備
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;

      if (prev != null) {
        final delta = v - prev!;
        if (delta > noiseFloor && delta < jumpCap) {
          total += delta;
        }
      }
      prev = v;
    }

    // 後備：若樣本太少或雜訊判定導致 total 幾近 0，但整體落差明顯，採用 max-min 作為估計
    if (total < 0.5 && maxV > minV && (maxV - minV) > 0.5) {
      return maxV - minV;
    }
    return total;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Haversine distance in meters
  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius (m)
    double dLat = (lat2 - lat1) * 3.141592653589793 / 180.0;
    double dLon = (lon2 - lon1) * 3.141592653589793 / 180.0;
    double a = (MathSin(dLat / 2) * MathSin(dLat / 2)) +
        MathCos(lat1 * 3.141592653589793 / 180.0) *
            MathCos(lat2 * 3.141592653589793 / 180.0) *
            (MathSin(dLon / 2) * MathSin(dLon / 2));
    double c = 2 * MathAtan2(MathSqrt(a), MathSqrt(1 - a));
    return R * c;
  }

  /// 通用地址格式：路名＋門牌, 行政區（全球適用的最大公約數）
  String _fmtGlobalPlacemark(Placemark p) {
    // 路名（thoroughfare / street / name）
    final thoroughfare = (p.thoroughfare ?? '').trim();
    final subThoroughfare = (p.subThoroughfare ?? '').trim(); // 門牌號
    final street = (p.street ?? '').trim(); // 有些來源會已經包含「路名+號」

    String streetPart;
    if (thoroughfare.isNotEmpty && subThoroughfare.isNotEmpty) {
      streetPart = '$thoroughfare $subThoroughfare';
    } else if (street.isNotEmpty) {
      streetPart = street;
    } else if ((thoroughfare + subThoroughfare).trim().isNotEmpty) {
      streetPart = (thoroughfare +
              (subThoroughfare.isNotEmpty ? ' $subThoroughfare' : ''))
          .trim();
    } else {
      streetPart = (p.name ?? '').trim();
    }

    // 行政區：prefer subLocality (區/鄉/鎮/區域) > locality (城市/鄉鎮) > subAdministrativeArea (縣/區)
    String area = (p.subLocality ?? '').trim();
    if (area.isEmpty) area = (p.locality ?? '').trim();
    if (area.isEmpty) area = (p.subAdministrativeArea ?? '').trim();
    if (area.isEmpty) area = (p.administrativeArea ?? '').trim();

    if (streetPart.isEmpty && area.isEmpty) return '';
    if (streetPart.isEmpty) return area;
    if (area.isEmpty) return streetPart;
    return '$streetPart, $area';
  }

  Future<void> _loadAddresses(TripFull d) async {
    if (d.lat.isEmpty || d.lon.isEmpty) return;
    try {
      final sPl = await placemarkFromCoordinates(d.lat.first, d.lon.first);
      final ePl = await placemarkFromCoordinates(d.lat.last, d.lon.last);
      final s = sPl.isNotEmpty ? _fmtGlobalPlacemark(sPl.first) : '';
      final e = ePl.isNotEmpty ? _fmtGlobalPlacemark(ePl.first) : '';
      if (!mounted) return;
      setState(() {
        _startAddr = s.isNotEmpty
            ? s
            : '${d.lat.first.toStringAsFixed(5)}, ${d.lon.first.toStringAsFixed(5)}';
        _endAddr = e.isNotEmpty
            ? e
            : '${d.lat.last.toStringAsFixed(5)}, ${d.lon.last.toStringAsFixed(5)}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _startAddr =
            '${d.lat.first.toStringAsFixed(5)}, ${d.lon.first.toStringAsFixed(5)}';
        _endAddr =
            '${d.lat.last.toStringAsFixed(5)}, ${d.lon.last.toStringAsFixed(5)}';
      });
    }
  }

  // Lightweight math wrappers to avoid importing dart:math at top of file
  double MathSin(double v) => math.sin(v);
  double MathCos(double v) => math.cos(v);
  double MathAtan2(double y, double x) => math.atan2(y, x);
  double MathSqrt(double v) => math.sqrt(v);

  // 取得「播放顯示用」時間戳：播放中用牆鐘推進（並更新快取）；非播放/拖曳時優先回傳快取
  DateTime _playDisplayTime(TripFull d) {
    // 播放中（且非拖曳）：用牆鐘推進，並更新快取
    if (playing &&
        !_scrubbing &&
        _playStartWall != null &&
        _playStartTs != null) {
      final elapsedSec =
          DateTime.now().difference(_playStartWall!).inMilliseconds / 1000.0;
      DateTime t = _playStartTs!.add(
        Duration(milliseconds: (elapsedSec * 1000 * speed).round()),
      );
      final DateTime last = d.ts.isNotEmpty ? d.ts.last : d.end;
      if (t.isAfter(last)) t = last;
      _lastDisplayTime = t; // 更新快取（給暫停時使用）
      return t;
    }
    // 拖曳中：跟著目前樣本點走，並更新快取
    if (_scrubbing && idx >= 0 && idx < d.ts.length) {
      _lastDisplayTime = d.ts[idx];
      return _lastDisplayTime!;
    }
    // 非播放：優先使用快取，若無則回退到樣本或行程開始
    if (_lastDisplayTime != null) return _lastDisplayTime!;
    if (idx >= 0 && idx < d.ts.length) return d.ts[idx];
    return d.start;
  }

  Future<void> _load() async {
    final loaded = await TripStore.instance.loadTripFull(widget.summary.id);

    TripFull merged;
    if (loaded == null) {
      final pts = widget.summary.geoPoints ?? const [];
      merged = TripFull(
        id: widget.summary.id,
        name: widget.summary.name,
        start: widget.summary.startTime,
        end: widget.summary.endTime,
        distanceMeters: widget.summary.totalDistanceMeters,
        movingSeconds: widget.summary.movingTime.inSeconds,
        maxSpeedMps: 0,
        avgSpeedMps: 0,
        weatherTempC: null,
        weatherAt: null,
        weatherLat: null,
        weatherLon: null,
        ts: const [],
        lat: pts.map((e) => e.latitude).toList(),
        lon: pts.map((e) => e.longitude).toList(),
        alt: List<double?>.filled(pts.length, null, growable: false),
        speedMps: const [],
        preferredUnit: null,
      );
    } else {
      final hasBasic = loaded.distanceMeters > 0 || loaded.movingSeconds > 0;
      final pts = (loaded.lat.isEmpty && (widget.summary.geoPoints != null))
          ? widget.summary.geoPoints!
          : null;

      merged = TripFull(
        id: loaded.id,
        name: (loaded.name.isNotEmpty ? loaded.name : widget.summary.name),
        start: loaded.start != loaded.end
            ? loaded.start
            : widget.summary.startTime,
        end: loaded.start != loaded.end ? loaded.end : widget.summary.endTime,
        distanceMeters: hasBasic
            ? loaded.distanceMeters
            : widget.summary.totalDistanceMeters,
        movingSeconds: hasBasic
            ? loaded.movingSeconds
            : widget.summary.movingTime.inSeconds,
        maxSpeedMps: loaded.maxSpeedMps,
        avgSpeedMps: loaded.avgSpeedMps,
        weatherTempC: loaded.weatherTempC,
        weatherAt: loaded.weatherAt,
        weatherLat: loaded.weatherLat,
        weatherLon: loaded.weatherLon,
        ts: loaded.ts,
        lat: loaded.lat.isNotEmpty
            ? loaded.lat
            : (pts?.map((e) => e.latitude).toList() ?? const []),
        lon: loaded.lon.isNotEmpty
            ? loaded.lon
            : (pts?.map((e) => e.longitude).toList() ?? const []),
        alt: loaded.alt.isNotEmpty
            ? loaded.alt
            : (pts != null
                ? List<double?>.filled(pts.length, null, growable: false)
                : const []),
        speedMps: loaded.speedMps,
        preferredUnit: loaded.preferredUnit,
      );
    }

    // --- 若沒有 samples，依 geoPoints 與時間生成近似的 ts/speed 曲線 ---
    if (merged.ts.isEmpty && merged.lat.length >= 2 && merged.lon.length >= 2) {
      final n = merged.lat.length;
      final totalSec = (merged.movingSeconds > 0)
          ? merged.movingSeconds
          : merged.end.difference(merged.start).inSeconds.clamp(1, 1 << 31);
      final segSec = (totalSec / (n - 1)).clamp(1, 3600).toDouble();

      final List<DateTime> ts = List.generate(
          n, (i) => merged.start.add(Duration(seconds: (i * segSec).round())));
      final List<double> speeds = List<double>.filled(n, 0.0);

      for (int i = 1; i < n; i++) {
        final d = _haversineMeters(
            merged.lat[i - 1], merged.lon[i - 1], merged.lat[i], merged.lon[i]);
        final v = d / segSec; // m/s
        speeds[i] = v;
      }

      // 平滑一下速度（移動平均）
      for (int i = 1; i < n - 1; i++) {
        speeds[i] = (speeds[i - 1] + speeds[i] + speeds[i + 1]) / 3.0;
      }

      final avg = speeds.reduce((a, b) => a + b) / speeds.length;
      final maxv = speeds.reduce((a, b) => a > b ? a : b);

      merged = TripFull(
        id: merged.id,
        name: merged.name,
        start: merged.start,
        end: merged.end,
        distanceMeters: merged.distanceMeters,
        movingSeconds: merged.movingSeconds,
        maxSpeedMps: merged.maxSpeedMps > 0 ? merged.maxSpeedMps : maxv,
        avgSpeedMps: merged.avgSpeedMps > 0 ? merged.avgSpeedMps : avg,
        weatherTempC: merged.weatherTempC,
        weatherAt: merged.weatherAt,
        weatherLat: merged.weatherLat,
        weatherLon: merged.weatherLon,
        ts: ts,
        lat: merged.lat,
        lon: merged.lon,
        alt: merged.alt,
        speedMps: speeds,
        preferredUnit: merged.preferredUnit,
      );
    }

    if (!mounted) return;
    setState(() {
      data = merged;
      loading = false;
      idx = 0;
    });
    _loadAddresses(merged);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _exportTrip() async {
    final d = data;
    if (d == null) return;
    try {
      // 先嘗試直接分享原始檔（若存在）
      final tripsDir = await _tdRootDir();
      final legacyDir = await _tdLegacyRootDir();
      final candidates = <File>[
        File('${tripsDir.path}/${d.id}.json'),
        File('${legacyDir.path}/${d.id}.json'),
        if (!d.id.startsWith('trip_'))
          File('${legacyDir.path}/trip_${d.id}.json'),
      ];
      File? src;
      for (final f in candidates) {
        if (await f.exists()) {
          src = f;
          break;
        }
      }
      if (src != null) {
        await Share.shareXFiles([XFile(src.path)]);
        return;
      }

      // 若找不到原始檔，臨時輸出一份 JSON
      final tmp = await getTemporaryDirectory();
      final out = File('${tmp.path}/trip_${d.id}.json');
      final samples = <Map<String, dynamic>>[];
      final n = [
        d.ts.length,
        d.lat.length,
        d.lon.length,
        d.alt.length,
        d.speedMps.length
      ].reduce((a, b) => a < b ? a : b);
      for (int i = 0; i < n; i++) {
        samples.add({
          'ts': d.ts[i].toIso8601String(),
          'lat': d.lat[i],
          'lon': d.lon[i],
          'alt': d.alt[i],
          'speedMps': d.speedMps[i],
        });
      }
      final m = {
        'id': d.id,
        'name': d.name,
        'startAt': d.start.toIso8601String(),
        'endAt': d.end.toIso8601String(),
        'distanceMeters': d.distanceMeters,
        'movingSeconds': d.movingSeconds,
        'maxSpeedMps': d.maxSpeedMps,
        'avgSpeedMps': d.avgSpeedMps,
        'preferredUnit': d.preferredUnit,
        'samples': samples,
      };
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert(m));
      await Share.shareXFiles([XFile(out.path)]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(L10n.t('export_failed', params: {'error': e.toString()}))),
      );
    }
  }

  void _togglePlay() {
    if (data == null || data!.ts.isEmpty) return;
    final d = data!;
    final lastIdx = d.ts.length - 1;

    // 若目前已在結尾並且要從暫停切到播放，視為「重新播放」
    final bool restarting = (!playing && idx >= lastIdx);

    setState(() {
      if (restarting) {
        idx = 0; // 從頭開始
        _lastDisplayTime = null; // 清除上次的錨點，避免又鎖在結尾
      }
      playing = !playing;
    });

    // 若是從播放切到暫停，先把當前播放對應的「顯示時間」凍結下來
    if (!playing && _playStartWall != null && _playStartTs != null) {
      final elapsedSec =
          DateTime.now().difference(_playStartWall!).inMilliseconds / 1000.0;
      DateTime t = _playStartTs!.add(
        Duration(milliseconds: (elapsedSec * 1000 * speed).round()),
      );
      final d = data!;
      final DateTime last = d.ts.isNotEmpty ? d.ts.last : d.end;
      if (t.isAfter(last)) t = last;
      _lastDisplayTime = t;
    }

    _tick?.cancel();
    if (playing) {
      final d = data!;
      // 以「目前顯示的時間」為播放起點（若無快取則退回當前樣本時間或行程開始時間）
      final DateTime anchorDisplay = _lastDisplayTime ??
          ((idx >= 0 && idx < d.ts.length) ? d.ts[idx] : d.start);

      _playStartWall = DateTime.now();
      _playStartTs = anchorDisplay;

      // 找到 anchorDisplay 對應的索引（<= anchor 的最大索引）
      int lo = 0, hi = d.ts.length - 1, pos = 0;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final t = d.ts[mid];
        if (!t.isAfter(anchorDisplay)) {
          pos = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      _playStartIdx = pos;

      // 立即把當前畫面對齊到該索引，避免按下播放時出現「跳回去」
      setState(() {
        idx = pos;
        _lastDisplayTime = anchorDisplay; // 顯示從這刻開始連續前進
      });

      // 以較高頻率（60Hz/16ms）檢查，按時間找對應索引
      _tick = Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!mounted || !playing || _scrubbing) return;
        final d = data!;
        final wallElapsed =
            DateTime.now().difference(_playStartWall!).inMilliseconds / 1000.0;
        final targetTs = _playStartTs!
            .add(Duration(milliseconds: (wallElapsed * 1000 * speed).round()));

        // 二分搜尋找到 targetTs 所在的索引
        int lo = _playStartIdx, hi = d.ts.length - 1, pos = lo;
        while (lo <= hi) {
          final mid = (lo + hi) >> 1;
          final t = d.ts[mid];
          if (t.isBefore(targetTs)) {
            pos = mid;
            lo = mid + 1;
          } else {
            hi = mid - 1;
          }
        }

        setState(() {
          idx = pos;
          if (idx >= d.ts.length - 1) {
            idx = d.ts.length - 1;
            playing = false;
            _tick?.cancel();
          }
        });
      });
    }
  }

  String _fmtSpeed(double mps, {required bool useMiles}) {
    final factor = useMiles ? 2.23694 : 3.6;
    final unit = useMiles ? 'mph' : 'km/h';
    return '${(mps * factor).toStringAsFixed(0)} $unit';
  }

  String _fmtTimeWithSeconds(DateTime dt, BuildContext context) {
    String two(int v) => v.toString().padLeft(2, '0');
    final use24h = MediaQuery.of(context).alwaysUse24HourFormat;
    if (use24h) {
      return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
    } else {
      final isPM = dt.hour >= 12;
      int h = dt.hour % 12;
      if (h == 0) h = 12;
      final suffix = isPM ? 'PM' : 'AM';
      return '$h:${two(dt.minute)}:${two(dt.second)} $suffix';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final d = data;
    if (d == null) {
      return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Center(child: Text(L10n.t('trip_load_failed'))));
    }

    final total = d.end.difference(d.start);
    final moving = Duration(seconds: d.movingSeconds);
    final stopped = total - moving;

    // 單位相關
    final speedFactor = d.useMiles ? 2.23694 : 3.6;
    final speedUnit = d.useMiles ? 'mph' : 'km/h';
    final distValue =
        d.useMiles ? (d.distanceMeters / 1609.34) : (d.distanceMeters / 1000.0);
    final distUnit = d.useMiles ? 'mi' : 'km';

    // 目前點資訊
    final curSp = (idx >= 0 && idx < d.speedMps.length) ? d.speedMps[idx] : 0.0;
    final curAlt = (idx >= 0 && idx < d.alt.length) ? (d.alt[idx] ?? 0.0) : 0.0;
    final curTime = _playDisplayTime(d);
    final hasAltitude = d.alt.any((e) => e != null);
    final double elevGainMeters =
        hasAltitude ? _elevationGainMeters(d.alt) : 0.0;
    final bool useFeet = d.useMiles; // 英里制時以英尺顯示
    final double elevValue =
        useFeet ? (elevGainMeters * 3.28084) : elevGainMeters;
    final String elevUnit = useFeet ? 'ft' : 'm';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(d.name.isEmpty ? L10n.t('trip_detail_title') : d.name),
        actions: [
          IconButton(
            tooltip: L10n.t('export_share'),
            icon: const Icon(Icons.ios_share),
            onPressed: _exportTrip,
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final controller = TextEditingController(text: d.name);
              final newName = await showDialog<String?>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(L10n.t('edit_title')),
                  content: TextField(controller: controller, autofocus: true),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, null),
                        child: Text(L10n.t('cancel'))),
                    TextButton(
                        onPressed: () =>
                            Navigator.pop(ctx, controller.text.trim()),
                        child: Text(L10n.t('save'))),
                  ],
                ),
              );
              if (newName != null && newName.isNotEmpty && newName != d.name) {
                final ok = await TripStore.instance.renameTrip(d.id, newName);
                if (!mounted) return;
                if (ok)
                  setState(() {
                    d.name = newName;
                  });
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(ok
                        ? L10n.t('title_updated')
                        : L10n.t('update_failed'))));
              }
            },
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          // 地圖縮圖（互動式地圖）— 放大顯示（依螢幕寬度自適應高度）
          Builder(
            builder: (context) {
              final w = MediaQuery.of(context).size.width;
              // 以寬度的 0.62 當作高度基準；限制在 260–420 之間，手機上更容易看清楚
              final double mapHeight = (w * 0.68).clamp(420.0, 460.0);
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: mapHeight,
                  child: InteractiveTripMap(
                    points: d.lat.isNotEmpty
                        ? [
                            for (int i = 0;
                                i < d.lat.length && i < d.lon.length;
                                i++)
                              ll.LatLng(d.lat[i], d.lon[i])
                          ]
                        : (widget.summary.geoPoints ?? const <ll.LatLng>[]),
                    currentIndex: idx,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),

          // 播放控制
          Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill),
                color: Theme.of(context).colorScheme.onSurface,
                iconSize: 34,
              ),
              PopupMenuButton<double>(
                initialValue: speed,
                onSelected: (v) {
                  final d = data;
                  // If currently playing, capture the current absolute time under the OLD speed
                  if (playing && d != null && d.ts.isNotEmpty) {
                    final anchor = _playDisplayTime(d); // time where we are now
                    setState(() {
                      // Apply new speed
                      speed = v;
                      // Re-anchor playback so it continues from the same absolute time
                      _playStartWall = DateTime.now();
                      _playStartTs = anchor;
                      // find index at/just before anchor
                      int lo = 0, hi = d.ts.length - 1, pos = 0;
                      while (lo <= hi) {
                        final mid = (lo + hi) >> 1;
                        final t = d.ts[mid];
                        if (!t.isAfter(anchor)) {
                          pos = mid;
                          lo = mid + 1;
                        } else {
                          hi = mid - 1;
                        }
                      }
                      _playStartIdx = pos;
                      idx = pos;
                      _lastDisplayTime = anchor; // keep UI synced
                    });
                  } else {
                    // Paused (or no data): just change speed without moving the cursor
                    setState(() {
                      speed = v;
                    });
                  }
                },
                color: Theme.of(context).colorScheme.surface,
                itemBuilder: (ctx) => [
                  PopupMenuItem(value: 0.5, child: Text('0.5x')),
                  PopupMenuItem(value: 1.0, child: Text('1x')),
                  PopupMenuItem(value: 2.0, child: Text('2x')),
                  PopupMenuItem(value: 5.0, child: Text('5x')), // 原本的4x改成5x
                  PopupMenuItem(value: 10.0, child: Text('10x')),
                  PopupMenuItem(value: 20.0, child: Text('20x')), // 新增20x
                ],
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Text('${speed.toStringAsFixed(speed == 1 ? 0 : 1)}x',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Slider(
                value: d.ts.isEmpty
                    ? 0
                    : (idx.clamp(0, d.ts.length - 1)).toDouble(),
                min: 0,
                max: (d.ts.isEmpty ? 1 : (d.ts.length - 1)).toDouble(),
                onChangeStart: (_) {
                  setState(() {
                    _scrubbing = true; // 使用者開始拖動，暫停自動定位
                  });
                },
                onChanged: (v) {
                  setState(() {
                    idx = v.round(); // 即時預覽位置
                    if (idx >= 0 && idx < d.ts.length) {
                      _lastDisplayTime = d.ts[idx];
                    }
                  });
                },
                onChangeEnd: (v) {
                  final i = v.round();
                  setState(() {
                    idx = i;
                    _scrubbing = false;
                    // 重新建立播放錨點，使後續自動播放從新位置與當前牆鐘對齊
                    _playStartIdx = i;
                    _playStartTs = d.ts[i];
                    _playStartWall = DateTime.now();
                    _lastDisplayTime = d.ts[i];
                  });
                },
              )),
            ],
          ),

          // 目前點資訊三欄
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _InfoTile(
                  label: L10n.t('timestamp'),
                  value: _fmtTimeWithSeconds(curTime, context)),
              _InfoTile(
                  label: L10n.t('speed'),
                  value: _fmtSpeed(curSp, useMiles: d.useMiles)),
              _InfoTile(
                  label: L10n.t('altitude'),
                  value: hasAltitude
                      ? '${(useFeet ? (curAlt * 3.28084) : curAlt).toStringAsFixed(0)} ${useFeet ? 'ft' : 'm'}'
                      : '—'),
            ],
          ),
          const SizedBox(height: 12),

          // 基本統計 & 天氣（用網格排版，手機 2 欄、寬螢幕 3 欄）
          _StatGrid(children: [
            _ChipStat(L10n.t('distance'),
                '${distValue.toStringAsFixed(2)} ' + distUnit),
            _ChipStat(L10n.t('moving_time'), moving.fmtHms()),
            _ChipStat(L10n.t('total_time'), total.fmtHms()),
            _ChipStat(L10n.t('stopped_time'),
                (stopped.isNegative ? Duration.zero : stopped).fmtHms()),
            _ChipStat(L10n.t('avg_speed'),
                _fmtSpeed(d.avgSpeedMps, useMiles: d.useMiles)),
            _ChipStat(L10n.t('max_speed'),
                _fmtSpeed(d.maxSpeedMps, useMiles: d.useMiles)),
            if (d.weatherTempC != null)
              _ChipStat(L10n.t('temperature'),
                  '${d.weatherTempC!.toStringAsFixed(0)} °C'),
            if (hasAltitude)
              _ChipStat(L10n.t('elevation_gain'),
                  '${elevValue.toStringAsFixed(0)} ' + elevUnit),
          ]),
          const SizedBox(height: 14),

          // 起點/終點（地理反查）
          _AddressStartEndCard(
            startAddress: _startAddr ?? '--',
            endAddress: _endAddr ?? '--',
            startCoord: d.lat.isNotEmpty && d.lon.isNotEmpty
                ? '${d.lat.first.toStringAsFixed(5)}, ${d.lon.first.toStringAsFixed(5)}'
                : '--',
            endCoord: d.lat.isNotEmpty && d.lon.isNotEmpty
                ? '${d.lat.last.toStringAsFixed(5)}, ${d.lon.last.toStringAsFixed(5)}'
                : '--',
            startDate: '${d.start.month}月 ${d.start.day}',
            startTime: _fmtTimeWithSeconds(d.start, context),
            endDate: '${d.end.month}月 ${d.end.day}',
            endTime: _fmtTimeWithSeconds(d.end, context),
          ),
          const SizedBox(height: 12),

          // 速度曲線
          _SectionTitle(L10n.t('speed') + ' (' + speedUnit + ')'),
          SizedBox(
              height: 160,
              child: _LineChart(
                values: d.speedMps.map((e) => e * speedFactor).toList(),
                color: Colors.greenAccent,
                timestamps: d.ts,
                unit: speedUnit,
                fitToWidth: true,
              )),
          const SizedBox(height: 16),

          // 海拔曲線
          if (hasAltitude) ...[
            _SectionTitle(
                L10n.t('altitude') + ' (' + (d.useMiles ? 'ft' : 'm') + ')'),
            SizedBox(
                height: 160,
                child: _LineChart(
                  values: d.alt
                      .map((e) => ((e ?? 0) * (d.useMiles ? 3.28084 : 1.0)))
                      .toList(),
                  color: Colors.pinkAccent,
                  timestamps: d.ts,
                  unit: d.useMiles ? 'ft' : 'm',
                  fitToWidth: true,
                ))
          ] else ...[
            _SectionTitle(
                L10n.t('altitude') + ' (' + (d.useMiles ? 'ft' : 'm') + ')'),
            Container(
              height: 160,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                L10n.t('no_altitude_recorded'),
                style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  const _InfoTile({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              fontSize: 12)),
      const SizedBox(height: 4),
      Text(value,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w700)),
    ]);
  }
}

class _ChipStat extends StatelessWidget {
  final String label;
  final String value;
  const _ChipStat(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Label on first line (allow wrapping; no ellipsis)
          Text(
            label,
            softWrap: true,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 4),
          // Value on second line, right-aligned and allowed to wrap
          Text(
            value,
            softWrap: true,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final List<Widget> children;
  const _StatGrid({required this.children});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final cols = constraints.maxWidth >= 520 ? 3 : 2; // 手機 2 欄、較寬 3 欄
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: children.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: 64, // 增高以容納兩行
        ),
        itemBuilder: (context, i) => children[i],
      );
    });
  }
}

class _AddressStartEndCard extends StatelessWidget {
  final String startAddress;
  final String endAddress;
  final String startCoord;
  final String endCoord;
  final String startDate;
  final String startTime;
  final String endDate;
  final String endTime;
  const _AddressStartEndCard({
    required this.startAddress,
    required this.endAddress,
    required this.startCoord,
    required this.endCoord,
    required this.startDate,
    required this.startTime,
    required this.endDate,
    required this.endTime,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      // Base width 360; clamp scale between 0.85 and 1.2
      final scale = (w / 360.0).clamp(0.85, 1.2);
      final iconSize = (32.0 * scale).clamp(24.0, 36.0);
      final titleSize = (18.0 * scale).clamp(15.0, 20.0);
      final subSize = (13.0 * scale).clamp(11.0, 15.0);
      final dateSize = (18.0 * scale).clamp(15.0, 20.0);
      final timeSize = (13.0 * scale).clamp(11.0, 15.0);
      final dotSize = (5.0 * scale).clamp(3.0, 6.0);
      final titleMaxLines = w < 340 ? 2 : 3;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            _row(
              context,
              leading: _startIcon(size: iconSize),
              title: startAddress,
              subtitle: startCoord,
              date: startDate,
              time: startTime,
              iconSlot: iconSize,
              titleSize: titleSize,
              subSize: subSize,
              dateSize: dateSize,
              timeSize: timeSize,
              titleMaxLines: titleMaxLines,
            ),
            Row(
              children: [
                SizedBox(
                  width: iconSize,
                  child: Column(
                    children: [
                      const SizedBox(height: 2),
                      _Dot(size: dotSize),
                      const SizedBox(height: 4),
                      _Dot(size: dotSize),
                      const SizedBox(height: 4),
                      _Dot(size: dotSize),
                      const SizedBox(height: 2),
                    ],
                  ),
                ),
                const Expanded(child: SizedBox(height: 8)),
              ],
            ),
            _row(
              context,
              leading: _endIcon(size: iconSize),
              title: endAddress,
              subtitle: endCoord,
              date: endDate,
              time: endTime,
              iconSlot: iconSize,
              titleSize: titleSize,
              subSize: subSize,
              dateSize: dateSize,
              timeSize: timeSize,
              titleMaxLines: titleMaxLines,
            ),
          ],
        ),
      );
    });
  }

  Widget _row(
    BuildContext context, {
    required Widget leading,
    required String title,
    required String subtitle,
    required String date,
    required String time,
    required double iconSlot,
    required double titleSize,
    required double subSize,
    required double dateSize,
    required double timeSize,
    required int titleMaxLines,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: iconSlot, child: Center(child: leading)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: titleSize * 1.35,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Text(
                    title.isEmpty ? '--' : title,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: titleSize,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6),
                    fontSize: subSize),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(date,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: dateSize)),
            const SizedBox(height: 6),
            Text(time,
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6),
                    fontSize: timeSize)),
          ],
        ),
      ],
    );
  }

  Widget _startIcon({required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
        border: Border.all(color: Colors.black45, width: 4),
      ),
    );
  }

  Widget _endIcon({required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Icon(Icons.flag,
            color: Colors.black87, size: (size * 0.56).clamp(12, 22)),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final double size;
  const _Dot({this.size = 7});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Section title for detail page
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 極簡折線圖（無第三方套件）
class _LineChart extends StatefulWidget {
  final List<double> values;
  final Color color;
  final List<DateTime>? timestamps;
  final String? unit;
  final int maxPoints;
  final bool fitToWidth; // <— 新增

  const _LineChart({
    required this.values,
    required this.color,
    this.timestamps,
    this.unit,
    this.maxPoints = 600,
    this.fitToWidth = true, // <— 新增（預設就貼齊寬度）
  });

  @override
  State<_LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<_LineChart> {
  // Hover/inspect state
  int? _hoverIdx; // index of the sample being inspected
  double _hoverFrac =
      0.0; // 0..1, interpolation between hoverIdx and hoverIdx+1
  final ScrollController _hScroll = ScrollController();
  DateTime? _lastNudge; // rate-limit edge nudges

  // Constants used by painter; keep in sync
  static const double _leftPad = 40.0;
  static const double _rightPad = 8.0;
  static const double _topPad = 8.0;
  static const double _bottomPad = 30.0;
  // 實際繪圖資料（可能已降採樣）
  List<double> _curValues = const [];
  List<DateTime>? _curTimestamps;
  List<double>?
      _timePosSec; // cached fractional second positions for timestamps

  // ---- Largest-Triangle-Three-Buckets (LTTB) downsampling ----
  // Return selected indices (ascending) into the source arrays
  List<int> _lttbIndices(List<double> xs, List<double> ys, int threshold) {
    final int n = ys.length;
    if (threshold <= 0 || threshold >= n || n <= 2) {
      return List<int>.generate(n, (i) => i);
    }

    final int buckets = threshold - 2; // keep first & last
    final double bucketSize = (n - 2) / buckets;

    final List<int> sampled = List<int>.filled(threshold, 0);
    sampled[0] = 0;
    sampled[threshold - 1] = n - 1;

    int a = 0; // index of previously selected point
    for (int i = 0; i < buckets; i++) {
      int bucketStart = (i * bucketSize + 1.0).floor();
      int bucketEnd = ((i + 1) * bucketSize + 1.0).floor();
      if (bucketEnd <= bucketStart) bucketEnd = bucketStart + 1;
      if (bucketEnd > n - 1) bucketEnd = n - 1;

      int nextBucketStart = (((i + 1) * bucketSize) + 1.0).floor();
      int nextBucketEnd = (((i + 2) * bucketSize) + 1.0).floor();
      if (nextBucketStart < 1) nextBucketStart = 1;
      if (nextBucketEnd > n) nextBucketEnd = n;
      if (nextBucketEnd <= nextBucketStart) nextBucketEnd = nextBucketStart + 1;

      // Average point of the next bucket
      double avgX = 0.0, avgY = 0.0;
      final int nextCount = (nextBucketEnd - nextBucketStart);
      if (nextCount > 0) {
        for (int j = nextBucketStart; j < nextBucketEnd; j++) {
          avgX += xs[j];
          avgY += ys[j];
        }
        avgX /= nextCount;
        avgY /= nextCount;
      } else {
        avgX = xs[a];
        avgY = ys[a];
      }

      // Choose the point in the current bucket that maximizes triangle area
      double maxArea = -1.0;
      int maxIndex = bucketStart;
      for (int j = bucketStart; j < bucketEnd; j++) {
        final double area = ((xs[a] - avgX) * (ys[j] - ys[a]) -
                (xs[a] - xs[j]) * (avgY - ys[a]))
            .abs();
        if (area > maxArea) {
          maxArea = area;
          maxIndex = j;
        }
      }
      sampled[i + 1] = maxIndex;
      a = maxIndex;
    }

    sampled.sort();
    return sampled;
  }

  // Prepare effective arrays used by painters/gestures (with optional LTTB)
  void _buildEffectiveSeries() {
    final srcVals = widget.values;
    final srcTs = widget.timestamps;
    final int n = srcVals.length;

    // 依可視寬度計算實際門檻（fitToWidth 時，以每點 ~3px 為目標）
    int threshold = widget.maxPoints;
    if (widget.fitToWidth) {
      final baseWidth = MediaQuery.of(context).size.width - 32;
      final innerWidth =
          (baseWidth - _leftPad - _rightPad).clamp(80.0, 100000.0);
      const double pxPerPoint = 4.0;
      final int byPixels = (innerWidth / pxPerPoint).floor();
      if (byPixels > 0) {
        threshold = math.min(threshold, byPixels);
      }
    }

    if (threshold > 0 && n > threshold) {
      late final List<double> xs;
      if (srcTs != null && srcTs.isNotEmpty && srcTs.length == n) {
        final DateTime start = srcTs.first;
        xs = List<double>.generate(
            n, (i) => srcTs[i].difference(start).inMilliseconds / 1000.0);
      } else {
        xs = List<double>.generate(n, (i) => i.toDouble());
      }
      final idx = _lttbIndices(xs, srcVals, threshold);
      _curValues = [for (final k in idx) srcVals[k]];
      _curTimestamps = (srcTs != null && srcTs.length == n)
          ? [for (final k in idx) srcTs[k]]
          : null;
    } else {
      _curValues = srcVals;
      _curTimestamps = srcTs;
    }
    _timePosSec = null;
  }

  @override
  void didUpdateWidget(covariant _LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timestamps != widget.timestamps) {
      _timePosSec = null; // rebuild on next use
    }
  }

  String _fmtHms(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // Build cached fractional second positions identical to painter logic
  void _ensureTimePos() {
    final ts = _curTimestamps;
    if (ts == null || ts.isEmpty) return;
    if (_timePosSec != null) return;

    final start = ts.first;
    final end = ts.last;
    final totalSec = end.isAfter(start) ? end.difference(start).inSeconds : 0;
    if (totalSec <= 0 || ts.length != _curValues.length) {
      _timePosSec = null;
      return;
    }
    final counts = <int, int>{};
    for (final t in ts) {
      final s = t.difference(start).inSeconds;
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final seen = <int, int>{};
    _timePosSec = List<double>.filled(ts.length, 0.0);
    for (int i = 0; i < ts.length; i++) {
      final s = ts[i].difference(start).inSeconds;
      final totalInSec = counts[s] ?? 1;
      final k = (seen[s] ?? 0);
      seen[s] = k + 1;
      final frac = totalInSec > 1 ? ((k + 1) / (totalInSec + 1)) : 0.0;
      _timePosSec![i] = s + frac;
    }
  }

  /// Map a local position to a data position (index + fractional offset to next point)
  (int, double) _posFromLocal(Offset local, Size size) {
    if (_curValues.isEmpty) return (0, 0.0);
    final chart = Rect.fromLTWH(
      _leftPad,
      _topPad,
      size.width - _leftPad - _rightPad,
      size.height - _topPad - _bottomPad,
    );
    double x = local.dx.clamp(chart.left, chart.right);

    final ts = _curTimestamps;
    if (ts == null || ts.isEmpty || ts.length != _curValues.length) {
      if (_curValues.length <= 1) return (0, 0.0);
      final ratio = (x - chart.left) / chart.width;
      final pos = ratio * (_curValues.length - 1);
      final i = pos.floor().clamp(0, _curValues.length - 1);
      final frac = (pos - i).clamp(0.0, 1.0);
      return (i, frac);
    }

    final start = ts.first;
    final end = ts.last;
    final totalSec = end.isAfter(start) ? end.difference(start).inSeconds : 0;
    if (totalSec <= 0) return (0, 0.0);

    _ensureTimePos();
    final arr = _timePosSec;
    if (arr == null) {
      int best = 0;
      double bestDiff = double.infinity;
      for (int i = 0; i < ts.length; i++) {
        final s = ts[i].difference(start).inSeconds.toDouble();
        final pxSec = (x - chart.left) / chart.width * totalSec;
        final d = (s - pxSec).abs();
        if (d < bestDiff) {
          bestDiff = d;
          best = i;
        }
      }
      return (best, 0.0);
    }

    final pxSec = (x - chart.left) / chart.width * totalSec;
    int lo = 0, hi = arr.length - 1, i = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (arr[mid] <= pxSec) {
        i = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (i >= arr.length - 1) return (arr.length - 1, 0.0);
    final a = arr[i], b = arr[i + 1];
    final frac = ((pxSec - a) / (b - a)).clamp(0.0, 1.0);
    return (i, frac);
  }

  void _maybeNudgeViewport(int i, double f,
      {required double localX, required Size size}) {
    // If no horizontal scroll container, fallback to nudging the hover cursor
    if (!_hScroll.hasClients) {
      _nudgeHoverFallback(i, f, localX: localX, size: size);
      return;
    }

    final now = DateTime.now();
    if (_lastNudge != null &&
        now.difference(_lastNudge!) < const Duration(milliseconds: 60)) {
      return; // throttle to avoid jitter
    }

    // ---- Compute the WHITE DOT x position in CHILD coordinates ----
    // Keep chart rect in sync with painters
    final Rect chart = Rect.fromLTWH(
      _leftPad,
      _topPad,
      size.width - _leftPad - _rightPad,
      size.height - _topPad - _bottomPad,
    );

    double xAtIndex(int idx) {
      final ts = _curTimestamps;
      if (ts == null || ts.isEmpty || ts.length != _curValues.length) {
        if (_curValues.length <= 1) return chart.left;
        final t = idx / (_curValues.length - 1);
        return chart.left + t * chart.width;
      }
      _ensureTimePos();
      final start = ts.first;
      final end = ts.last;
      final totalSec = end.isAfter(start) ? end.difference(start).inSeconds : 0;
      if (totalSec <= 0) return chart.left;

      if (_timePosSec != null) {
        final secPos = _timePosSec![idx].clamp(0.0, totalSec.toDouble());
        final ratio = (secPos / totalSec).clamp(0.0, 1.0);
        return chart.left + ratio * chart.width;
      }
      final secPos = ts[idx].difference(start).inSeconds.toDouble();
      final ratio = (secPos / totalSec).clamp(0.0, 1.0);
      return chart.left + ratio * chart.width;
    }

    final double x0 = xAtIndex(i);
    final double x1 = i < _curValues.length - 1 ? xAtIndex(i + 1) : x0;
    final double xDot =
        (i < _curValues.length - 1) ? (x0 + (x1 - x0) * f.clamp(0.0, 1.0)) : x0;

    // ---- Viewport edge positions in CHILD coordinates ----
    final pos = _hScroll.position;
    final double viewLeft = pos.pixels;
    final double viewRight = pos.pixels + pos.viewportDimension;

    // Trigger zone margin & pan distance
    const double edgeMargin = 24.0; // px from each edge
    const double pan = 60.0; // px per nudge (smaller to reduce flashing)

    final double before = pos.pixels;
    double? target;

    // If white dot hits the RIGHT edge → move chart to the RIGHT (scroll forward)
    if (xDot >= viewRight - edgeMargin) {
      target = (before + pan).clamp(0.0, pos.maxScrollExtent);
    }
    // If white dot hits the LEFT edge → move chart to the LEFT (scroll backward)
    else if (xDot <= viewLeft + edgeMargin) {
      target = (before - pan).clamp(0.0, pos.maxScrollExtent);
    }

    if (target != null && target != before) {
      _hScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
      _lastNudge = now;
    } else {
      // Final fallback when not scrollable or no movement occurred
      _nudgeHoverFallback(i, f, localX: localX, size: size);
    }
  }

  // 當無法捲動時，直接把 hover 適度往內縮（避免卡在邊緣無法讀值）
  void _nudgeHoverFallback(int i, double f,
      {required double localX, required Size size}) {
    final double rightEdge = size.width - _rightPad - 8;
    final double leftEdge = _leftPad + 8;

    if (localX >= rightEdge && i > 0) {
      setState(() {
        _hoverIdx = (i - 1).clamp(0, _curValues.length - 1);
        _hoverFrac = 0.95; // 把點往左縮一點
      });
    } else if (localX <= leftEdge) {
      setState(() {
        _hoverIdx = (i + 1).clamp(0, _curValues.length - 1);
        _hoverFrac = 0.05; // 把點往右縮一點
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color bgColor = cs.surface;
    final Color axisColor = cs.onSurface.withOpacity(0.2);
    final Color gridColor = cs.onSurface.withOpacity(0.13);
    final Color labelColor = cs.onSurface.withOpacity(0.6);
    final baseWidth = MediaQuery.of(context).size.width - 32;
    // 準備（必要時）降採樣後的序列
    _buildEffectiveSeries();

    double width = baseWidth;
    final ts = _curTimestamps;
    if (widget.fitToWidth) {
      // 一律貼齊可視寬度，不再水平捲動
      width = baseWidth;
    } else {
      // 需要可捲動時才走舊邏輯（總時長 & 依點數的雙策略取較小）
      double durationWidthPx = baseWidth;
      if (ts != null && ts.isNotEmpty) {
        final start = ts.first;
        final end = ts.last;
        final totalMin = end.isAfter(start)
            ? (end.difference(start).inSeconds / 60).ceil().clamp(1, 100000)
            : 1;
        const double pxPerMinute = 80.0;
        durationWidthPx = math.max(baseWidth, totalMin * pxPerMinute);
      }

      const double pxPerPoint = 3.0;
      final double pointWidthPx = math.max(
          baseWidth,
          (_curValues.length <= 1)
              ? baseWidth
              : _curValues.length * pxPerPoint);

      width = math.max(baseWidth, math.min(durationWidthPx, pointWidthPx));
    }
    // Width strategy: duration-based (minutes) but with a per-point soft cap
    // so very long trips won't explode horizontally when we already downsampled.
    double durationWidthPx = baseWidth;
    if (ts != null && ts.isNotEmpty) {
      final start = ts.first;
      final end = ts.last;
      final totalMin = end.isAfter(start)
          ? (end.difference(start).inSeconds / 60).ceil().clamp(1, 100000)
          : 1;
      const double pxPerMinute = 80.0; // original density
      durationWidthPx = math.max(baseWidth, totalMin * pxPerMinute);
    }

    // Cap by effective point count: ensure average spacing ~3 px/point
    const double pxPerPoint = 3.0; // tweakable: 2~4 usually looks good
    final double pointWidthPx = math.max(baseWidth,
        (_curValues.length <= 1) ? baseWidth : _curValues.length * pxPerPoint);

    // Take the smaller of the two strategies to avoid over-long X axis
    width = math.max(baseWidth, math.min(durationWidthPx, pointWidthPx));

    return SingleChildScrollView(
      controller: _hScroll,
      scrollDirection: Axis.horizontal,
      child: LayoutBuilder(builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) {
            final box = context.findRenderObject() as RenderBox;
            final size = box.size;
            final local = box.globalToLocal(d.globalPosition);
            final (i, f) = _posFromLocal(local, size);
            _maybeNudgeViewport(i, f, localX: local.dx, size: size);
            setState(() {
              _hoverIdx = i;
              _hoverFrac = f;
            });
          },
          onLongPressMoveUpdate: (d) {
            final box = context.findRenderObject() as RenderBox;
            final size = box.size;
            final local = box.globalToLocal(d.globalPosition);
            final (i, f) = _posFromLocal(local, size);
            _maybeNudgeViewport(i, f, localX: local.dx, size: size);
            setState(() {
              _hoverIdx = i;
              _hoverFrac = f;
            });
          },
          onLongPressEnd: (_) => setState(() {
            _hoverIdx = null;
            _hoverFrac = 0.0;
          }),
          child: SizedBox(
            width: width,
            child: CustomPaint(
              painter: _LineChartPainter(
                values: _curValues,
                color: widget.color,
                timestamps: _curTimestamps,
                bgColor: bgColor,
                axisColor: axisColor,
                gridColor: gridColor,
                labelColor: labelColor,
              ),
              foregroundPainter: (_hoverIdx != null)
                  ? _LineChartHoverPainter(
                      values: _curValues,
                      timestamps: _curTimestamps,
                      hoverIndex: _hoverIdx!,
                      hoverFrac: _hoverFrac,
                      axisColor: axisColor,
                      labelColor: cs.onSurface,
                      unit: widget.unit,
                    )
                  : null,
            ),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final List<DateTime>? timestamps;
  final Color bgColor;
  final Color axisColor;
  final Color gridColor;
  final Color labelColor;

  _LineChartPainter({
    required this.values,
    required this.color,
    this.timestamps,
    required this.bgColor,
    required this.axisColor,
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background card
    final bg = Paint()..color = bgColor;
    final card =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(card, bg);

    // Space for axes
    const leftPad = 40.0; // y-axis + labels
    const rightPad = 8.0;
    const topPad = 8.0;
    const bottomPad =
        30.0; // x-axis + labels (increased for label not to be clipped)

    final chart = Rect.fromLTWH(
      leftPad,
      topPad,
      size.width - leftPad - rightPad,
      size.height - topPad - bottomPad,
    );

    if (values.isEmpty) return;

    // Data range
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);

    final bool hasTs = timestamps != null && timestamps!.isNotEmpty;
    final DateTime? startTime = hasTs ? timestamps!.first : null;
    final DateTime? endTime = hasTs ? timestamps!.last : null;
    final int totalSec = (hasTs && endTime!.isAfter(startTime!))
        ? endTime.difference(startTime).inSeconds
        : 0;

    // --- Prevent vertical steps when multiple samples share the same second ---
    // Build a fractional position inside each second so x increases monotonically.
    List<double>?
        _timePosSec; // seconds since start (may contain fractional part)
    if (hasTs && totalSec > 0 && timestamps!.length == values.length) {
      final counts = <int, int>{}; // second -> total count in that second
      for (final t in timestamps!) {
        final s = t.difference(startTime!).inSeconds;
        counts[s] = (counts[s] ?? 0) + 1;
      }
      final seen = <int, int>{}; // second -> index seen so far
      _timePosSec = List<double>.filled(timestamps!.length, 0.0);
      for (int i = 0; i < timestamps!.length; i++) {
        final s = timestamps![i].difference(startTime!).inSeconds;
        final totalInSec = counts[s] ?? 1;
        final k = (seen[s] ?? 0);
        seen[s] = k + 1;
        // Place samples evenly within the same second: (k+1)/(totalInSec+1) keeps inside the second
        final frac = totalInSec > 1 ? ((k + 1) / (totalInSec + 1)) : 0.0;
        _timePosSec[i] = s + frac; // strictly increasing inside the same second
      }
    }

    double xAt(int i) {
      if (!hasTs || totalSec <= 0 || timestamps!.length != values.length) {
        if (values.length <= 1) return chart.left;
        final t = i / (values.length - 1);
        return chart.left + t * chart.width;
      }
      final double secPos = (_timePosSec != null)
          ? _timePosSec[i]
          : timestamps![i].difference(startTime!).inSeconds.toDouble();
      final ratio = (secPos / totalSec).clamp(0.0, 1.0);
      return chart.left + ratio * chart.width;
    }

    double yAt(double v) {
      final t = (v - minV) / range; // 0..1
      return chart.bottom - t * chart.height;
    }

    // Axes & grid
    final axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;

    // y-axis
    canvas.drawLine(
        Offset(chart.left, chart.top), Offset(chart.left, chart.bottom), axis);
    // x-axis
    canvas.drawLine(Offset(chart.left, chart.bottom),
        Offset(chart.right, chart.bottom), axis);

    // y ticks: min, mid, max
    final yTicks = <double>[minV, (minV + maxV) / 2, maxV];
    for (final v in yTicks) {
      final y = yAt(v);
      // tick
      canvas.drawLine(Offset(chart.left - 4, y), Offset(chart.left, y), axis);
      // grid
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y),
          axis..color = gridColor);
      // label
      final tp = TextPainter(
        text: TextSpan(
            text: _fmtNumber(v),
            style: TextStyle(color: labelColor, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 8);
      tp.paint(canvas, Offset(chart.left - tp.width - 6, y - tp.height / 2));
      axis.color = axisColor; // reset
    }

    // x ticks: adaptive (seconds-mode for short trips, minutes-mode otherwise)
    if (hasTs && totalSec > 0) {
      if (totalSec <= 120) {
        // ===== Seconds mode (<= 2 minutes) =====
        const int minorTickSec = 5; // short ticks every 5s
        final double pxPerSec = chart.width / totalSec;
        const double minLabelPx = 48.0;
        final candidatesSec = <int>[5, 10, 15, 30, 60];
        int labelEverySec = 5;
        for (final c in candidatesSec) {
          if (pxPerSec * c >= minLabelPx) {
            labelEverySec = c;
            break;
          }
        }

        // START label
        final double xStart = chart.left;
        canvas.drawLine(Offset(xStart, chart.bottom),
            Offset(xStart, chart.bottom + 4), axis);
        final String startLabel = _fmtTimeLabel(startTime!, seconds: true);
        final tpStart = TextPainter(
          text: TextSpan(
              text: startLabel,
              style: TextStyle(color: labelColor, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tpStart.paint(
            canvas, Offset(xStart - tpStart.width / 2, chart.bottom + 6));

        // Align to the next 5s boundary
        DateTime tick = startTime.add(Duration(
            seconds: minorTickSec -
                (startTime.second % minorTickSec == 0
                    ? 0
                    : startTime.second % minorTickSec)));
        while (!tick.isAfter(endTime!)) {
          final double ratio = tick.difference(startTime).inSeconds / totalSec;
          final double x = chart.left + ratio * chart.width;
          canvas.drawLine(
              Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);

          final int secsFromStart = tick.difference(startTime).inSeconds;
          final bool drawLabel = (secsFromStart % labelEverySec == 0);
          if (drawLabel) {
            final String label = _fmtTimeLabel(tick, seconds: true);
            final tp = TextPainter(
              text: TextSpan(
                  text: label,
                  style: TextStyle(color: labelColor, fontSize: 10)),
              textDirection: TextDirection.ltr,
            )..layout();
            tp.paint(canvas, Offset(x - tp.width / 2, chart.bottom + 6));
          }
          tick = tick.add(const Duration(seconds: minorTickSec));
        }

        // END label
        final double xEnd = chart.right;
        canvas.drawLine(
            Offset(xEnd, chart.bottom), Offset(xEnd, chart.bottom + 4), axis);
        final String endLabel = _fmtTimeLabel(endTime, seconds: true);
        final tpEnd = TextPainter(
          text: TextSpan(
              text: endLabel,
              style: TextStyle(color: labelColor, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tpEnd.paint(canvas, Offset(xEnd - tpEnd.width / 2, chart.bottom + 6));
      } else {
        // ===== Minutes mode (> 2 minutes) =====
        const int minorTickMin = 5; // short ticks every 5 min
        final double pxPerMinute = chart.width / (totalSec / 60.0);
        const double minLabelPx = 48.0;
        final candidates = <int>[5, 10, 15, 30, 60, 120];
        int labelEveryMin = 5;
        for (final c in candidates) {
          if (pxPerMinute * c >= minLabelPx) {
            labelEveryMin = c;
            break;
          }
        }

        // START label
        final double xStart = chart.left;
        canvas.drawLine(Offset(xStart, chart.bottom),
            Offset(xStart, chart.bottom + 4), axis);
        final String startLabel = _fmtTimeLabel(startTime!, seconds: false);
        final tpStart = TextPainter(
          text: TextSpan(
              text: startLabel,
              style: TextStyle(color: labelColor, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tpStart.paint(
            canvas, Offset(xStart - tpStart.width / 2, chart.bottom + 6));

        // Align to 5-min boundary
        DateTime tick = DateTime(
            startTime.year,
            startTime.month,
            startTime.day,
            startTime.hour,
            startTime.minute - (startTime.minute % minorTickMin));
        if (tick.isBefore(startTime))
          tick = tick.add(const Duration(minutes: minorTickMin));
        while (!tick.isAfter(endTime!)) {
          final double ratio = tick.difference(startTime).inSeconds / totalSec;
          final double x = chart.left + ratio * chart.width;
          canvas.drawLine(
              Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);

          final minutesFromStart = tick.difference(startTime).inMinutes;
          final bool drawLabel = (minutesFromStart % labelEveryMin == 0);
          if (drawLabel) {
            final String label = _fmtTimeLabel(tick, seconds: false);
            final tp = TextPainter(
              text: TextSpan(
                  text: label,
                  style: TextStyle(color: labelColor, fontSize: 10)),
              textDirection: TextDirection.ltr,
            )..layout();
            tp.paint(canvas, Offset(x - tp.width / 2, chart.bottom + 6));
          }
          tick = tick.add(const Duration(minutes: minorTickMin));
        }

        // END label
        final double xEnd = chart.right;
        canvas.drawLine(
            Offset(xEnd, chart.bottom), Offset(xEnd, chart.bottom + 4), axis);
        final String endLabel = _fmtTimeLabel(endTime, seconds: false);
        final tpEnd = TextPainter(
          text: TextSpan(
              text: endLabel,
              style: TextStyle(color: labelColor, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tpEnd.paint(canvas, Offset(xEnd - tpEnd.width / 2, chart.bottom + 6));
      }
    } else {
      // 無時間資料：退回百分比刻度
      const xT = [0.0, 0.5, 1.0];
      const xLabels = ['0%', '50%', '100%'];
      for (int i = 0; i < xT.length; i++) {
        final x = chart.left + xT[i] * chart.width;
        canvas.drawLine(
            Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);
        final tp = TextPainter(
          text: TextSpan(
              text: xLabels[i],
              style: TextStyle(color: labelColor, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, chart.bottom + 6));
      }
    }

    // Data path (smoothed)
    final points = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      points.add(Offset(xAt(i), yAt(values[i])));
    }
    Path path;
    if (points.length < 3) {
      path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
    } else {
      // Catmull-Rom to Bezier
      const double t = 0.5; // tension
      path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 0; i < points.length - 1; i++) {
        final p0 = i == 0 ? points[0] : points[i - 1];
        final p1 = points[i];
        final p2 = points[i + 1];
        final p3 = (i + 2 < points.length) ? points[i + 2] : points[i + 1];
        final c1 = Offset(
          p1.dx + (p2.dx - p0.dx) * (t / 6.0),
          p1.dy + (p2.dy - p0.dy) * (t / 6.0),
        );
        final c2 = Offset(
          p2.dx - (p3.dx - p1.dx) * (t / 6.0),
          p2.dy - (p3.dy - p1.dy) * (t / 6.0),
        );
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
      }
    }

    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawPath(path, p);
  }

  String _fmtNumber(double v) {
    final s = (v.abs() < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0));
    return s.replaceAll(RegExp(r"\.0$"), '');
  }

  String _fmtTimeLabel(DateTime t, {required bool seconds}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return seconds
        ? '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        : '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.values != values ||
      old.color != color ||
      old.timestamps != timestamps ||
      old.bgColor != bgColor ||
      old.axisColor != axisColor ||
      old.gridColor != gridColor ||
      old.labelColor != labelColor;
}

class _LineChartHoverPainter extends CustomPainter {
  final List<double> values;
  final List<DateTime>? timestamps;
  final int hoverIndex;
  final double hoverFrac; // 0..1 between index and index+1
  final Color axisColor;
  final Color labelColor;
  final String? unit;

  _LineChartHoverPainter({
    required this.values,
    required this.timestamps,
    required this.hoverIndex,
    required this.hoverFrac,
    required this.axisColor,
    required this.labelColor,
    this.unit,
  });

  String _fmtHms(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    // Keep constants in sync with _LineChartPainter
    const leftPad = 40.0;
    const rightPad = 8.0;
    const topPad = 8.0;
    const bottomPad = 30.0;

    final chart = Rect.fromLTWH(
      leftPad,
      topPad,
      size.width - leftPad - rightPad,
      size.height - topPad - bottomPad,
    );

    // Compute y-range like painter
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);
    double yAt(double v) {
      final t = (v - minV) / range;
      return chart.bottom - t * chart.height;
    }

    // Compute x for hoverIndex similar to painter's xAt
    double xAtIndex(int i) {
      if (timestamps == null ||
          timestamps!.isEmpty ||
          timestamps!.length != values.length) {
        if (values.length <= 1) return chart.left;
        final t = i / (values.length - 1);
        return chart.left + t * chart.width;
      }
      final start = timestamps!.first;
      final end = timestamps!.last;
      final totalSec = end.isAfter(start) ? end.difference(start).inSeconds : 0;
      if (totalSec <= 0) return chart.left;

      // fractional positions inside seconds like painter
      final counts = <int, int>{};
      for (final tt in timestamps!) {
        final s = tt.difference(start).inSeconds;
        counts[s] = (counts[s] ?? 0) + 1;
      }
      final seen = <int, int>{};
      final arr = List<double>.filled(timestamps!.length, 0.0);
      for (int j = 0; j < timestamps!.length; j++) {
        final s = timestamps![j].difference(start).inSeconds;
        final totalInSec = counts[s] ?? 1;
        final k = (seen[s] ?? 0);
        seen[s] = k + 1;
        final frac = totalInSec > 1 ? ((k + 1) / (totalInSec + 1)) : 0.0;
        arr[j] = s + frac;
      }
      final ratio = (arr[i] / totalSec).clamp(0.0, 1.0);
      return chart.left + ratio * chart.width;
    }

    final i = hoverIndex.clamp(0, values.length - 1);

    double x;
    double y;
    if (i < values.length - 1) {
      // interpolate between i and i+1
      final x0 = xAtIndex(i);
      final x1 = xAtIndex(i + 1);
      final v0 = values[i];
      final v1 = values[i + 1];
      final f = hoverFrac.clamp(0.0, 1.0);
      x = x0 + (x1 - x0) * f;
      y = yAt(v0 + (v1 - v0) * f);
    } else {
      x = xAtIndex(i);
      y = yAt(values[i]);
    }

    final guide = Paint()
      ..color = axisColor
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), guide);

    final dot = Paint()..color = labelColor;
    canvas.drawCircle(Offset(x, y), 3.5, dot);

    // Interpolated time/value for display
    double valueInterp;
    DateTime? timeInterp;
    if (i < values.length - 1) {
      final f = hoverFrac.clamp(0.0, 1.0);
      valueInterp = values[i] + (values[i + 1] - values[i]) * f;
      if (timestamps != null && timestamps!.length == values.length) {
        final t0 = timestamps![i];
        final t1 = timestamps![i + 1];
        timeInterp = t0.add(Duration(
            milliseconds: (t1.difference(t0).inMilliseconds * f).round()));
      }
    } else {
      valueInterp = values[i];
      if (timestamps != null && timestamps!.length == values.length) {
        timeInterp = timestamps![i];
      }
    }
    final valueCore = valueInterp.abs() < 10
        ? valueInterp.toStringAsFixed(1)
        : valueInterp.toStringAsFixed(0);
    final valueText =
        (unit == null || unit!.isEmpty) ? valueCore : '$valueCore $unit';
    final text = (timeInterp != null)
        ? '${_fmtHms(timeInterp!)}\n$valueText'
        : valueText;

    final tp = TextPainter(
      text: TextSpan(
          style: TextStyle(
              color: labelColor, fontSize: 11, fontWeight: FontWeight.w600),
          text: text),
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(80, chart.width * 0.6));

    const pad = 6.0;
    final boxW = tp.width + pad * 2;
    final boxH = tp.height + pad * 2;
    double bx = x + 8;
    double by = chart.top + 8;
    if (bx + boxW > chart.right) bx = x - 8 - boxW; // flip to left if overflow
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, by, boxW, boxH), const Radius.circular(6));
    final paintBg = Paint()..color = Colors.black.withOpacity(0.6);
    canvas.drawRRect(rrect, paintBg);
    tp.paint(canvas, Offset(bx + pad, by + pad));
  }

  @override
  bool shouldRepaint(covariant _LineChartHoverPainter old) =>
      old.values != values ||
      old.timestamps != timestamps ||
      old.hoverIndex != hoverIndex ||
      old.hoverFrac != hoverFrac ||
      old.axisColor != axisColor ||
      old.labelColor != labelColor ||
      old.unit != unit;
}

class InteractiveTripMap extends StatefulWidget {
  final List<ll.LatLng> points;
  final int currentIndex; // 播放進度指到的點
  const InteractiveTripMap({
    super.key,
    required this.points,
    required this.currentIndex,
  });

  @override
  State<InteractiveTripMap> createState() => _InteractiveTripMapState();
}

class _InteractiveTripMapState extends State<InteractiveTripMap>
    with AutomaticKeepAliveClientMixin<InteractiveTripMap> {
  // Dot pixel size constants for dynamic icons (越近越小、越遠越大)
  static const double kDotMinPx = 30;
  static const double kDotMaxPx = 68; // 放遠時最大視覺像素（上限）
  bool _didInitialFit = false; // 只在進入頁面自動縮放一次
  // Controllers for iOS AppleMap / flutter_map
  am.AppleMapController? _amController;
  am.LatLngBounds? _lastFittedBounds; // 記錄上次 auto-fit 的路徑邊界
  am.CameraPosition? _cameraPos; // 快取目前相機位置，用來做 px→m
  // 需要在檔頭 imports 加：  import 'dart:ui' as ui;
  final Map<String, am.BitmapDescriptor> _iconCache = {}; // key: 'start', 'end'

  am.BitmapDescriptor? _movingIcon; // 藍色定位點樣式（固定像素）
  // 用 Canvas 畫出圓點（實心＋外框）→ 轉成 PNG → BitmapDescriptor
  Future<am.BitmapDescriptor> _makeDotIcon({
    required double diameter,
    required Color fill,
    required Color stroke,
    double strokeWidth = 3.0,
  }) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final d = diameter, r = d / 2.0;
    final center = Offset(r, r);
    final paintFill = Paint()..color = fill;
    final paintStroke = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    c.drawCircle(center, r - strokeWidth / 2.0, paintFill);
    c.drawCircle(center, r - strokeWidth / 2.0, paintStroke);

    final pic = rec.endRecording();
    final img = await pic.toImage(d.ceil(), d.ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return am.BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  am.LatLngBounds _boundsFor(List<ll.LatLng> pts) {
    double minLat = pts.first.latitude,
        maxLat = pts.first.latitude,
        minLon = pts.first.longitude,
        maxLon = pts.first.longitude;
    for (final p in pts.skip(1)) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return am.LatLngBounds(
      southwest: am.LatLng(minLat, minLon),
      northeast: am.LatLng(maxLat, maxLon),
    );
  }

  void _maybeInitialFit() {
    if (_didInitialFit) return;
    if (_amController == null) return;
    if (widget.points.isEmpty) return;

    _didInitialFit = true;

    // 等下一幀再做，確保地圖完成初始 layout
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitToAllPoints(animate: false);

      // 再加一次極短延遲的保險，避免某些機型第一下被覆寫
      Future.delayed(const Duration(milliseconds: 50), () {
        if (!mounted) return;
        _fitToAllPoints(animate: false);
      });
    });
  }

  Future<void> _fitToAllPoints({bool animate = true}) async {
    if (widget.points.isEmpty) return;
    if (_amController == null) return;

    if (widget.points.length == 1) {
      final t = am.CameraUpdate.newCameraPosition(
        am.CameraPosition(
          target: am.LatLng(
              widget.points.first.latitude, widget.points.first.longitude),
          zoom: 16,
        ),
      );
      _lastFittedBounds = null; // 單點無 bounds
      if (animate) {
        await _amController!.animateCamera(t);
      } else {
        await _amController!.moveCamera(t);
      }
      return;
    }

    final b = _boundsFor(widget.points);
    _lastFittedBounds = b; // 記錄此次自動縮放的邊界
    final update = am.CameraUpdate.newLatLngBounds(b, 48.0); // 四周留 48px
    if (animate) {
      await _amController!.animateCamera(update);
    } else {
      await _amController!.moveCamera(update);
    }
  }

  bool _boundsApproxEqual(am.LatLngBounds a, am.LatLngBounds b,
      {double tol = 1e-5}) {
    bool close(double x, double y) => (x - y).abs() <= tol;
    return close(a.southwest.latitude, b.southwest.latitude) &&
        close(a.southwest.longitude, b.southwest.longitude) &&
        close(a.northeast.latitude, b.northeast.latitude) &&
        close(a.northeast.longitude, b.northeast.longitude);
  }

  // 動態依目前 zoom 直接重生 icon（不做 bucket）；越近越小、越遠越大
  double? _lastIconSize; // 記錄最近一次的像素尺寸，避免無謂重建
  Timer? _iconRegenDebounce;

  // 依當前 zoom 在 [kDotMinPx, kDotMaxPx] 之間取一個像素大小：
  // 越遠（zoom 小）→ 圓點越大；越近（zoom 大）→ 圓點越小。
  double _dotPxForZoom() {
    final z = _cameraPos?.zoom ?? 14.0;
    const double zNear = 18.0; // 很近（放大）
    const double zFar = 10.0; // 很遠（縮小）

    // 正確方向：z = zNear → t=0；z = zFar → t=1
    final t = ((z - zNear) / (zFar - zNear)).clamp(0.0, 1.0);

    // 越遠（t→1）→ 圓點越大；越近（t→0）→ 圓點越小
    return kDotMinPx + (kDotMaxPx - kDotMinPx) * t;
  }

  Future<void> _refreshDotIcons() async {
    final size = _dotPxForZoom();
    // 若變化極小（<0.5px）就不重生，減少抖動與成本
    if (_lastIconSize != null && (size - _lastIconSize!).abs() < 0.5) return;

    final start = await _makeDotIcon(
      diameter: size,
      fill: Colors.white,
      stroke: Colors.black,
      strokeWidth: 3,
    );
    final end = await _makeDotIcon(
      diameter: size,
      fill: Colors.red,
      stroke: Colors.black,
      strokeWidth: 2,
    );
    final moving = await _makeDotIcon(
      diameter: size,
      fill: const Color(0xFF0A84FF), // iOS 系統藍近似
      stroke: Colors.white,
      strokeWidth: 3,
    );

    _iconCache['start'] = start;
    _iconCache['end'] = end;
    _movingIcon = moving; // ★ 移動點也跟著縮放

    _lastIconSize = size;

    // 若目前有有效的播放位置，就用新的位圖更新一次移動點註記
    if (widget.points.isNotEmpty &&
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.points.length) {
      _updateMovingAnnotation(widget.points[widget.currentIndex]);
    }

    if (mounted) setState(() {});
  }

  final MapController _fmController = MapController();
  // --- Cached, non-rebuilt polylines to avoid flicker ---
  am.Polyline? _amTripLine; // iOS AppleMap polyline (固定)
  Polyline? _fmTripLine; // flutter_map polyline (固定)

  // 移動點 Marker 快取
  am.Annotation? _movingAnnotation;

  void _rebuildTripPolylines() {
    if (widget.points.isNotEmpty) {
      // Apple Map polyline
      _amTripLine = am.Polyline(
        polylineId: am.PolylineId('trip_line'),
        points: [
          for (final p in widget.points) am.LatLng(p.latitude, p.longitude)
        ],
        width: 4,
        color: Colors.red,
        zIndex: 1, // 低於移動點
      );

      // flutter_map polyline
      _fmTripLine = Polyline(
        points: widget.points,
        strokeWidth: 4,
        color: Colors.red,
      );
    } else {
      _amTripLine = null;
      _fmTripLine = null;
    }
  }

  // 更新移動點 Marker
  void _updateMovingAnnotation(ll.LatLng pos) {
    if (_movingIcon == null) return; // icon 尚未就緒，先不建
    _movingAnnotation = am.Annotation(
      annotationId: am.AnnotationId('moving_dot'),
      position: am.LatLng(pos.latitude, pos.longitude),
      draggable: false,
      alpha: 1.0,
      zIndex: 1000,
      icon: _movingIcon!, // ★ 這裡用非 nullable
    );
  }

  @override
  @override
  void didUpdateWidget(covariant InteractiveTripMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 播放索引變更：只更新移動點，不自動縮放
    if (oldWidget.currentIndex != widget.currentIndex &&
        widget.points.isNotEmpty &&
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.points.length) {
      _updateMovingAnnotation(widget.points[widget.currentIndex]);
    }

    // 初次資料就緒或換了一段路（bounds 真的改變）才自動縮放一次
    if (widget.points.isNotEmpty) {
      if (widget.points.length == 1) {
        // 單點：沒有 bounds，比對不到；直接依規則置中
        if (_lastFittedBounds != null) {
          _fitToAllPoints(animate: false);
        }
      } else {
        final newB = _boundsFor(widget.points);
        final needRefit = (_lastFittedBounds == null) ||
            !_boundsApproxEqual(_lastFittedBounds!, newB);
        if (needRefit) {
          _fitToAllPoints(animate: false); // 內部會更新 _lastFittedBounds
        }
      }
    }
  }

  // Cache last fitted hash to avoid redundant fits
  int _lastFitHash = 0;
  // 讓端點/播放點半徑維持「接近固定像素大小」：依 zoom 換算像素→公尺
  double _lastZoom = 15.0;
  double _centerLat = 0.0; // 目前視圖中心緯度（用來換算每像素幾公尺）

  // Web Mercator 近似：每像素（公尺）
  double _metersPerPixel(double lat, double zoom) {
    // ...（原始程式碼）...
    // 省略未變動部分
    throw UnimplementedError();
  }

  @override
  void initState() {
    super.initState();
    // 讓 px→m 有初始參考
    if (widget.points.isNotEmpty) {
      _cameraPos ??= am.CameraPosition(
        target: am.LatLng(
            widget.points.first.latitude, widget.points.first.longitude),
        zoom: 14,
      );
    }
    _rebuildTripPolylines();
    // 若 points 已經就緒但 onMapCreated 尚未觸發，首幀後再嘗試一次 auto-fit
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeInitialFit();
    });

// 先準備藍點 icon，再建立移動點註記

// 依當前 zoom 產生第一組端點 icon
    _refreshDotIcons();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 讓 keep-alive 生效
    // 只顯示 AppleMap 相關部分
    return am.AppleMap(
      onCameraMove: (am.CameraPosition pos) {
        _cameraPos = pos; // 更新最新 zoom/中心
        setState(() {}); // 讓畫面即時刷新
        // 小幅 debounce，避免每個 tick 都重生 icon
        _iconRegenDebounce?.cancel();
        _iconRegenDebounce = Timer(const Duration(milliseconds: 80), () {
          if (mounted) _refreshDotIcons();
        });
      },
      onMapCreated: (c) {
        _amController = c;
        _maybeInitialFit();
      },
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
      initialCameraPosition: am.CameraPosition(
        target: widget.points.isNotEmpty
            ? am.LatLng(
                widget.points.first.latitude,
                widget.points.first.longitude,
              )
            : const am.LatLng(25.0330, 121.5654), // fallback: Taipei
        zoom: 14,
      ),
      polylines: {
        if (_amTripLine != null) _amTripLine!,
      },
      annotations: {
        // --- 起點：白點黑框（會隨縮放改變像素大小） ---
        if (widget.points.isNotEmpty && _iconCache['start'] != null)
          am.Annotation(
            annotationId: am.AnnotationId('start'),
            position: am.LatLng(
              widget.points.first.latitude,
              widget.points.first.longitude,
            ),
            icon: _iconCache['start']!,
            zIndex: 20,
            draggable: false,
          ),
        // --- 終點：紅色實心點（細黑邊；會隨縮放改變像素大小） ---
        if (widget.points.length > 1 && _iconCache['end'] != null)
          am.Annotation(
            annotationId: am.AnnotationId('end'),
            position: am.LatLng(
              widget.points.last.latitude,
              widget.points.last.longitude,
            ),
            icon: _iconCache['end']!,
            zIndex: 20,
            draggable: false,
          ),
        // --- 播放中的移動點（放最上層） ---
        if (_movingAnnotation != null) _movingAnnotation!,
      },
    );
  }

  @override
  void dispose() {
    _iconRegenDebounce?.cancel();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;
}
