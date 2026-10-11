import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../models.dart';

/// The label shown for an input modality (`Text`, `Image`, `File`, `Audio`,
/// `Video`).
String modelInputModalityLabel(ModelInputModality modality) =>
    switch (modality) {
      ModelInputModality.text => 'Text',
      ModelInputModality.image => 'Image',
      ModelInputModality.file => 'File',
      ModelInputModality.audio => 'Audio',
      ModelInputModality.video => 'Video',
    };

/// The icon shown for an input modality.
IconData modelInputModalityIcon(ModelInputModality modality) =>
    switch (modality) {
      ModelInputModality.text => LucideIcons.type,
      ModelInputModality.image => LucideIcons.image,
      ModelInputModality.file => LucideIcons.fileText,
      ModelInputModality.audio => LucideIcons.audioLines,
      ModelInputModality.video => LucideIcons.video,
    };

/// A small pill for one capability (e.g. an `Image` input).
class CapabilityBadge extends StatelessWidget {
  const CapabilityBadge({
    super.key,
    required this.modality,
    this.compact = false,
  });

  final ModelInputModality modality;

  /// Whether to render the icon only (used in tight spots like menu rows).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            modelInputModalityIcon(modality),
            size: 11,
            color: colors.mutedForeground,
          ),
          if (!compact) ...[
            const Gap(4),
            Text(
              modelInputModalityLabel(modality),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: colors.mutedForeground,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The capability badges for a model, in the canonical Text/Image/File/Audio/
/// Video order.
class CapabilityBadges extends StatelessWidget {
  const CapabilityBadges({
    super.key,
    required this.modalities,
    this.compact = false,
  });

  final Set<ModelInputModality> modalities;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final modality in ModelInputModality.values)
          if (modalities.contains(modality))
            CapabilityBadge(modality: modality, compact: compact),
      ],
    );
  }
}

/// A small coloured dot reflecting a model's health, with a tooltip.
class ModelHealthDot extends StatelessWidget {
  const ModelHealthDot({super.key, required this.status, this.size = 8});

  final ModelHealthStatus status;
  final double size;

  /// The dot colour: green when healthy, destructive when unhealthy, muted when
  /// not yet observed.
  static Color colorFor(BuildContext context, ModelHealthStatus status) =>
      switch (status) {
        ModelHealthStatus.healthy => const Color(0xFF22C55E),
        ModelHealthStatus.unhealthy => ColorScheme.of(context).destructive,
        ModelHealthStatus.unknown => ColorScheme.of(context).mutedForeground,
      };

  /// The human label for a health status.
  static String labelFor(ModelHealthStatus status) => switch (status) {
    ModelHealthStatus.healthy => 'Healthy',
    ModelHealthStatus.unhealthy => 'Unhealthy',
    ModelHealthStatus.unknown => 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final label = labelFor(status);
    return Tooltip(
      tooltip: (context) => TooltipContainer(child: Text(label)),
      child: Semantics(
        label: 'Health: $label',
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colorFor(context, status),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
