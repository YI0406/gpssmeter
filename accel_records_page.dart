import 'dart:async';
import 'package:flutter/material.dart';
import 'accel_page.dart'; // 引用 AccelStore / AccelRecord / AccelModeLabel
import 'package:gps_speedometer_min/setting.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

class AccelRecordsPage extends StatefulWidget {
  const AccelRecordsPage({super.key});

  @override
  State<AccelRecordsPage> createState() => _AccelRecordsPageState();
}

class _AccelRecordsPageState extends State<AccelRecordsPage> {
  List<AccelRecord> _all = [];
  String _q = '';
  bool _loading = true;

  bool _selectMode = false; // 是否為選擇模式
  final Set<String> _selectedIds = <String>{};
  bool _showDeleteFab = false; // 顯示底部刪除 FAB
  bool _showExportFab = false; // 顯示底部匯出 FAB
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AccelStore.load();
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    setState(() {
      _all = list;
      _loading = false;
    });
  }

  Future<void> _rename(AccelRecord r) async {
    final ctrl = TextEditingController(text: r.name);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(L10n.t('rename_record')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.t('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text(L10n.t('confirm'))),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      await AccelStore.rename(r.id, v);
      await _load();
    }
  }

  Future<void> _delete(AccelRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(L10n.t('delete_record')),
        content: Text(L10n.t('confirm_delete_name').replaceFirst('%s', r.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(L10n.t('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(L10n.t('delete'))),
        ],
      ),
    );
    if (ok == true) {
      await AccelStore.delete(r.id);
      await _load();
    }
  }

  Future<void> _deleteGroup(String dateKey, List<AccelRecord> items) async {
    // 已在 confirmDismiss 確認；這裡直接刪除同一天的所有紀錄
    final all = await AccelStore.load();
    final targets = all.where((r) {
      final key =
          '${r.startedAt.year}-${r.startedAt.month.toString().padLeft(2, '0')}-${r.startedAt.day.toString().padLeft(2, '0')}';
      return key == dateKey;
    }).toList(growable: false);
    for (final r in targets) {
      await AccelStore.delete(r.id);
    }
    await _load();
  }

  void _removeGroupFromView(String dateKey) {
    setState(() {
      _all = _all.where((r) {
        final key =
            '${r.startedAt.year}-${r.startedAt.month.toString().padLeft(2, '0')}-${r.startedAt.day.toString().padLeft(2, '0')}';
        return key != dateKey;
      }).toList();
    });
  }

  Future<void> _exportJson(List<AccelRecord> records,
      {String suffix = ''}) async {
    try {
      final now = DateTime.now();
      final ts = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';

      final dir = await getApplicationDocumentsDirectory();

      // Flatten a record into portable JSON
      Map<String, dynamic> flat(AccelRecord r) => {
            'id': r.id,
            'startedAtEpochMs': r.startedAt.millisecondsSinceEpoch,
            'date':
                '${r.startedAt.year}-${r.startedAt.month.toString().padLeft(2, '0')}-${r.startedAt.day.toString().padLeft(2, '0')}',
            'time':
                '${r.startedAt.hour.toString().padLeft(2, '0')}:${r.startedAt.minute.toString().padLeft(2, '0')}:${r.startedAt.second.toString().padLeft(2, '0')}',
            'mode': r.mode.title,
            'name': r.name,
            'elapsedMs': r.elapsedMs,
            'endSpeedKmh': r.endSpeedKmh,
            'useMph': r.useMph,
          };

      final List<XFile> toShare = [];

      if (records.length > 1) {
        // one file per record
        for (final r in records) {
          final file = File('${dir.path}/accel_${r.id}.json');
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert([flat(r)]),
            flush: true,
          );
          toShare.add(XFile(file.path));
        }
      } else if (records.length == 1) {
        // single selection: one file with a single-element array (keeps previous viewer-friendly format)
        final file = File(
            '${dir.path}/accel${suffix.isNotEmpty ? '_$suffix' : ''}_$ts.json');
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert([flat(records.first)]),
          flush: true,
        );
        toShare.add(XFile(file.path));
      } else {
        // nothing to export
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                duration: Duration(milliseconds: 500),
                content: Text(L10n.t('select_something_first'))),
          );
        }
        return;
      }

      // share (no extra text)
      await Share.shareXFiles(toShare);

      // Always exit select mode after sharing
      if (mounted) {
        setState(() {
          _selectMode = false;
          _selectedIds.clear();
          _showExportFab = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              duration: Duration(milliseconds: 500),
              content: Text('${L10n.t('export_failed_prefix')}$e')),
        );
      }
    }
  }

  void _enterSelectMode() {
    setState(() {
      _selectMode = true;
      _showDeleteFab = true; // 進入時秀出底部刪除鈕
      _showExportFab = false;
      _selectedIds.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          duration: Duration(milliseconds: 500),
          content: Text(L10n.t('delete_hint_bottom'))),
    );
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _showDeleteFab = false; // 離開時隱藏
      _showExportFab = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id, bool? v) {
    setState(() {
      if (v == true) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  void _selectAllVisible() {
    final filtered = _all.where((r) {
      if (_q.isEmpty) return true;
      final q = _q.toLowerCase();
      return r.name.toLowerCase().contains(q) ||
          r.mode.title.toLowerCase().contains(q);
    });
    setState(() {
      _selectedIds.addAll(filtered.map((e) => e.id));
    });
  }

  Future<void> _importFiles() async {
    try {
      debugPrint('[IMPORT] start pick files');
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['json', 'csv'],
      );
      debugPrint('[IMPORT] pick result: ${res?.files.length ?? 0} file(s)');
      if (res == null || res.files.isEmpty) return;

      int imported = 0;
      int parsed = 0;
      int skipped = 0;
      final existing = await AccelStore.load();
      final byId = {for (final r in existing) r.id: r};
      debugPrint('[IMPORT] existing in store: ${byId.length}');

      for (final f in res.files) {
        debugPrint(
            '[IMPORT] file: name=${f.name}, path=${f.path}, bytes=${f.bytes?.length ?? 0}');
        String? path = f.path;
        final lower = (path ?? '').toLowerCase();
        // helpers to support both file path and bytes
        Future<String> _readAsString() async {
          if (path != null) {
            try {
              return await File(path!).readAsString();
            } catch (_) {}
          }
          if (f.bytes != null) {
            return String.fromCharCodes(f.bytes!);
          }
          throw Exception('no data');
        }

        Future<List<String>> _readAsLines() async {
          final s = await _readAsString();
          return s.split('\n');
        }

        if (lower.endsWith('.json')) {
          try {
            final txt = await _readAsString();
            debugPrint('[IMPORT] read json bytes: ${txt.length}');
            final data = jsonDecode(txt);
            debugPrint('[IMPORT] decoded type: ${data.runtimeType}');

            void _tryAddFlat(dynamic e) {
              try {
                if (e is Map) {
                  final map = e.cast<String, dynamic>();
                  final rec = _recordFromFlatMap(map);
                  if (!byId.containsKey(rec.id)) {
                    byId[rec.id] = rec;
                    imported++;
                  }
                  parsed++;
                  debugPrint(
                      '[IMPORT] parsed id=${rec.id} elapsedMs=${rec.elapsedMs}');
                }
              } catch (_) {
                skipped++;
                debugPrint('[IMPORT] skip one entry due to parse error');
              }
            }

            if (data is List) {
              for (final e in data) {
                _tryAddFlat(e);
              }
              debugPrint('[IMPORT] list count=${(data as List).length}');
            } else if (data is Map) {
              // file contains a single flat record object
              _tryAddFlat(data);
              debugPrint('[IMPORT] single object json processed');
            }
          } catch (_) {}
        } else if (lower.endsWith('.csv')) {
          try {
            final lines = await _readAsLines();
            debugPrint('[IMPORT] read csv lines: ${lines.length}');
            if (lines.isEmpty) continue;
            final header = _safeCsvSplit(lines.first)
                .map((e) => e.replaceAll('"', '').trim())
                .toList();
            for (int i = 1; i < lines.length; i++) {
              final row = _safeCsvSplit(lines[i])
                  .map((e) => e.replaceAll('"', '').trim())
                  .toList();
              if (row.isEmpty) continue;
              final m = <String, String>{};
              for (int j = 0; j < header.length && j < row.length; j++) {
                m[header[j]] = row[j];
              }
              // 嘗試把字串 map 轉成我們匯出的鍵名
              final mapped = <String, dynamic>{};
              void put(String k, String alt1, [String? alt2]) {
                if (m.containsKey(k))
                  mapped[k] = m[k];
                else if (m.containsKey(alt1))
                  mapped[k] = m[alt1];
                else if (alt2 != null && m.containsKey(alt2))
                  mapped[k] = m[alt2];
              }

              put('id', 'ID');
              put('name', 'Name');
              put('mode', 'Mode');
              put('elapsedMs', 'elapsedMs', 'ElapsedMs');
              put('endSpeedKmh', 'endSpeedKmh', 'EndSpeedKmh');
              put('useMph', 'useMph', 'UseMph');
              put('startedAtEpochMs', 'startedAtEpochMs');
              if (!mapped.containsKey('startedAtEpochMs')) {
                // 若無 epoch，嘗試從 date+time
                if (m['date'] != null && m['time'] != null) {
                  mapped['date'] = m['date'];
                  mapped['time'] = m['time'];
                }
              }
              try {
                final rec = _recordFromFlatMap(mapped);
                if (!byId.containsKey(rec.id)) {
                  byId[rec.id] = rec;
                  imported++;
                }
                parsed++;
                debugPrint('[IMPORT] csv row -> id=${rec.id}');
              } catch (_) {
                skipped++;
                debugPrint('[IMPORT] csv parse error');
              }
            }
          } catch (_) {}
        }
      }

      debugPrint(
          '[IMPORT] parsed=$parsed, imported(new)=$imported, skipped=$skipped, merged=${byId.length}');
      final merged = byId.values.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      await AccelStore.saveAll(merged);
      await _load();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 500),
            content: Text(
                '${L10n.t('import_done_count').replaceFirst('%d', imported.toString())}  (parsed:$parsed, skipped:$skipped)'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${L10n.t('import_failed_prefix')}$e')),
        );
      }
    }
  }

  List<String> _safeCsvSplit(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    bool inQ = false;
    for (final ch in line.split('')) {
      if (ch == '"') {
        inQ = !inQ;
        sb.write(ch);
      } else if (ch == ',' && !inQ) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }
    out.add(sb.toString());
    return out;
  }

  AccelMode _modeFromTitle(String t) {
    debugPrint('[IMPORT] mode title raw="$t"');
    final s = (t ?? '').toString().toLowerCase().replaceAll('–', '-').trim();
    // 0-50 km/h or 0-31 mph (≈ 50 km/h)
    if (s.contains('0-50') || (s.contains('0-31') && s.contains('mph'))) {
      return AccelMode.zeroTo50;
    }
    if (s.contains('400') && (s.contains('m') || s.contains('meter'))) {
      return AccelMode.zeroTo400m;
    }
    if (s.contains('100') && s.contains('200')) {
      return AccelMode.hundredTo200;
    }
    // 0-60 mph / 0-60 km/h
    if (s.contains('0-60')) {
      // 不論單位字樣，對應 0-60 類型
      return AccelMode.zeroTo60;
    }
    // 0-100 km/h 或 0-62 mph（常見等價），標題一般寫 0-100
    if (s.contains('0-100')) {
      return AccelMode.zeroTo100;
    }
    // 預設：0-100
    return AccelMode.zeroTo100;
  }

  AccelRecord _recordFromFlatMap(Map<String, dynamic> m) {
    debugPrint('[IMPORT] _recordFromFlatMap keys=${m.keys.toList()}');
    // 來源為本頁匯出的扁平 JSON：id / startedAtEpochMs / date / time / mode(title) / name / elapsedMs / endSpeedKmh / useMph
    // 填補 AccelRecord 需要但匯出時未帶的欄位（startSpeedKmh / distanceM / samples）。
    DateTime started;
    if (m['startedAtEpochMs'] != null) {
      started = DateTime.fromMillisecondsSinceEpoch(
          (m['startedAtEpochMs'] as num).toInt());
    } else if (m['date'] != null && m['time'] != null) {
      try {
        started = DateTime.parse('${m['date']}T${m['time']}');
      } catch (_) {
        started = DateTime.now();
      }
    } else {
      started = DateTime.now();
    }

    String id = (m['id']?.toString() ?? '').trim();
    if (id.isEmpty) {
      final t = started;
      id =
          '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}_${(t.millisecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';
    }

    final mode = _modeFromTitle(m['mode']?.toString() ?? '');
    final name = (m['name']?.toString() ?? '').trim().isEmpty
        ? '${started.month.toString().padLeft(2, '0')}/${started.day.toString().padLeft(2, '0')} ${started.hour.toString().padLeft(2, '0')}:${started.minute.toString().padLeft(2, '0')}'
        : m['name'].toString();

    final elapsedMs =
        (m['elapsedMs'] is num) ? (m['elapsedMs'] as num).toInt() : 0;
    final endSpeedKmh =
        (m['endSpeedKmh'] is num) ? (m['endSpeedKmh'] as num).toDouble() : 0.0;
    final useMph = (m['useMph'] is bool) ? (m['useMph'] as bool) : false;

    // 由模式推距離的預設值（僅作為匯入缺值時的保底；實際距離原始記錄才有）
    final double distanceM = (mode == AccelMode.zeroTo400m) ? 400.0 : 0.0;

    return AccelRecord.minimal(
      id: id,
      name: name,
      mode: mode,
      startedAt: started,
      elapsedMs: elapsedMs,
      endSpeedKmh: endSpeedKmh,
      distanceM: distanceM,
      useMph: useMph,
    );
  }

  Future<void> _deleteSelected() async {
    final chosen = _all.where((r) => _selectedIds.contains(r.id)).toList();
    if (chosen.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              duration: Duration(milliseconds: 500),
              content: Text(L10n.t('select_something_first'))),
        );
      }
      return;
    }
    for (final r in chosen) {
      await AccelStore.delete(r.id);
    }
    await _load();
    if (mounted) {
      setState(() {
        _selectMode = false;
        _showDeleteFab = false; // 刪除後隱藏 FAB
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            duration: Duration(milliseconds: 500),
            content: Text('${L10n.t('delete')}: ${chosen.length}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _all.where((r) {
      if (_q.isEmpty) return true;
      final q = _q.toLowerCase();
      return r.name.toLowerCase().contains(q) ||
          r.mode.title.toLowerCase().contains(q);
    }).toList();

    // 依日期群組
    final groups = <String, List<AccelRecord>>{};
    for (final r in filtered) {
      final key =
          '${r.startedAt.year}-${r.startedAt.month.toString().padLeft(2, '0')}-${r.startedAt.day.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(r);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.t('accel_records')),
        actions: [
          if (!_selectMode) ...[
            IconButton(
              onPressed: () {
                _enterSelectMode();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      duration: Duration(milliseconds: 500),
                      content: Text(L10n.t('delete_hint_bottom'))),
                );
              },
              tooltip: L10n.t('delete'),
              icon: const Icon(Icons.delete),
            ),
            IconButton(
              onPressed: _importFiles,
              tooltip: L10n.t('import'),
              icon: const Icon(Icons.download),
            ),
            IconButton(
              onPressed: () async {
                // 進入選擇模式並顯示底部匯出 FAB
                if (!_selectMode) {
                  _enterSelectMode();
                }
                setState(() {
                  _showExportFab = true; // 顯示匯出 FAB
                  _showDeleteFab = false; // 匯出模式下隱藏刪除 FAB
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(milliseconds: 500),
                    content: Text(L10n.t('export_hint_bottom')),
                  ),
                );
              },
              tooltip: L10n.t('export'),
              icon: const Icon(Icons.ios_share),
            ),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ] else ...[
            IconButton(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      duration: Duration(milliseconds: 500),
                      content: Text(L10n.t('use_bottom_delete_button'))),
                );
              },
              tooltip: L10n.t('delete'),
              icon: const Icon(Icons.delete),
            ),
            IconButton(
              onPressed: () async {
                setState(() {
                  _showExportFab = true;
                  _showDeleteFab = false; // 匯出模式下隱藏刪除 FAB
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(milliseconds: 500),
                    content: Text(L10n.t('export_hint_bottom')),
                  ),
                );
              },
              tooltip: L10n.t('export'),
              icon: const Icon(Icons.ios_share),
            ),
            IconButton(
              onPressed: _selectAllVisible,
              tooltip: L10n.t('select_all'),
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              onPressed: _exitSelectMode,
              tooltip: L10n.t('cancel'),
              icon: const Icon(Icons.close),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: L10n.t('search_name_or_date'),
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemCount: keys.length,
              itemBuilder: (_, i) {
                final k = keys[i];
                final items = groups[k]!;
                return _DateGroup(
                  dateKey: k,
                  items: items,
                  onRename: _rename,
                  onDelete: _delete,
                  onDeleteGroup: (dk, list) => _deleteGroup(dk, list),
                  onRemoveGroup: _removeGroupFromView,
                  selectMode: _selectMode,
                  selectedIds: _selectedIds,
                  onToggleSelect: _toggleSelect,
                );
              },
            ),
      floatingActionButton: _selectMode
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_showExportFab)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FloatingActionButton.extended(
                      onPressed: () async {
                        final chosen = _all
                            .where((r) => _selectedIds.contains(r.id))
                            .toList();
                        if (chosen.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(milliseconds: 500),
                              content: Text(L10n.t('select_something_first')),
                            ),
                          );
                          return;
                        }
                        await _exportJson(chosen, suffix: 'selected');
                      },
                      icon: const Icon(Icons.ios_share),
                      label:
                          Text('${L10n.t('export')} (${_selectedIds.length})'),
                    ),
                  ),
                if (_showDeleteFab)
                  FloatingActionButton.extended(
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete),
                    label: Text('${L10n.t('delete')} (${_selectedIds.length})'),
                  ),
              ],
            )
          : null,
    );
  }
}

class _DateGroup extends StatelessWidget {
  final String dateKey;
  final List<AccelRecord> items;
  final Future<void> Function(AccelRecord) onRename;
  final Future<void> Function(AccelRecord) onDelete;
  final Future<void> Function(String, List<AccelRecord>) onDeleteGroup;
  final void Function(String) onRemoveGroup;

  final bool selectMode;
  final Set<String> selectedIds;
  final void Function(String, bool?) onToggleSelect;

  const _DateGroup({
    required this.dateKey,
    required this.items,
    required this.onRename,
    required this.onDelete,
    required this.onDeleteGroup,
    required this.onRemoveGroup,
    required this.selectMode,
    required this.selectedIds,
    required this.onToggleSelect,
  });

  String _fmtMs(int ms) {
    final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final milli = (ms % 1000).toString().padLeft(3, '0');
    return '$minutes:$seconds.$milli';
  }

  String _fmtTime(DateTime t) {
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$min:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('group-' + dateKey),
      direction: DismissDirection.endToStart,
      background: const SizedBox.shrink(),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: Colors.redAccent,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (dir) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(L10n.t('delete_record')),
            content: Text(
              L10n.t('confirm_delete_name')
                  .replaceFirst('%s', '$dateKey  (x${items.length})'),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(L10n.t('cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(L10n.t('delete'))),
            ],
          ),
        );
        return ok == true;
      },
      onDismissed: (_) async {
        // 先把這個日期群組從 UI 列表移除，避免 Dismissible 殘留錯誤
        onRemoveGroup(dateKey);
        // 再刪除儲存層資料並重新載入
        await onDeleteGroup(dateKey, items);
      },
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: ExpansionTile(
          key: ValueKey('exp-${dateKey}-${selectMode ? 'open' : 'close'}'),
          initiallyExpanded: selectMode,
          title: Text(dateKey),
          children: items.map((r) {
            return ListTile(
              leading: selectMode
                  ? Checkbox(
                      value: selectedIds.contains(r.id),
                      onChanged: (v) => onToggleSelect(r.id, v),
                      shape: const CircleBorder(),
                    )
                  : null,
              title: Text(r.name.isNotEmpty ? r.name : _fmtTime(r.startedAt)),
              subtitle: Builder(builder: (_) {
                if (r.mode == AccelMode.zeroTo400m) {
                  final useMph = r.useMph; // 當時單位
                  final speed =
                      useMph ? r.endSpeedKmh * 0.621371 : r.endSpeedKmh;
                  final unit = useMph ? 'mph' : 'km/h';
                  return Text(
                      '${r.mode.title}  •  ${_fmtMs(r.elapsedMs)}  •  ${speed.toStringAsFixed(0)} $unit');
                } else {
                  return Text('${r.mode.title}  •  ${_fmtMs(r.elapsedMs)}');
                }
              }),
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'rename') onRename(r);
                  if (v == 'delete') onDelete(r);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'rename', child: Text(L10n.t('rename'))),
                  PopupMenuItem(value: 'delete', child: Text(L10n.t('delete'))),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
