import 'dart:math';
import 'package:flutter/material.dart';
import 'package:gps_speedometer_min/setting.dart';

// 區間模式
enum RangeMode { last31Days, monthly, yearly }

class TotalStatsPage extends StatefulWidget {
  final int count;
  final double totalMeters;
  final Duration totalMoving;
  final double maxSpeedKmh;
  final double avgSpeedKmh;
  final List<double> distancesMeters; // 每筆距離（對應 tripStartDates 同索引）
  final List<DateTime> tripStartDates; // 每筆開始時間

  const TotalStatsPage({
    super.key,
    required this.count,
    required this.totalMeters,
    required this.totalMoving,
    required this.maxSpeedKmh,
    required this.avgSpeedKmh,
    required this.distancesMeters,
    required this.tripStartDates,
  });

  @override
  State<TotalStatsPage> createState() => _TotalStatsPageState();
}

class _TotalStatsPageState extends State<TotalStatsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  RangeMode _mode = RangeMode.last31Days;

  // Helper: 讀取英里設定
  bool get _useMiles {
    try {
      return Setting.instance.useMph; // 專案內統一用 useMph
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(
        length: 3,
        vsync:
            this); // keep variable to avoid compile errors but will not be used
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _fmtDist(double meters) {
    if (_useMiles) {
      const mPerMile = 1609.344;
      const mPerFoot = 0.3048;
      if (meters >= mPerMile) {
        final mi = meters / mPerMile;
        return mi.toStringAsFixed(2) + ' mi';
      } else {
        final ft = meters / mPerFoot;
        // < 1 mi 改用英尺便於閱讀
        return ft.toStringAsFixed(ft >= 100 ? 0 : 1) + ' ft';
      }
    } else {
      if (meters >= 1000) {
        return (meters / 1000).toStringAsFixed(2) + ' km';
      } else {
        return meters.toStringAsFixed(0) + ' m';
      }
    }
  }

  String _fmtDur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _fmtSpeedKmh(double kmh) {
    if (_useMiles) {
      final mph = kmh * 0.621371; // km/h -> mph
      return mph.toStringAsFixed(1) + ' mph';
    }
    return kmh.toStringAsFixed(1) + ' km/h';
  }

  // ===== 聚合器 =====
  _DailySeries _buildSeries(RangeMode mode) {
    switch (mode) {
      case RangeMode.last31Days:
        return _seriesLast31Days();
      case RangeMode.monthly:
        return _seriesMonthly();
      case RangeMode.yearly:
        return _seriesYearly();
    }
  }

  _DailySeries _seriesLast31Days() {
    final now = DateTime.now();
    final start = now.subtract(const Duration(days: 30)); // 共31天
    final Map<DateTime, _DailyPoint> map = {};
    for (int i = 0; i < widget.tripStartDates.length; i++) {
      final dt = widget.tripStartDates[i];
      if (dt.isBefore(start)) continue;
      final day = DateTime(dt.year, dt.month, dt.day);
      final p = map.putIfAbsent(day, () => _DailyPoint(day));
      final d =
          i < widget.distancesMeters.length ? widget.distancesMeters[i] : 0.0;
      p.distanceMeters += d;
      p.count++;
    }
    final days = map.keys.toList()..sort();
    return _DailySeries(
        days.map((d) => map[d]!).toList(), RangeMode.last31Days);
  }

  _DailySeries _seriesMonthly() {
    final Map<String, _DailyPoint> map = {};
    for (int i = 0; i < widget.tripStartDates.length; i++) {
      final dt = widget.tripStartDates[i];
      final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
      final labelDate = DateTime(dt.year, dt.month, 1);
      final p = map.putIfAbsent(key, () => _DailyPoint(labelDate));
      final d =
          i < widget.distancesMeters.length ? widget.distancesMeters[i] : 0.0;
      p.distanceMeters += d;
      p.count++;
    }
    final keys = map.keys.toList()..sort((a, b) => a.compareTo(b));
    return _DailySeries(keys.map((k) => map[k]!).toList(), RangeMode.monthly);
  }

  _DailySeries _seriesYearly() {
    final Map<int, _DailyPoint> map = {};
    for (int i = 0; i < widget.tripStartDates.length; i++) {
      final dt = widget.tripStartDates[i];
      final p = map.putIfAbsent(dt.year, () => _DailyPoint(DateTime(dt.year)));
      final d =
          i < widget.distancesMeters.length ? widget.distancesMeters[i] : 0.0;
      p.distanceMeters += d;
      p.count++;
    }
    final years = map.keys.toList()..sort();
    return _DailySeries(years.map((y) => map[y]!).toList(), RangeMode.yearly);
  }

  String _tickLabel(_DailyPoint p, RangeMode mode) {
    switch (mode) {
      case RangeMode.last31Days:
        return '${p.day.month}/${p.day.day}';
      case RangeMode.monthly:
        return '${p.day.year}/${p.day.month}';
      case RangeMode.yearly:
        return p.day.year.toString();
    }
  }

  String _dateTitle(_DailyPoint p, RangeMode mode) => _tickLabel(p, mode);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            L10n.t('stats_result_title', params: {'n': '${widget.count}'})),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: _RangeSwitcher(
              mode: _mode,
              onChanged: (m) => setState(() => _mode = m),
            ),
          ),
          _buildBody(cs, _mode),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs, RangeMode mode) {
    final series = _buildSeries(mode);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatCard(
            title: L10n.t('total_distance'),
            value: _fmtDist(widget.totalMeters),
            icon: Icons.route,
          ),
          const SizedBox(height: 8),
          _StatCard(
            title: L10n.t('total_moving'),
            value: _fmtDur(widget.totalMoving),
            icon: Icons.timer,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  title: L10n.t('max_speed'),
                  value: _fmtSpeedKmh(widget.maxSpeedKmh),
                  icon: Icons.speed,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  title: L10n.t('avg_speed'),
                  value: _fmtSpeedKmh(widget.avgSpeedKmh),
                  icon: Icons.speed_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionTitle(
              title:
                  L10n.t('total_distance') + ' • ' + L10n.t('stats_confirm')),
          const SizedBox(height: 8),
          _DailyBarChart(
            series: series,
            height: 240,
            color: cs.primary,
            mode: DailyMetric.distance,
            valueLabelBuilder: (p) => _fmtDist(p.distanceMeters),
            tickLabelBuilder: (p) => _tickLabel(p, mode),
            dateTitleBuilder: (p) => _dateTitle(p, mode),
          ),
          const SizedBox(height: 24),
          _SectionTitle(title: L10n.t('trip_count') ?? 'Trips'),
          const SizedBox(height: 8),
          _DailyBarChart(
            series: series,
            height: 240,
            color: cs.tertiary,
            mode: DailyMetric.count,
            valueLabelBuilder: (p) => '${p.count}',
            tickLabelBuilder: (p) => _tickLabel(p, mode),
            dateTitleBuilder: (p) => _dateTitle(p, mode),
          ),
        ],
      ),
    );
  }
} // close _TotalStatsPageState

class _RangeSwitcher extends StatelessWidget {
  final RangeMode mode;
  final ValueChanged<RangeMode> onChanged;
  const _RangeSwitcher({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = [
      L10n.t('stats_tab_31d'),
      L10n.t('stats_tab_month'),
      L10n.t('stats_tab_year'),
    ];
    final modes = const [
      RangeMode.last31Days,
      RangeMode.monthly,
      RangeMode.yearly
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(builder: (context, c) {
          return ToggleButtons(
            isSelected: modes.map((m) => m == mode).toList(),
            onPressed: (i) => onChanged(modes[i]),
            borderRadius: BorderRadius.circular(10),
            constraints:
                BoxConstraints(minWidth: (c.maxWidth - 4) / 3, minHeight: 36),
            selectedColor: cs.onPrimary,
            fillColor: cs.primary,
            color: cs.onSurface,
            children: labels.map((t) => Text(t)).toList(),
          );
        }),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});
  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  const _StatCard(
      {required this.title, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(color: cs.onSurface.withOpacity(0.7))),
                  const SizedBox(height: 6),
                  Text(value,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ====== Daily Series / Chart ======
class _DailyPoint {
  _DailyPoint(this.day);
  final DateTime day; // 以當地時區日期或週期代表
  double distanceMeters = 0.0;
  int count = 0;
}

class _DailySeries {
  _DailySeries(this.points, this.mode);
  final List<_DailyPoint> points; // 已排序（遞增）
  final RangeMode mode;
}

enum DailyMetric { distance, count }

class _DailyBarChart extends StatefulWidget {
  final _DailySeries series;
  final double height;
  final Color color;
  final DailyMetric mode;
  final String Function(_DailyPoint) valueLabelBuilder;
  final String Function(_DailyPoint)? tickLabelBuilder; // x 軸刻度（首/中/尾）
  final String Function(_DailyPoint)? dateTitleBuilder; // tooltip 日期顯示
  const _DailyBarChart({
    required this.series,
    required this.height,
    required this.color,
    this.mode = DailyMetric.distance,
    required this.valueLabelBuilder,
    this.tickLabelBuilder,
    this.dateTitleBuilder,
  });

  @override
  State<_DailyBarChart> createState() => _DailyBarChartState();
}

class _DailyBarChartState extends State<_DailyBarChart> {
  int? _hoverIndex; // 目前高亮的 bar index

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final points = widget.series.points;

    String _tick(_DailyPoint p) => widget.tickLabelBuilder != null
        ? widget.tickLabelBuilder!(p)
        : '${p.day.month}/${p.day.day}';

    return Card(
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 22),
              child: _DailyBars(
                points: points,
                color: widget.color,
                mode: widget.mode,
                hoverIndex: _hoverIndex,
                onHoverIndex: (i) => setState(() => _hoverIndex = i),
              ),
            ),
            // x 軸刻度（首 / 中 / 尾）
            Positioned(
              left: 12,
              right: 12,
              bottom: 4,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (points.isNotEmpty)
                    Text(_tick(points.first),
                        style: TextStyle(
                            color: cs.onSurface.withOpacity(0.55),
                            fontSize: 11)),
                  if (points.length > 2)
                    Text(_tick(points[points.length ~/ 2]),
                        style: TextStyle(
                            color: cs.onSurface.withOpacity(0.55),
                            fontSize: 11)),
                  if (points.isNotEmpty)
                    Text(_tick(points.last),
                        style: TextStyle(
                            color: cs.onSurface.withOpacity(0.55),
                            fontSize: 11)),
                ],
              ),
            ),
            // tooltip
            if (_hoverIndex != null &&
                _hoverIndex! >= 0 &&
                _hoverIndex! < points.length)
              _DailyTooltip(
                point: points[_hoverIndex!],
                mode: widget.mode,
                valueLabel: widget.valueLabelBuilder(points[_hoverIndex!]),
                dateText: widget.dateTitleBuilder != null
                    ? widget.dateTitleBuilder!(points[_hoverIndex!])
                    : '${points[_hoverIndex!].day.month}/${points[_hoverIndex!].day.day}',
              ),
          ],
        ),
      ),
    );
  }
}

class _DailyBars extends StatelessWidget {
  final List<_DailyPoint> points;
  final Color color;
  final DailyMetric mode;
  final int? hoverIndex;
  final ValueChanged<int?> onHoverIndex;
  const _DailyBars({
    required this.points,
    required this.color,
    required this.mode,
    required this.hoverIndex,
    required this.onHoverIndex,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return GestureDetector(
          onPanDown: (d) => _hitTest(c, d.localPosition.dx),
          onPanUpdate: (d) => _hitTest(c, d.localPosition.dx),
          onTapDown: (d) => _hitTest(c, d.localPosition.dx),
          onTapUp: (_) => onHoverIndex(null),
          child: CustomPaint(
            size: Size.infinite,
            painter: _DailyBarsPainter(
              points: points,
              color: color,
              mode: mode,
              highlightIndex: hoverIndex,
            ),
          ),
        );
      },
    );
  }

  void _hitTest(BoxConstraints c, double dx) {
    final w = c.maxWidth;
    final n = max(1, points.length);
    final barW = w / (n * 1.5);
    final spacing = barW * 0.5;

    int idx = ((dx) / (barW + spacing)).floor();
    if (idx < 0) idx = 0;
    if (idx >= points.length) idx = points.length - 1;
    onHoverIndex(idx);
  }
}

class _DailyBarsPainter extends CustomPainter {
  final List<_DailyPoint> points;
  final Color color;
  final DailyMetric mode;
  final int? highlightIndex;
  _DailyBarsPainter(
      {required this.points,
      required this.color,
      required this.mode,
      required this.highlightIndex});

  @override
  void paint(Canvas canvas, Size size) {
    final baseY = size.height - 8.0;
    final axis = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.grey.withOpacity(0.35)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), axis);

    final double barW = size.width / (max(1, points.length) * 1.5);
    final double spacing = barW * 0.5;

    double maxValue = 0.0;
    for (final p in points) {
      final v =
          mode == DailyMetric.distance ? p.distanceMeters : p.count.toDouble();
      if (v > maxValue) maxValue = v;
    }
    if (maxValue <= 0) maxValue = 1.0;

    final barPaint = Paint()..color = color.withOpacity(0.9);
    final hiPaint = Paint()..color = color.withOpacity(0.55);

    for (int i = 0; i < points.length; i++) {
      final v = mode == DailyMetric.distance
          ? points[i].distanceMeters
          : points[i].count.toDouble();
      final h = (v / maxValue) * (baseY - 12.0);
      final double x = i * (barW + spacing);
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, baseY - h, barW, h), const Radius.circular(4));
      canvas.drawRRect(r, i == highlightIndex ? hiPaint : barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _DailyBarsPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.color != color ||
      oldDelegate.mode != mode ||
      oldDelegate.highlightIndex != highlightIndex;
}

class _DailyTooltip extends StatelessWidget {
  final _DailyPoint point;
  final DailyMetric mode;
  final String valueLabel;
  final String dateText;
  const _DailyTooltip(
      {required this.point,
      required this.mode,
      required this.valueLabel,
      required this.dateText});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      left: 16,
      right: 16,
      top: 8,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outlineVariant),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 6)
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(dateText,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: cs.onSurface)),
              const SizedBox(width: 10),
              Text(
                mode == DailyMetric.distance ? valueLabel : '${point.count}',
                style: TextStyle(color: cs.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
