import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../motion.dart';
import 'pressable.dart';
import 'procul_logo.dart';
import 'stagger.dart';

class ChatWelcome extends StatelessWidget {
  const ChatWelcome({super.key, required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _starters = [
    (
      LucideIcons.penLine,
      'Write something',
      'Find the right words',
      'Help me write a message about ',
    ),
    (
      LucideIcons.bookOpen,
      'Understand something',
      'Make a tricky topic click',
      'Explain this in simple terms: ',
    ),
    (
      LucideIcons.lightbulb,
      'Explore an idea',
      'See where it could go',
      'Help me brainstorm ideas for ',
    ),
    (
      LucideIcons.listChecks,
      'Make a plan',
      'Find a good next step',
      'Help me make a step-by-step plan for ',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: 24,
          vertical: compact ? 24 : 36,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: reduceMotion(context) ? 1 : 0, end: 1),
                duration: motionDuration(context, Motion.welcome),
                curve: Motion.pop,
                child: ProculLogo(size: compact ? 44 : 60),
                builder: (context, value, child) => Transform.rotate(
                  angle: -0.08 * (1 - value),
                  child: Transform.scale(
                    scale: 0.88 + 0.12 * value,
                    child: child,
                  ),
                ),
              ),
              Gap(compact ? 18 : 24),
              Stagger(
                index: 0,
                child: Text(
                  'What can we work on?',
                  style: TextStyle(
                    fontSize: compact ? 28 : 34,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1.1,
                    height: 1.15,
                    color: colors.foreground,
                  ),
                ),
              ),
              const Gap(12),
              Stagger(
                index: 1,
                child: Text(
                  'Ask a question, work through an idea, or make a plan.',
                  style: TextStyle(
                    fontSize: compact ? 14 : 16,
                    color: colors.mutedForeground,
                    height: 1.6,
                  ),
                ),
              ),
              Gap(compact ? 24 : 32),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 480 ? 2 : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final (index, starter) in _starters.indexed)
                        SizedBox(
                          width: width,
                          child: Stagger(
                            index: index + 2,
                            child: _StarterCard(
                              icon: starter.$1,
                              title: starter.$2,
                              subtitle: starter.$3,
                              onPressed: () => onSuggestion(starter.$4),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StarterCard extends StatefulWidget {
  const _StarterCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  @override
  State<_StarterCard> createState() => _StarterCardState();
}

class _StarterCardState extends State<_StarterCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final active = _hovered || _focused;
    return PressableScale(
      child: Clickable(
        onPressed: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        onFocus: (value) => setState(() => _focused = value),
        disableHoverEffect: true,
        child: AnimatedContainer(
          duration: motionDuration(context, Motion.medium),
          curve: Motion.curve,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: active ? colors.muted : colors.card.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _focused ? colors.ring : colors.border),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: active ? colors.primary : colors.mutedForeground,
              ),
              const Gap(14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Gap(5),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              AnimatedSlide(
                offset: active ? const Offset(0.2, 0) : Offset.zero,
                duration: motionDuration(context, Motion.medium),
                curve: Motion.pop,
                child: Icon(
                  LucideIcons.arrowUpRight,
                  size: 15,
                  color: colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
