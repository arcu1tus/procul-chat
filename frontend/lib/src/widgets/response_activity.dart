import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../models.dart';

/// Saved provider reasoning and tool activity, reachable on touch and keyboard.
class ResponseActivity extends StatelessWidget {
  const ResponseActivity({
    super.key,
    required this.message,
    required this.isStreaming,
  });
  final ChatMessage message;
  final bool isStreaming;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (message.completionStatus != 'completed')
        Text('Response ${message.completionStatus}').muted.small,
      if (message.reasoning.isNotEmpty)
        ActivityDisclosure(
          label: isStreaming && message.phase == 'thinking'
              ? 'Thinking…'
              : 'Reasoning',
          details: message.reasoning,
        ),
      for (final call in message.toolCalls)
        ActivityDisclosure(
          label: call.isPending
              ? 'Running ${call.name}…'
              : call.hasFailed || call.status == 'failed'
              ? '${call.name} failed'
              : call.status == 'interrupted'
              ? '${call.name} interrupted'
              : 'Used ${call.name}',
          details: [
            if (call.arguments != null) 'Arguments: ${call.arguments}',
            if (call.result != null) 'Result: ${call.result}',
            if (call.error != null) 'Error: ${call.error}',
            if (call.result == null && call.status == 'completed')
              'Completed without a result.',
          ].join('\n\n'),
        ),
    ],
  );
}

class ActivityDisclosure extends StatefulWidget {
  const ActivityDisclosure({
    super.key,
    required this.label,
    required this.details,
  });
  final String label;
  final String details;
  @override
  State<ActivityDisclosure> createState() => _ActivityDisclosureState();
}

class _ActivityDisclosureState extends State<ActivityDisclosure> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        expanded: _expanded,
        child: GhostButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 14,
              ),
              const Gap(6),
              Flexible(child: Text(widget.label).muted.small),
            ],
          ),
        ),
      ),
      if (_expanded)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: SelectableText(widget.details).small,
        ),
    ],
  );
}
