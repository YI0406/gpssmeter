import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'tripdata.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:gps_speedometer_min/setting.dart';
import 'total.dart';
import 'package:share_plus/share_plus.dart';

/// 簡易的旅程摘要資料模型
class TripSummary {
  final String id; // 用於檔名與刪除識別
  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final double totalDistanceMeters;
  final Duration movingTime;
  final List<Offset>? previewPath; // 用於縮圖繪製的歸一化座標 (0~1)
  final List<ll.LatLng>? geoPoints; // 真實經緯度軌跡（用於地圖）
  final Rect?
      geoBounds; // 經緯度外框：left=minLng, top=maxLat, right=maxLng, bottom=minLat

  TripSummary({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.totalDistanceMeters,
    required this.movingTime,
    this.previewPath,
    this.geoPoints,
    this.geoBounds,
  });

  factory TripSummary.fromJson(Map<String, dynamic> json) {
    final pts = (json['points'] as List?)?.map((e) {
      final p = (e as List).cast<num>();
      return ll.LatLng(p[0].toDouble(), p[1].toDouble());
    }).toList();

    Rect? bounds;
    if (json['bounds'] is Map) {
      final b = json['bounds'] as Map;
      final minLat = (b['minLat'] as num).toDouble();
      final minLng = (b['minLng'] as num).toDouble();
      final maxLat = (b['maxLat'] as num).toDouble();
      final maxLng = (b['maxLng'] as num).toDouble();
      bounds = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);
    }
    return TripSummary(
      id: json['id'] as String,
      name: json['name'] as String? ?? '未命名旅程',
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      totalDistanceMeters:
          (json['totalDistanceMeters'] as num?)?.toDouble() ?? 0,
      movingTime:
          Duration(milliseconds: (json['movingTimeMs'] as num?)?.toInt() ?? 0),
      previewPath: (json['previewPath'] as List?)?.map((e) {
        final p = (e as List).cast<num>();
        return Offset(p[0].toDouble(), p[1].toDouble());
      }).toList(),
      geoPoints: pts,
      geoBounds: bounds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'totalDistanceMeters': totalDistanceMeters,
        'movingTimeMs': movingTime.inMilliseconds,
        'previewPath': previewPath?.map((o) => [o.dx, o.dy]).toList(),
        if (geoPoints != null)
          'points': geoPoints!.map((e) => [e.latitude, e.longitude]).toList(),
        if (geoBounds != null)
          'bounds': {
            'minLat': geoBounds!.bottom,
            'minLng': geoBounds!.left,
            'maxLat': geoBounds!.top,
            'maxLng': geoBounds!.right,
          },
      };
}

/// 檔案存取：trips/index.json 內放 summaries；trips/{id}.json 放完整內容
class TripStore {
  TripStore._();
  static final TripStore instance = TripStore._();
  Future<double?> loadMaxSpeedKmh(String id) async {
    try {
      // 優先讀取新格式 trips/{id}.json
      final tripsDir = await _rootDir();
      File f = File('${tripsDir.path}/$id.json');
      if (!await f.exists()) {
        // 試試舊格式（documents 根目錄）
        final legacyDir = await _legacyRootDir();
        final lf = File('${legacyDir.path}/$id.json');
        if (await lf.exists())
          f = lf;
        else
          return null;
      }
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return null;
      final m = json as Map<String, dynamic>;
      if (m['maxSpeedKmh'] is num) return (m['maxSpeedKmh'] as num).toDouble();
      if (m['maxSpeedMps'] is num)
        return (m['maxSpeedMps'] as num).toDouble() * 3.6;
      if (m['samples'] is List) {
        double best = 0;
        for (final s in (m['samples'] as List)) {
          if (s is Map && s['speedMps'] is num) {
            final v = (s['speedMps'] as num).toDouble() * 3.6;
            if (v > best) best = v;
          }
        }
        return best > 0 ? best : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _rootDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final trips = Directory('${dir.path}/trips');
    if (!await trips.exists()) await trips.create(recursive: true);
    return trips;
  }

  Future<File> _indexFile() async {
    final d = await _rootDir();
    return File('${d.path}/index.json');
  }

  /// 舊版（main.dart）儲存位置：直接在 documents 根目錄（非 trips/ 子資料夾）
  Future<Directory> _legacyRootDir() async {
    return getApplicationDocumentsDirectory();
  }

  /// 讀取舊版 trip_*.json 檔，轉成 TripSummary（從 samples 抽經緯度）
  Future<TripSummary?> _readLegacyTripFile(File f) async {
    try {
      final txt = await f.readAsString();
      final m = jsonDecode(txt) as Map<String, dynamic>;
      final String id = f.uri.pathSegments.last
          .replaceAll('.json', ''); // e.g. trip_20250824_012233
      final String name = (m['name'] as String?)?.trim().isNotEmpty == true
          ? (m['name'] as String)
          : '未命名旅程';
      final DateTime start =
          DateTime.tryParse(m['startAt']?.toString() ?? '') ?? DateTime.now();
      final DateTime end =
          DateTime.tryParse(m['endAt']?.toString() ?? '') ?? start;
      final double distance = (m['distanceMeters'] as num?)?.toDouble() ?? 0.0;
      final int movingSec = (m['movingSeconds'] as num?)?.toInt() ?? 0;

      // 從 samples 取經緯度
      List<ll.LatLng> pts = [];
      final samples = m['samples'];
      if (samples is List) {
        for (final s in samples) {
          if (s is Map) {
            final lat = (s['lat'] as num?)?.toDouble();
            final lon = (s['lon'] as num?)?.toDouble();
            if (lat != null && lon != null) {
              pts.add(ll.LatLng(lat, lon));
            }
          }
        }
      }

      Rect? bounds;
      if (pts.isNotEmpty) {
        double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
        for (final g in pts) {
          if (g.latitude < minLat) minLat = g.latitude;
          if (g.latitude > maxLat) maxLat = g.latitude;
          if (g.longitude < minLng) minLng = g.longitude;
          if (g.longitude > maxLng) maxLng = g.longitude;
        }
        bounds = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);
      }

      return TripSummary(
        id: id,
        name: name,
        startTime: start,
        endTime: end,
        totalDistanceMeters: distance,
        movingTime: Duration(seconds: movingSec),
        previewPath: null,
        geoPoints: pts.isEmpty ? null : pts,
        geoBounds: bounds,
      );
    } catch (_) {
      return null;
    }
  }

  /// Helper: read a trip JSON file and return a minimal TripSummary.
  Future<TripSummary?> _readTripSummaryFromFile(File f) async {
    try {
      final content = await f.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      // id: from file name if missing
      String id = json['id'] as String? ??
          f.uri.pathSegments.last.replaceAll('.json', '');
      String name = json['name'] as String? ?? '未命名旅程';
      DateTime now = DateTime.now();
      DateTime startTime;
      DateTime endTime;
      if (json.containsKey('startTime')) {
        startTime = DateTime.tryParse(json['startTime'].toString()) ?? now;
      } else {
        startTime = now;
      }
      if (json.containsKey('endTime')) {
        endTime = DateTime.tryParse(json['endTime'].toString()) ?? startTime;
      } else {
        endTime = startTime;
      }
      double totalDistanceMeters =
          (json['totalDistanceMeters'] as num?)?.toDouble() ?? 0;
      Duration movingTime =
          Duration(milliseconds: (json['movingTimeMs'] as num?)?.toInt() ?? 0);
      // geoPoints from points
      List<ll.LatLng>? geoPoints;
      if (json['points'] is List) {
        try {
          geoPoints = (json['points'] as List).map((e) {
            final p = (e as List).cast<num>();
            return ll.LatLng(p[0].toDouble(), p[1].toDouble());
          }).toList();
        } catch (_) {}
      }
      // bounds
      Rect? geoBounds;
      if (json['bounds'] is Map) {
        final b = json['bounds'] as Map;
        try {
          final minLat = (b['minLat'] as num).toDouble();
          final minLng = (b['minLng'] as num).toDouble();
          final maxLat = (b['maxLat'] as num).toDouble();
          final maxLng = (b['maxLng'] as num).toDouble();
          geoBounds = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);
        } catch (_) {}
      }
      // If no bounds but have points, compute bounds
      if (geoBounds == null && geoPoints != null && geoPoints.isNotEmpty) {
        double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
        for (final g in geoPoints) {
          if (g.latitude < minLat) minLat = g.latitude;
          if (g.latitude > maxLat) maxLat = g.latitude;
          if (g.longitude < minLng) minLng = g.longitude;
          if (g.longitude > maxLng) maxLng = g.longitude;
        }
        geoBounds = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);
      }
      // previewPath is not present in file (skip)
      return TripSummary(
        id: id,
        name: name,
        startTime: startTime,
        endTime: endTime,
        totalDistanceMeters: totalDistanceMeters,
        movingTime: movingTime,
        previewPath: null,
        geoPoints: geoPoints,
        geoBounds: geoBounds,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<TripSummary>> loadSummaries() async {
    try {
      final dir = await _rootDir();
      final indexFile = await _indexFile();
      Map<String, TripSummary> indexMap = {};
      // 1. Load index.json if present
      if (await indexFile.exists()) {
        try {
          final raw = jsonDecode(await indexFile.readAsString());
          final list = (raw as List).cast<Map<String, dynamic>>();
          for (final e in list) {
            final summary = TripSummary.fromJson(e);
            indexMap[summary.id] = summary;
          }
        } catch (_) {}
      }
      // 2. List all trip files
      final files = await dir
          .list()
          .where((f) =>
              f is File &&
              f.path.endsWith('.json') &&
              !f.path.endsWith('/index.json'))
          .cast<File>()
          .toList();
      for (final f in files) {
        final fileSummary = await _readTripSummaryFromFile(f);
        if (fileSummary == null) {
          // 自動清除：無法解析的檔案會造成「實際有檔案，但列表為空」的狀況
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        final id = fileSummary.id;
        final indexSummary = indexMap[id];
        // 3. Merge: if not present in index, or index has missing geoPoints/geoBounds while file has them, use file
        bool shouldReplace = false;
        if (indexSummary == null) {
          shouldReplace = true;
        } else {
          if ((indexSummary.geoPoints == null ||
                  indexSummary.geoPoints!.isEmpty) &&
              fileSummary.geoPoints != null &&
              fileSummary.geoPoints!.isNotEmpty) {
            shouldReplace = true;
          }
          if ((indexSummary.geoBounds == null) &&
              fileSummary.geoBounds != null) {
            shouldReplace = true;
          }
        }
        if (shouldReplace) {
          // Only previewPath will remain null for fileSummary
          // Optionally, preserve previewPath from index if present
          final merged =
              (indexSummary != null && indexSummary.previewPath != null)
                  ? TripSummary(
                      id: fileSummary.id,
                      name: fileSummary.name,
                      startTime: fileSummary.startTime,
                      endTime: fileSummary.endTime,
                      totalDistanceMeters: fileSummary.totalDistanceMeters,
                      movingTime: fileSummary.movingTime,
                      previewPath: indexSummary.previewPath,
                      geoPoints: fileSummary.geoPoints,
                      geoBounds: fileSummary.geoBounds,
                    )
                  : fileSummary;
          indexMap[id] = merged;
        }
      }

      // 2b. 同步掃描舊版（documents 根目錄）trip_*.json
      final legacyDir = await _legacyRootDir();
      final legacyFiles = await legacyDir
          .list()
          .where((e) =>
              e is File &&
              e.path.endsWith('.json') &&
              e.uri.pathSegments.last.startsWith('trip_'))
          .cast<File>()
          .toList();

      for (final f in legacyFiles) {
        final legacy = await _readLegacyTripFile(f);
        if (legacy == null) {
          // 自動清除壞掉的舊格式檔案，避免影響「免費版僅能保存 1 筆」判斷
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        final id = legacy.id;
        final indexSummary = indexMap[id];
        bool shouldReplace = indexSummary == null;
        if (!shouldReplace && indexSummary != null) {
          if ((indexSummary.geoPoints == null ||
                  indexSummary.geoPoints!.isEmpty) &&
              (legacy.geoPoints != null && legacy.geoPoints!.isNotEmpty)) {
            shouldReplace = true;
          }
          if (indexSummary.geoBounds == null && legacy.geoBounds != null) {
            shouldReplace = true;
          }
        }
        if (shouldReplace) {
          indexMap[id] = legacy;
        }

        // 將舊檔轉存一份到 trips/{id}.json（不刪原檔）以利之後直接使用
        try {
          final tripsDir = await _rootDir();
          final out = File('${tripsDir.path}/$id.json');
          if (!await out.exists()) {
            await out.writeAsString(jsonEncode({
              'id': legacy.id,
              'name': legacy.name,
              if (legacy.geoPoints != null)
                'points': legacy.geoPoints!
                    .map((e) => [e.latitude, e.longitude])
                    .toList(),
              if (legacy.geoBounds != null)
                'bounds': {
                  'minLat': legacy.geoBounds!.bottom,
                  'minLng': legacy.geoBounds!.left,
                  'maxLat': legacy.geoBounds!.top,
                  'maxLng': legacy.geoBounds!.right,
                },
              'startTime': legacy.startTime.toIso8601String(),
              'endTime': legacy.endTime.toIso8601String(),
              'totalDistanceMeters': legacy.totalDistanceMeters,
              'movingTimeMs': legacy.movingTime.inMilliseconds,
            }));
          }
        } catch (_) {}
      }

      // 4. Save merged list to index.json (best effort)
      try {
        await _saveSummaries(indexMap.values.toList());
      } catch (_) {}
      // 5. Return merged list sorted by startTime desc
      final mergedList = indexMap.values.toList()
        ..sort((a, b) => b.startTime.compareTo(a.startTime));
      return mergedList;
    } catch (_) {
      return [];
    }
  }

  /// 回傳目前「有效可解析」的旅程數量（會自動清掉壞檔後再計數）
  Future<int> countValidTrips() async {
    final list = await loadSummaries();
    return list.length;
  }

  Future<void> _saveSummaries(List<TripSummary> items) async {
    final f = await _indexFile();
    final data = items.map((e) => e.toJson()).toList();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  Future<bool> deleteTrip(String id) async {
    try {
      // 1) 刪除新格式檔：trips/{id}.json
      final tripsDir = await _rootDir();
      final newFile = File('${tripsDir.path}/$id.json');
      if (await newFile.exists()) {
        await newFile.delete();
      }

      // 2) 刪除舊格式檔：documents 根目錄的 trip_*.json（與 id 相同名稱）
      //    舊檔若未刪除，loadSummaries() 會在下次開啟時重新掃描並「復原」這筆旅程。
      try {
        final legacyDir = await _legacyRootDir();
        final legacyFile = File('${legacyDir.path}/$id.json');
        if (await legacyFile.exists()) {
          await legacyFile.delete();
        }
      } catch (_) {
        // best effort
      }

      // 3) 更新 index.json（移除該 id）
      final summaries = await loadSummaries();
      final after = summaries.where((e) => e.id != id).toList();
      await _saveSummaries(after);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 產生範例資料，方便開發測試
  Future<void> seedDemo(int count) async {
    final dir = await _rootDir();
    final now = DateTime.now();
    final List<TripSummary> summaries = [];
    for (int i = 0; i < count; i++) {
      final id = 'demo_${now.millisecondsSinceEpoch}_$i';
      final start = now.subtract(Duration(days: i + 1, hours: 1 + i));
      final end = start.add(Duration(minutes: 30 + i * 5));
      final distance = 3000 + i * 1200 + (i.isEven ? 750 : 420);
      final moving = Duration(minutes: 20 + i * 3, seconds: i * 7);

      // 產生一條 0~1 歸一化的折線作為縮圖路徑
      final List<Offset> preview = [];
      final points = 18 + i * 2;
      for (int p = 0; p < points; p++) {
        final t = p / (points - 1);
        final x = t;
        final y = 0.5 + 0.35 * math.sin(2 * math.pi * (t + i * 0.13));
        preview.add(Offset(x, y.clamp(0.0, 1.0)));
      }

      // 以南投為中心，將 0~1 的 previewPath 映射到經緯度（約 1km 規模）
      final center = ll.LatLng(23.9600 + i * 0.001, 120.9700 + i * 0.001);
      const dLat = 0.01; // 約 1.1km
      const dLng = 0.01; // 約 1.0km（於台灣緯度）
      final geoPoints = preview
          .map((o) => ll.LatLng(
                center.latitude + (o.dy - 0.5) * dLat,
                center.longitude + (o.dx - 0.5) * dLng,
              ))
          .toList();
      double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
      for (final g in geoPoints) {
        if (g.latitude < minLat) minLat = g.latitude;
        if (g.latitude > maxLat) maxLat = g.latitude;
        if (g.longitude < minLng) minLng = g.longitude;
        if (g.longitude > maxLng) maxLng = g.longitude;
      }
      final boundsRect = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);

      final summary = TripSummary(
        id: id,
        name: '範例旅程 #${i + 1}',
        startTime: start,
        endTime: end,
        totalDistanceMeters: distance.toDouble(),
        movingTime: moving,
        previewPath: preview,
        geoPoints: geoPoints,
        geoBounds: boundsRect,
      );
      summaries.add(summary);

      final fullFile = File('${dir.path}/$id.json');
      await fullFile.writeAsString(jsonEncode({
        'id': id,
        'name': summary.name,
        'points': geoPoints.map((e) => [e.latitude, e.longitude]).toList(),
        'bounds': {
          'minLat': boundsRect.bottom,
          'minLng': boundsRect.left,
          'maxLat': boundsRect.top,
          'maxLng': boundsRect.right,
        }
      }));
    }

    // 讀取舊的 summaries 並合併（避免覆蓋使用者資料）
    final existing = await loadSummaries();
    final merged = [...summaries, ...existing];
    await _saveSummaries(merged);
  }

  /// 建立一筆指定的測試旅程（含經緯度軌跡與 bounds，用於縮圖測試）
  Future<void> seedOneTestAddressTrip() async {
    final dir = await _rootDir();
    final now = DateTime.now();
    final id = 'demo_addr_${now.millisecondsSinceEpoch}';

    // 模擬一條從左下到右上的路徑（V 字緩弧），只做預覽縮圖
    final List<Offset> preview = [];
    const points = 24;
    for (int p = 0; p < points; p++) {
      final t = p / (points - 1);
      final x = t;
      final y = 0.65 - 0.45 * math.sin(t * math.pi); // 漂亮一點的路徑
      preview.add(Offset(x, y));
    }

    // 大約經緯度（永靖鄉永興路三段 56 號 → 270 號，手動估略值，僅供縮圖測試）
    final startLL = ll.LatLng(23.9186, 120.5408);
    final endLL = ll.LatLng(23.9192, 120.5470);

    // 線性插值出一條平滑折線（含起終點）
    const segs = 20;
    final List<ll.LatLng> geoPoints = List.generate(segs, (i) {
      final t = i / (segs - 1);
      final lat = startLL.latitude + (endLL.latitude - startLL.latitude) * t;
      final lng = startLL.longitude + (endLL.longitude - startLL.longitude) * t;
      return ll.LatLng(lat, lng);
    });

    // 計算 bounds（left=minLng, top=maxLat, right=maxLng, bottom=minLat）
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final g in geoPoints) {
      if (g.latitude < minLat) minLat = g.latitude;
      if (g.latitude > maxLat) maxLat = g.latitude;
      if (g.longitude < minLng) minLng = g.longitude;
      if (g.longitude > maxLng) maxLng = g.longitude;
    }
    final boundsRect = Rect.fromLTRB(minLng, maxLat, maxLng, minLat);

    final summary = TripSummary(
      id: id,
      name: '永靖鄉永興路三段56號 → 270號',
      startTime: now.subtract(const Duration(minutes: 15)),
      endTime: now,
      totalDistanceMeters: 1100, // 大約 1.1 km（示意）
      movingTime: const Duration(minutes: 8, seconds: 20),
      previewPath: preview,
      geoPoints: geoPoints,
      geoBounds: boundsRect,
    );

    // 更新 index.json
    final current = await loadSummaries();
    current.insert(0, summary);
    await _saveSummaries(current);

    // 也建立對應的內容檔（寫 points/bounds for Apple Map 縮圖）
    final fullFile = File('${dir.path}/$id.json');
    await fullFile.writeAsString(jsonEncode({
      'id': id,
      'name': summary.name,
      'points': geoPoints.map((e) => [e.latitude, e.longitude]).toList(),
      'bounds': {
        'minLat': boundsRect.bottom,
        'minLng': boundsRect.left,
        'maxLat': boundsRect.top,
        'maxLng': boundsRect.right,
      }
    }));
  }
}

/// 旅程列表頁主要內容（供 TripsListPage 使用）
class TripsListBody extends StatefulWidget {
  const TripsListBody({super.key});

  @override
  State<TripsListBody> createState() => _TripsListBodyState();
}

enum SelectionAction { stats, export, delete }

class _TripsListBodyState extends State<TripsListBody> {
  final List<TripSummary> _items = [];
  bool _loading = true;
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';
  final List<TripSummary> _all = [];
  bool _selectMode = false; // 是否進入統計選取模式
  SelectionAction _selectionAction = SelectionAction.stats; // 當前選取模式要做的事
  final Set<String> _selectedIds = {}; // 已選旅程 id 清單
  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selectionAction = SelectionAction.stats;
      if (!_selectMode) _selectedIds.clear();
    });
  }

  void _enterExportMode() {
    setState(() {
      _selectMode = true;
      _selectionAction = SelectionAction.export;
      _selectedIds.clear();
    });
  }

  void _enterDeleteMode() {
    setState(() {
      _selectMode = true;
      _selectionAction = SelectionAction.delete;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(L10n.t('please_select_items'))),
      );
      return;
    }
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(L10n.t('trip_delete_title')),
            content: Text(
              L10n.t('delete_selected_confirm',
                  params: {'count': count.toString()}),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(L10n.t('cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(L10n.t('delete')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    int ok = 0;
    for (final id in _selectedIds.toList()) {
      final success = await TripStore.instance.deleteTrip(id);
      if (success) ok++;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _selectionAction = SelectionAction.stats;
      _selectedIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 500),
        content: Text(
          L10n.t('delete_done', params: {'count': ok.toString()}),
        ),
      ),
    );
  }

  Future<void> _exportSelected() async {
    Future<void> _deleteSelected() async {
      if (_selectedIds.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              duration: const Duration(milliseconds: 500),
              content: Text(L10n.t('please_select_items'))),
        );
        return;
      }
      final count = _selectedIds.length;
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(L10n.t('trip_delete_title')),
              content: Text(L10n.t('delete_selected_confirm',
                  params: {'count': count.toString()})),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(L10n.t('cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(L10n.t('delete')),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) return;

      int ok = 0;
      for (final id in _selectedIds.toList()) {
        final success = await TripStore.instance.deleteTrip(id);
        if (success) ok++;
      }
      await _load();
      if (!mounted) return;
      setState(() {
        _selectMode = false;
        _selectionAction = SelectionAction.stats;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content:
                Text(L10n.t('delete_done', params: {'count': ok.toString()}))),
      );
    }

    if (_selectedIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(L10n.t('please_select_items'))),
      );
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final tripsDir = Directory('${docs.path}/trips');

      final List<XFile> files = [];

      for (final id in _selectedIds) {
        Map<String, dynamic>? one;

        // 先找新格式 trips/{id}.json
        final nf = File('${tripsDir.path}/$id.json');
        if (await nf.exists()) {
          try {
            one = (jsonDecode(await nf.readAsString()) as Map)
                .cast<String, dynamic>();
          } catch (_) {}
        }

        // 舊格式備援（documents 根目錄）
        if (one == null) {
          final of = File('${docs.path}/$id.json');
          if (await of.exists()) {
            try {
              one = (jsonDecode(await of.readAsString()) as Map)
                  .cast<String, dynamic>();
            } catch (_) {}
          }
        }

        // 仍無法讀出，就輸出摘要
        if (one == null) {
          final t = _all.firstWhere(
            (e) => e.id == id,
            orElse: () => TripSummary(
              id: id,
              name: 'Trip',
              startTime: DateTime.now(),
              endTime: DateTime.now(),
              totalDistanceMeters: 0,
              movingTime: Duration.zero,
            ),
          );
          one = t.toJson();
        }

        // 寫到暫存檔，檔名直接使用 {id}.json
        final tmp = await getTemporaryDirectory();
        final out = File('${tmp.path}/$id.json');
        await out.writeAsString(
          const JsonEncoder.withIndent('  ').convert(one),
        );
        files.add(
            XFile(out.path, mimeType: 'application/json', name: '$id.json'));
      }

      // 以多檔案方式分享（share_plus 支援多檔）
      await Share.shareXFiles(files);
      if (!mounted) return;
      setState(() {
        _selectMode = false;
        _selectionAction = SelectionAction.stats;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 500),
          content: Text(
            L10n.t('export_done', params: {'count': files.length.toString()}),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _importOneJson(Map<String, dynamic> json,
      {String? preferId}) async {
    // points
    List<List<num>>? points;
    if (json['points'] is List) {
      try {
        points = (json['points'] as List)
            .map((e) => (e as List).cast<num>())
            .toList();
      } catch (_) {}
    }
    // bounds
    Map<String, num>? bounds = (json['bounds'] is Map)
        ? (json['bounds'] as Map).cast<String, num>()
        : null;
    if (bounds == null && points != null && points.isNotEmpty) {
      double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
      for (final p in points) {
        final lat = p[0].toDouble();
        final lng = p[1].toDouble();
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lng < minLng) minLng = lng;
        if (lng > maxLng) maxLng = lng;
      }
      bounds = {
        'minLat': minLat,
        'minLng': minLng,
        'maxLat': maxLat,
        'maxLng': maxLng,
      };
    }

    // samples 正規化
    List<Map<String, dynamic>>? samples;
    if (json['samples'] is List) {
      samples = [];
      for (final s in (json['samples'] as List)) {
        if (s is Map) {
          final ts = (s['ts'] ?? s['time'] ?? s['timestamp'])?.toString();
          final lat = (s['lat'] as num?)?.toDouble();
          final lon = (s['lon'] as num?)?.toDouble();
          final alt = (s['alt'] as num?)?.toDouble();
          final spd = (s['speedMps'] as num?)?.toDouble();
          if (lat != null && lon != null) {
            samples.add({
              if (ts != null) 'ts': ts,
              'lat': lat,
              'lon': lon,
              if (alt != null) 'alt': alt,
              if (spd != null) 'speedMps': spd,
            });
          }
        }
      }
    }
    if (points == null && samples != null && samples.isNotEmpty) {
      points =
          samples.map((m) => [m['lat'] as double, m['lon'] as double]).toList();
    }

    final startIso = (json['startTime'] ?? json['startAt'])?.toString();
    final endIso = (json['endTime'] ?? json['endAt'])?.toString();
    final totalDist =
        (json['totalDistanceMeters'] ?? json['distanceMeters']) as num?;
    final movingMs = (json['movingTimeMs'] ??
        (json['movingSeconds'] is num
            ? (json['movingSeconds'] as num) * 1000
            : null)) as num?;

    final now = DateTime.now();
    final id = (preferId?.trim().isNotEmpty == true)
        ? preferId!.trim()
        : ((json['id'] as String?)?.trim().isNotEmpty == true
            ? (json['id'] as String)
            : 'import_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}');

    final unified = {
      'id': id,
      'name': (json['name'] as String?) ?? '未命名旅程',
      if (points != null) 'points': points,
      if (bounds != null) 'bounds': bounds,
      'startTime': (startIso ?? now.toIso8601String()).toString(),
      'endTime': (endIso ?? now.toIso8601String()).toString(),
      if (totalDist != null) 'totalDistanceMeters': totalDist.toDouble(),
      if (movingMs != null) 'movingTimeMs': movingMs.toInt(),
      if (startIso != null) 'startAt': startIso,
      if (endIso != null) 'endAt': endIso,
      if (json['distanceMeters'] != null)
        'distanceMeters': (json['distanceMeters'] as num).toDouble(),
      if (json['movingSeconds'] != null)
        'movingSeconds': (json['movingSeconds'] as num).toInt(),
      if (samples != null) 'samples': samples,
      if (json['ts'] is List)
        'ts': (json['ts'] as List).map((e) => e.toString()).toList(),
      if (json['lat'] is List)
        'lat': (json['lat'] as List).map((e) => (e as num).toDouble()).toList(),
      if (json['lon'] is List)
        'lon': (json['lon'] as List).map((e) => (e as num).toDouble()).toList(),
      if (json['alt'] is List)
        'alt': (json['alt'] as List).map((e) => (e as num).toDouble()).toList(),
      if (json['speedMps'] is List)
        'speedMps': (json['speedMps'] as List)
            .map((e) => (e as num).toDouble())
            .toList(),
      if (json['avgSpeedMps'] is num)
        'avgSpeedMps': (json['avgSpeedMps'] as num).toDouble(),
      if (json['maxSpeedMps'] is num)
        'maxSpeedMps': (json['maxSpeedMps'] as num).toDouble(),
      if (json['preferredUnit'] is String)
        'preferredUnit': json['preferredUnit'],
      if (json['weatherProvider'] is String)
        'weatherProvider': json['weatherProvider'],
      if (json['weatherTempC'] is num)
        'weatherTempC': (json['weatherTempC'] as num).toDouble(),
      if (json['weatherAt'] != null) 'weatherAt': json['weatherAt'].toString(),
      if (json['weatherLat'] is num)
        'weatherLat': (json['weatherLat'] as num).toDouble(),
      if (json['weatherLon'] is num)
        'weatherLon': (json['weatherLon'] as num).toDouble(),
    };

    final dir = await TripStore.instance._rootDir();
    final out = File('${dir.path}/$id.json');
    await out
        .writeAsString(const JsonEncoder.withIndent('  ').convert(unified));
  }

  void _toggleOne(String id, bool? v) {
    setState(() {
      if (v == true || (_selectMode && !_selectedIds.contains(id))) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(_items.map((e) => e.id));
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  Future<void> _computeStatsForSelected() async {
    if (_selectedIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(L10n.t('please_select_items'))),
      );
      return;
    }
    // 彙總距離與移動時間 + 準備圖表資料
    double totalMeters = 0;
    Duration totalMoving = Duration.zero;
    final distances = <double>[];
    final starts = <DateTime>[];

    for (final t in _all) {
      if (_selectedIds.contains(t.id)) {
        totalMeters += t.totalDistanceMeters;
        totalMoving += t.movingTime;
        distances.add(t.totalDistanceMeters);
        starts.add(t.startTime);
      }
    }

    // 讀取各旅程最高速（若檔案中有 maxSpeedMps 或 samples.speedMps）
    double maxSpeedKmh = 0;
    for (final id in _selectedIds) {
      final v = await TripStore.instance.loadMaxSpeedKmh(id);
      if (v != null && v > maxSpeedKmh) maxSpeedKmh = v;
    }

    final avgKmh = (totalMoving.inSeconds > 0)
        ? (totalMeters / totalMoving.inSeconds) * 3.6
        : 0.0;

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TotalStatsPage(
          count: _selectedIds.length,
          totalMeters: totalMeters,
          totalMoving: totalMoving,
          maxSpeedKmh: maxSpeedKmh,
          avgSpeedKmh: avgKmh,
          distancesMeters: distances,
          tripStartDates: starts,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _importTrip() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null || picked.files.isEmpty) return;

      int okCount = 0;
      int failCount = 0;

      for (final f in picked.files) {
        final path = f.path;
        if (path == null) {
          failCount++;
          continue;
        }
        final src = File(path);
        if (!await src.exists()) {
          failCount++;
          continue;
        }

        Map<String, dynamic>? json;
        try {
          json = jsonDecode(await src.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          json = null;
        }

        if (json == null) {
          // 不是可解析的 JSON → 視為不合規，直接記為失敗，不複製到資料夾，避免造成列表顯示不到但檔案佔位
          failCount++;
          continue;
        }

        // 若為打包檔（過去的匯出格式），展開其中每一筆再走統一匯入流程
        if (json['trips'] is List) {
          final list = (json['trips'] as List).cast<Map>();
          for (final e in list) {
            try {
              final data = (e['data'] as Map).cast<String, dynamic>();
              final idFromBundle = (e['id'] as String?)?.trim();
              // 先寫入
              await _importOneJson(data, preferId: idFromBundle);
              // 驗證新檔是否可被列表解析，否則自動刪除
              try {
                final dir = await TripStore.instance._rootDir();
                final String? preferId = (idFromBundle?.isNotEmpty == true)
                    ? idFromBundle!
                    : ((data['id'] as String?)?.trim().isNotEmpty == true
                        ? (data['id'] as String).trim()
                        : null);
                File? target;
                if (preferId != null) {
                  final f = File('${dir.path}/$preferId.json');
                  if (await f.exists()) target = f;
                }
                target ??= (await dir
                        .list()
                        .where((e) => e is File && e.path.endsWith('.json'))
                        .cast<File>()
                        .toList())
                    .fold<File?>(null, (File? best, File f) {
                  if (best == null) return f;
                  return f.statSync().modified.isAfter(best.statSync().modified)
                      ? f
                      : best;
                });
                if (target != null) {
                  final ok =
                      await TripStore.instance._readTripSummaryFromFile(target);
                  if (ok == null) {
                    try {
                      await target.delete();
                    } catch (_) {}
                    failCount++;
                  } else {
                    okCount++;
                  }
                } else {
                  failCount++;
                }
              } catch (_) {
                failCount++;
              }
            } catch (_) {
              failCount++;
            }
          }
          // 處理完這個打包檔後，繼續下一個使用者選擇的檔案
          continue;
        }

        try {
          // 先寫入
          await _importOneJson(json);
          // 驗證新檔是否可被列表解析，否則自動刪除
          try {
            final dir = await TripStore.instance._rootDir();
            final String? preferId =
                (json['id'] as String?)?.trim().isNotEmpty == true
                    ? (json['id'] as String).trim()
                    : null;
            // 建立實際檔名：若 json 沒 id，_importOneJson 會用 import_yyyyMMdd_HHmmss
            // 因此掃描最新檔或用 preferId 嘗試讀取
            File? target;
            if (preferId != null) {
              final f = File('${dir.path}/$preferId.json');
              if (await f.exists()) target = f;
            }
            target ??= (await dir
                    .list()
                    .where((e) => e is File && e.path.endsWith('.json'))
                    .cast<File>()
                    .toList())
                .fold<File?>(null, (File? best, File f) {
              if (best == null) return f;
              return f.statSync().modified.isAfter(best.statSync().modified)
                  ? f
                  : best;
            });
            if (target != null) {
              final ok =
                  await TripStore.instance._readTripSummaryFromFile(target);
              if (ok == null) {
                try {
                  await target.delete();
                } catch (_) {}
                failCount++;
              } else {
                okCount++;
              }
            } else {
              failCount++;
            }
          } catch (_) {
            failCount++;
          }
        } catch (_) {
          failCount++;
        }
      }

      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(
                '${L10n.t('import_done')} ($okCount ok, $failCount failed)')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: const Duration(milliseconds: 500),
            content:
                Text(L10n.t('import_failed', params: {'error': e.toString()}))),
      );
    }
  }

  Future<void> _refresh() async {
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    final data = await TripStore.instance.loadSummaries();
    if (!mounted) return;
    setState(() {
      _all
        ..clear()
        ..addAll(data);
      _loading = false;
    });
    _applyFilter();
  }

  void _applyFilter() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        _items
          ..clear()
          ..addAll(_all);
      });
      return;
    }

    bool match(TripSummary t) {
      // by name
      if (t.name.toLowerCase().contains(q)) return true;
      // by date string like 2025/08/24 or time 01:12
      String two(int v) => v.toString().padLeft(2, '0');
      final d =
          '${t.startTime.year}/${two(t.startTime.month)}/${two(t.startTime.day)}';
      final t1 = '${two(t.startTime.hour)}:${two(t.startTime.minute)}';
      final t2 = '${two(t.endTime.hour)}:${two(t.endTime.minute)}';
      final range = '$d $t1–$t2';
      if (d.contains(q) ||
          t1.contains(q) ||
          t2.contains(q) ||
          range.contains(q)) return true;
      // by distance (km text)
      final km = (t.totalDistanceMeters / 1000).toStringAsFixed(2);
      if (km.contains(q)) return true;
      return false;
    }

    final filtered = _all.where(match).toList();
    setState(() {
      _items
        ..clear()
        ..addAll(filtered);
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  String _fmtDateRange(DateTime a, DateTime b) {
    final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
    String two(int v) => v.toString().padLeft(2, '0');
    final d = '${a.year}/${two(a.month)}/${two(a.day)}';
    final t1 = '${two(a.hour)}:${two(a.minute)}';
    final t2 = '${two(b.hour)}:${two(b.minute)}';
    return sameDay
        ? '$d  $t1–$t2'
        : '${d} ${t1} → ${b.year}/${two(b.month)}/${two(b.day)} ${t2}';
  }

  String _fmtDistance(double m) {
    if (m >= 1000) {
      return (m / 1000).toStringAsFixed(2) + ' km';
    }
    return m.toStringAsFixed(0) + ' m';
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // 工具列 → 改為 AppBar 風格的右上角動作按鈕（僅圖示）
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip:
                      L10n.t(_selectMode ? 'stats_cancel' : 'stats_select'),
                  onPressed: _toggleSelectMode,
                  icon: Icon(_selectMode ? Icons.close : Icons.query_stats),
                  visualDensity: VisualDensity.compact,
                  style: ButtonStyle(
                    iconColor: WidgetStatePropertyAll(
                      Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                if (_selectMode)
                  IconButton(
                    tooltip: L10n.t('select_all'),
                    onPressed: _selectAllVisible,
                    icon: const Icon(Icons.select_all),
                    visualDensity: VisualDensity.compact,
                    style: ButtonStyle(
                      iconColor: WidgetStatePropertyAll(
                        Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: L10n.t('export'), //匯出按鈕
                  onPressed: _enterExportMode,
                  icon: const Icon(Icons.ios_share),
                  visualDensity: VisualDensity.compact,
                  style: ButtonStyle(
                    iconColor: WidgetStatePropertyAll(
                      Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: L10n.t('import'),
                  onPressed: _importTrip,
                  icon: const Icon(Icons.file_download_sharp),
                  visualDensity: VisualDensity.compact,
                  style: ButtonStyle(
                    // 讓圖示與 AppBar action 視覺一致：無底色、用 onSurface 顏色
                    iconColor: WidgetStatePropertyAll(
                      Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: L10n.t('delete'),
                  onPressed: _enterDeleteMode,
                  icon: const Icon(Icons.delete_outline),
                  visualDensity: VisualDensity.compact,
                  style: const ButtonStyle(
                    iconColor: WidgetStatePropertyAll(Colors.red),
                  ),
                ),
              ],
            ),
          ),
          // 搜尋框
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtl,
              onChanged: (v) {
                _query = v;
                _applyFilter();
              },
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              cursorColor: Colors.white70,
              decoration: InputDecoration(
                hintText: L10n.t('trips_search_hint'),
                hintStyle: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6)),
                prefixIcon: Icon(Icons.search,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.7)),
                filled: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .surfaceVariant
                    .withOpacity(0.6),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 1.2),
                ),
                suffixIcon: (_query.isEmpty)
                    ? null
                    : IconButton(
                        icon: Icon(Icons.clear,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.7)),
                        onPressed: () {
                          _searchCtl.clear();
                          _query = '';
                          _applyFilter();
                        },
                      ),
              ),
            ),
          ),
          if (_selectMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: _clearSelection,
                    child: Text(L10n.t('clear')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _selectionAction == SelectionAction.stats
                          ? _computeStatsForSelected
                          : _selectionAction == SelectionAction.export
                              ? _exportSelected
                              : _deleteSelected,
                      icon: Icon(
                        _selectionAction == SelectionAction.stats
                            ? Icons.bar_chart
                            : _selectionAction == SelectionAction.export
                                ? Icons.ios_share
                                : Icons.delete_outline,
                      ),
                      label: Text(
                        _selectionAction == SelectionAction.stats
                            ? L10n.t('stats_confirm')
                            : _selectionAction == SelectionAction.export
                                ? L10n.t('export')
                                : L10n.t('delete'),
                      ),
                      style: _selectionAction == SelectionAction.delete
                          ? ButtonStyle(
                              backgroundColor: WidgetStatePropertyAll(
                                  Theme.of(context).colorScheme.error),
                              foregroundColor: WidgetStatePropertyAll(
                                  Theme.of(context).colorScheme.onError),
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _items.isEmpty ? 1 : _items.length,
                      itemBuilder: (context, index) {
                        if (_items.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 100),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Center(
                                  child: Text(
                                    L10n.t('trips_empty'),
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withOpacity(0.7)),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    _searchCtl.clear();
                                    _query = '';
                                    _applyFilter();
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: Text(L10n.t('clear_search')),
                                ),
                              ],
                            ),
                          );
                        }
                        final t = _items[index];
                        return _TripListTile(
                          key: ValueKey('trip-${t.id}'),
                          summary: t,
                          onDelete: () async {
                            final removed = t;
                            setState(() {
                              _items.removeAt(index);
                              _all.removeWhere((e) => e.id == removed.id);
                            });
                            final ok =
                                await TripStore.instance.deleteTrip(removed.id);
                            if (!context.mounted) return;
                            if (ok) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    duration: const Duration(milliseconds: 500),
                                    content: Text(L10n.t('trip_deleted'))),
                              );
                            } else {
                              setState(() {
                                _all.add(removed);
                                _applyFilter();
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    duration: const Duration(milliseconds: 500),
                                    content: Text(L10n.t('delete_failed'))),
                              );
                            }
                          },
                          fmtDateRange: _fmtDateRange,
                          fmtDistance: _fmtDistance,
                          fmtDuration: _fmtDuration,
                          onUpdated: () {
                            _load();
                          },
                          selectionMode: _selectMode,
                          selected: _selectedIds.contains(t.id),
                          onToggleSelected: (v) => _toggleOne(t.id, v),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripListTile extends StatelessWidget {
  final TripSummary summary;
  final VoidCallback onDelete;
  final String Function(DateTime, DateTime) fmtDateRange;
  final String Function(double) fmtDistance;
  final String Function(Duration) fmtDuration;
  final VoidCallback? onUpdated; // ← 新增：返回詳情頁後通知父層刷新
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool?> onToggleSelected;

  const _TripListTile({
    super.key,
    required this.summary,
    required this.onDelete,
    required this.fmtDateRange,
    required this.fmtDistance,
    required this.fmtDuration,
    this.onUpdated,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Dismissible(
        key: ValueKey('dismiss-${summary.id}'),
        direction:
            selectionMode ? DismissDirection.none : DismissDirection.endToStart,
        confirmDismiss: (direction) async {
          return await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(L10n.t('trip_delete_title')),
                  content: Text(L10n.t('trip_delete_confirm',
                      params: {'name': summary.name})),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(L10n.t('cancel')),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(L10n.t('delete')),
                    ),
                  ],
                ),
              ) ??
              false;
        },
        onDismissed: (_) => onDelete(),
        background: selectionMode
            ? const SizedBox.shrink()
            : Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.red.shade700,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 6, top: 28),
                child: Checkbox(
                  shape: const CircleBorder(),
                  value: selected,
                  onChanged: onToggleSelected,
                ),
              ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  if (selectionMode) {
                    onToggleSelected(!selected);
                    return;
                  }
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TripDetailPage(summary: summary),
                    ),
                  );
                  onUpdated?.call();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      // 左側縮圖
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 70,
                            height: 70,
                            color: Colors.black,
                            child: MapOrPreviewThumbnail(summary: summary),
                          ),
                        ),
                      ),
                      // 右側文字
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 10, horizontal: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                summary.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                fmtDateRange(
                                    summary.startTime, summary.endTime),
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withOpacity(0.7),
                                    fontSize: 12),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  _ChipText(
                                      label: L10n.t('distance'),
                                      value: fmtDistance(
                                          summary.totalDistanceMeters)),
                                  _ChipText(
                                      label: L10n.t('moving'),
                                      value: fmtDuration(summary.movingTime)),
                                ],
                              ),
                            ],
                          ),
                        ),
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

class _ChipText extends StatelessWidget {
  final String label;
  final String value;
  const _ChipText({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text('$label：$value',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface, fontSize: 12)),
    );
  }
}

class MapOrPreviewThumbnail extends StatelessWidget {
  final TripSummary summary;
  const MapOrPreviewThumbnail({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final hasGeo = summary.geoPoints != null && summary.geoPoints!.length >= 2;
    if (!hasGeo) {
      return CustomPaint(painter: _PathThumbnailPainter(summary.previewPath));
    }
    final pts = summary.geoPoints!;
    // 在 iOS 上優先使用 Apple Map 快照，避免在列表中執行多個地圖 view
    if (!kIsWeb && Platform.isIOS) {
      return AppleMapSnapshotThumb(points: pts, width: 70, height: 70);
    }
    final center = pts[pts.length ~/ 2];
    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: 14,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.app',
        ),
        PolylineLayer(polylines: [
          Polyline(points: pts, strokeWidth: 3, color: Colors.red),
        ]),
        MarkerLayer(markers: [
          Marker(
            point: pts.first,
            width: 10,
            height: 10,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.greenAccent,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Marker(
            point: pts.last,
            width: 10,
            height: 10,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.redAccent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ]),
      ],
    );
  }
}

class AppleMapSnapshotThumb extends StatefulWidget {
  final List<ll.LatLng> points;
  final double width;
  final double height;
  final Color polylineColor;
  const AppleMapSnapshotThumb(
      {super.key,
      required this.points,
      required this.width,
      required this.height,
      this.polylineColor = Colors.red});

  @override
  State<AppleMapSnapshotThumb> createState() => _AppleMapSnapshotThumbState();
}

class _AppleMapSnapshotThumbState extends State<AppleMapSnapshotThumb> {
  double? _scale;
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = MediaQuery.of(context).devicePixelRatio;
    if (_scale != s) {
      _scale = s;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      const channel = MethodChannel('trip_thumb');
      final pts = widget.points.map((e) => [e.latitude, e.longitude]).toList();
      final res = await channel.invokeMethod<List<int>>('snapshot', {
        'points': pts,
        'width': widget.width,
        'height': widget.height,
        'scale': _scale ?? 2.0,
        'strokeColor': widget.polylineColor.value,
        'strokeWidth': 3.0,
      });
      if (!mounted) return;
      if (res != null) setState(() => _bytes = Uint8List.fromList(res));
    } catch (e) {
      // 將錯誤輸出到主控台，方便定位（例如 channel 未註冊、iOS 端拋錯等）
      debugPrint('AppleMapSnapshotThumb error: $e');
      // 保持為 null，讓外層顯示預設底色
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return ColoredBox(color: Theme.of(context).colorScheme.surfaceVariant);
    }
    return Image.memory(
      _bytes!,
      width: widget.width,
      height: widget.height,
      fit: BoxFit.cover,
    );
  }
}

class _PathThumbnailPainter extends CustomPainter {
  final List<Offset>? path;
  _PathThumbnailPainter(this.path);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF0F0F0F);
    canvas.drawRect(Offset.zero & size, bg);

    if (path == null || path!.length < 2) {
      final p = Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)), p);
      final icon = Paint()..color = Colors.white30;
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), 6, icon);
      return;
    }

    final stroke = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final pad = 6.0;
    final pathScaled = Path();
    for (int i = 0; i < path!.length; i++) {
      final o = path![i];
      final dx = pad + o.dx.clamp(0.0, 1.0) * (size.width - pad * 2);
      final dy = pad + (1 - o.dy.clamp(0.0, 1.0)) * (size.height - pad * 2);
      if (i == 0) {
        pathScaled.moveTo(dx, dy);
      } else {
        pathScaled.lineTo(dx, dy);
      }
    }
    canvas.drawPath(pathScaled, stroke);

    // 起終點
    final start = path!.first;
    final end = path!.last;
    final s = Offset(
      pad + start.dx.clamp(0.0, 1.0) * (size.width - pad * 2),
      pad + (1 - start.dy.clamp(0.0, 1.0)) * (size.height - pad * 2),
    );
    final e = Offset(
      pad + end.dx.clamp(0.0, 1.0) * (size.width - pad * 2),
      pad + (1 - end.dy.clamp(0.0, 1.0)) * (size.height - pad * 2),
    );
    canvas.drawCircle(s, 3, Paint()..color = Colors.greenAccent);
    canvas.drawCircle(e, 3, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(covariant _PathThumbnailPainter oldDelegate) =>
      oldDelegate.path != path;
}
