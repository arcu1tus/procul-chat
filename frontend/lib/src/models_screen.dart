import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'model_catalog_controller.dart';
import 'models.dart';
import 'time_format.dart';
import 'widgets/content_width.dart';
import 'widgets/icon_action.dart';
import 'widgets/model_badges.dart';
import 'widgets/skeleton.dart';

/// The model catalog: every model the server is configured with, its
/// capabilities, and a live health snapshot. Reached from the sidebar.
///
/// The [catalog] is owned by the shell (so the app-bar picker and this screen
/// share one source); this screen only renders and refreshes it.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({
    super.key,
    required this.catalog,
    this.showMenuButton = false,
    this.onMenu,
  });

  final ModelCatalogController catalog;

  /// Whether to show a leading button that opens the conversation drawer.
  final bool showMenuButton;
  final VoidCallback? onMenu;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.catalog,
      builder: (context, _) {
        final catalog = widget.catalog;
        return Scaffold(
          loadingProgressIndeterminate:
              catalog.isLoading || catalog.isCheckingAll,
          headers: [
            AppBar(
              title: const Text(
                'Models',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text(
                'Models configured on this server',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ).muted.small,
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
                  key: const Key('check-all-models'),
                  icon: LucideIcons.heartPulse,
                  label: 'Check all models',
                  onPressed: catalog.isCheckingAll ? null : catalog.checkAll,
                ),
                IconAction(
                  icon: LucideIcons.refreshCw,
                  label: 'Refresh models',
                  onPressed: catalog.isLoading ? null : catalog.refresh,
                ),
              ],
            ),
            const Divider(),
          ],
          child: RefreshTrigger(
            onRefresh: catalog.refresh,
            child: _body(catalog),
          ),
        );
      },
    );
  }

  Widget _body(ModelCatalogController catalog) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = centeredSidePadding(constraints.maxWidth);
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20 + side, 20, 20 + side, 28),
          children: [
            if (catalog.error != null) ...[
              _ErrorNote(message: catalog.error!),
              const Gap(16),
            ],
            if (catalog.models.isEmpty)
              // Only shimmer while the first load is genuinely in flight; after a
              // failed first load the error note above is the whole state.
              catalog.isLoading
                  ? const _ModelsSkeleton()
                  : catalog.error == null
                  ? const _EmptyModels()
                  : const SizedBox.shrink()
            else ...[
              for (final model in catalog.models)
                _ModelCard(model: model, catalog: catalog),
              const Gap(8),
              const Text(
                'Unhealthy models are re-checked periodically, and a model with '
                'recent traffic is considered live.',
              ).muted.small,
            ],
          ],
        );
      },
    );
  }
}

/// One configured model: name, description, capability badges, and a health row.
class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model, required this.catalog});

  final ChatModel model;
  final ModelCatalogController catalog;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final checking = catalog.checkingSlug == model.slug;
    final description = model.description?.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ModelHealthDot(status: model.health.status),
              const Gap(8),
              Expanded(
                child: Text(
                  model.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ).medium,
              ),
              if (model.isDefault) ...[const Gap(8), const _DefaultPill()],
              IconAction(
                key: ValueKey('check-${model.slug}'),
                icon: LucideIcons.heartPulse,
                label: 'Check ${model.name}',
                size: 16,
                onPressed: checking || catalog.isCheckingAll
                    ? null
                    : () => catalog.check(model.slug),
              ),
            ],
          ),
          if (description != null && description.isNotEmpty) ...[
            const Gap(4),
            Text(description).muted.small,
          ],
          if (model.capabilities.input.isNotEmpty) ...[
            const Gap(10),
            CapabilityBadges(modalities: model.capabilities.input),
          ],
          const Gap(10),
          _HealthRow(health: model.health),
        ],
      ),
    );
  }
}

/// A small filled pill marking the server's default model.
class _DefaultPill extends StatelessWidget {
  const _DefaultPill();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Default',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: colors.primaryForeground,
        ),
      ),
    );
  }
}

/// The advisory health line: status, latency, last check / use, and last error.
class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.health});

  final ModelHealth health;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final parts = <String>[
      ModelHealthDot.labelFor(health.status),
      if (health.latencyMs != null) '${health.latencyMs} ms',
      if (health.lastCheckedAt != null)
        'checked ${relativeTime(health.lastCheckedAt!)}',
      if (health.lastUsedAt != null) 'used ${relativeTime(health.lastUsedAt!)}',
    ];
    final lastError = health.lastError?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          parts.join(' · '),
          style: TextStyle(fontSize: 11, color: colors.mutedForeground),
        ),
        if (lastError != null && lastError.isNotEmpty) ...[
          const Gap(3),
          Text(
            'Last error: $lastError',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.destructive),
          ),
        ],
      ],
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
class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        children: [
          Icon(LucideIcons.blocks, size: 34, color: colors.mutedForeground),
          const Gap(12),
          const Text('No models configured').semiBold,
          const Gap(4),
          const Text('Add models to the backend config to see them here.')
              .muted
              .small,
        ],
      ),
    );
  }
}

/// Shimmer placeholders shaped like model cards.
class _ModelsSkeleton extends StatelessWidget {
  const _ModelsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Column(
        children: [
          _ModelCardSkeleton(),
          Gap(10),
          _ModelCardSkeleton(),
          Gap(10),
          _ModelCardSkeleton(),
        ],
      ),
    );
  }
}

class _ModelCardSkeleton extends StatelessWidget {
  const _ModelCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FractionallySizedBox(
            widthFactor: 0.45,
            alignment: Alignment.centerLeft,
            child: Skeleton(height: 13),
          ),
          Gap(8),
          FractionallySizedBox(
            widthFactor: 0.7,
            alignment: Alignment.centerLeft,
            child: Skeleton(height: 10),
          ),
          Gap(10),
          Skeleton(width: 120, height: 16, radius: 6),
        ],
      ),
    );
  }
}
