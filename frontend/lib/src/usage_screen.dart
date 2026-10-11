import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_api.dart';
import 'models.dart';
import 'usage.dart';
import 'usage_controller.dart';
import 'widgets/content_width.dart';
import 'widgets/icon_action.dart';
import 'widgets/skeleton.dart';

/// The token-usage dashboard: lifetime totals, a browsable per-day chart over a
/// selectable window, and a per-model breakdown. Reached from the sidebar.
class UsageScreen extends StatefulWidget {
  const UsageScreen({
    super.key,
    required this.api,
    this.showMenuButton = false,
    this.onMenu,
  });

  final ChatApi api;

  /// Whether to show a leading button that opens the conversation drawer.
  final bool showMenuButton;
  final VoidCallback? onMenu;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

/// Which token count the bar chart plots.
enum _Metric { total, input, output }

class _UsageScreenState extends State<UsageScreen> {
  late final UsageController _controller;
  _Metric _metric = _Metric.total;

  @override
  void initState() {
    super.initState();
    _controller = UsageController(api: widget.api);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          loadingProgressIndeterminate: _controller.isLoading,
          headers: [
            AppBar(
              title: const Text('Usage'),
              subtitle: const Text('Tokens used by the assistant').muted.small,
              leading: widget.showMenuButton
                  ? [
                      IconAction(
                        icon: LucideIcons.panelLeft,
                        label: 'Open chats',
                        onPressed: widget.onMenu,
                      ),
                    ]
                  : const [],
              trailing: [
                IconAction(
                  icon: LucideIcons.refreshCw,
                  label: 'Refresh usage',
                  onPressed: _controller.isLoading ? null : _controller.refresh,
                ),
              ],
            ),
            const Divider(),
          ],
          child: RefreshTrigger(onRefresh: _controller.refresh, child: _body()),
        );
      },
    );
  }

  Widget _body() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = centeredSidePadding(constraints.maxWidth);
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20 + side, 20, 20 + side, 28),
          children: [
            if (_controller.error != null) ...[
              _ErrorNote(message: _controller.error!),
              const Gap(16),
            ],
            if (_controller.summary == null)
              // Only shimmer while the first load is genuinely in flight; after a
              // failed first load there is nothing to skeleton and the error note
              // above is the whole state.
              _controller.isLoading
                  ? const _UsageSkeleton()
                  : const SizedBox.shrink()
            else if (_controller.isEmpty)
              const _EmptyUsage()
            else
              ..._content(),
          ],
        );
      },
    );
  }

  List<Widget> _content() {
    return [
      const Text('Lifetime').semiBold(),
      const Gap(10),
      _LifetimeCards(lifetime: _controller.lifetime),
      const Gap(24),
      const Divider(),
      const Gap(16),
      Row(
        children: [
          Expanded(child: const Text('Daily usage').semiBold()),
          _RangeSelector(
            selected: _controller.selectedRange,
            onChanged: _controller.setRange,
          ),
        ],
      ),
      const Gap(12),
      _MetricSelector(
        selected: _metric,
        onChanged: (metric) => setState(() => _metric = metric),
      ),
      const Gap(16),
      _UsageChart(days: _controller.days, metric: _metric),
      if (_controller.models.isNotEmpty) ...[
        const Gap(24),
        const Divider(),
        const Gap(16),
        const Text('By model').semiBold(),
        const Gap(10),
        for (final model in _controller.models) _ModelRow(model: model),
      ],
    ];
  }
}

/// Lifetime summary as a wrap of compact stat cards.
class _LifetimeCards extends StatelessWidget {
  const _LifetimeCards({required this.lifetime});

  final UsageBreakdown lifetime;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatCard(
          label: 'Total',
          value: formatTokenCount(lifetime.totalTokens),
        ),
        _StatCard(
          label: 'Input',
          value: formatTokenCount(lifetime.inputTokens),
        ),
        _StatCard(
          label: 'Output',
          value: formatTokenCount(lifetime.outputTokens),
        ),
        _StatCard(
          label: 'Cached',
          value: formatTokenCount(lifetime.cachedInputTokens),
        ),
        _StatCard(label: 'Turns', value: '${lifetime.turns}'),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      width: 132,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label).muted.xSmall,
          const Gap(2),
          Text(value).semiBold.large,
        ],
      ),
    );
  }
}

/// A four-way 7 / 30 / 90 / All segmented control.
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  static String _label(int days) => days >= 365 ? 'All' : '${days}D';

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final days in UsageController.rangeOptions)
            SelectedButton(
              value: selected == days,
              onChanged: (_) => onChanged(days),
              child: Text(_label(days)).xSmall,
            ),
        ],
      ),
    );
  }
}

/// A three-way Total / Input / Output segmented control for the chart metric.
class _MetricSelector extends StatelessWidget {
  const _MetricSelector({required this.selected, required this.onChanged});

  final _Metric selected;
  final ValueChanged<_Metric> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          for (final metric in _Metric.values)
            Expanded(
              child: SelectedButton(
                value: selected == metric,
                onChanged: (_) => onChanged(metric),
                child: Text(_metricLabel(metric)).small,
              ),
            ),
        ],
      ),
    );
  }

  static String _metricLabel(_Metric metric) => switch (metric) {
    _Metric.total => 'Total',
    _Metric.input => 'Input',
    _Metric.output => 'Output',
  };
}

/// The per-day bar chart. Tapping a bar shows the day and its value.
class _UsageChart extends StatelessWidget {
  const _UsageChart({required this.days, required this.metric});

  final List<UsageDay> days;
  final _Metric metric;

  int _value(UsageBreakdown totals) => switch (metric) {
    _Metric.total => totals.totalTokens,
    _Metric.input => totals.inputTokens,
    _Metric.output => totals.outputTokens,
  };

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    if (days.isEmpty) {
      return const SizedBox(height: 220);
    }

    final values = days.map((day) => _value(day.totals)).toList();
    final maxValue = values.reduce(math.max);
    final maxY = maxValue <= 0 ? 1.0 : maxValue * 1.2;
    // Show roughly eight date labels regardless of the window length.
    final labelEvery = days.length <= 12 ? 1 : (days.length / 8).ceil();
    final barWidth = days.length > 60 ? 2.5 : (days.length > 20 ? 5.0 : 10.0);

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => colors.popover,
              getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                  BarTooltipItem(
                    '${days[group.x].date}\n${formatTokenCount(rod.toY.round())}',
                    TextStyle(color: colors.popoverForeground, fontSize: 12),
                  ),
            ),
          ),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: colors.border, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                getTitlesWidget: (value, meta) => value <= 0
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        meta: meta,
                        child: Text(formatTokenCount(value.round()))
                            .muted
                            .xSmall,
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 ||
                      index >= days.length ||
                      index % labelEvery != 0) {
                    return const SizedBox.shrink();
                  }
                  final date = days[index].date;
                  final label = date.length >= 10 ? date.substring(5) : date;
                  return SideTitleWidget(
                    meta: meta,
                    space: 6,
                    child: Text(label).muted.xSmall,
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var index = 0; index < days.length; index++)
              BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: values[index].toDouble(),
                    color: colors.primary,
                    width: barWidth,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// One row of the per-model breakdown.
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});

  final UsageModel model;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              model.model,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ).medium,
          ),
          const Gap(8),
          Text(
            '${formatTokenCount(model.totals.totalTokens)} tokens',
            style: TextStyle(fontSize: 12, color: colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: TextStyle(
        fontSize: 12,
        color: ColorScheme.of(context).destructive,
      ),
    );
  }
}

/// Centred, scrollable empty state so pull-to-refresh still works.
class _EmptyUsage extends StatelessWidget {
  const _EmptyUsage();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        children: [
          Icon(
            LucideIcons.chartColumn,
            size: 34,
            color: colors.mutedForeground,
          ),
          const Gap(12),
          const Text('No usage yet').semiBold,
          const Gap(4),
          const Text('Token usage appears here once you chat.').muted.small,
        ],
      ),
    );
  }
}

/// Shimmer placeholders shaped like the real dashboard.
class _UsageSkeleton extends StatelessWidget {
  const _UsageSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Skeleton(width: 90, height: 14),
          Gap(12),
          Row(
            children: [
              Expanded(child: Skeleton(height: 58, radius: 10)),
              Gap(8),
              Expanded(child: Skeleton(height: 58, radius: 10)),
              Gap(8),
              Expanded(child: Skeleton(height: 58, radius: 10)),
            ],
          ),
          Gap(24),
          Skeleton(height: 220, radius: 12),
        ],
      ),
    );
  }
}
