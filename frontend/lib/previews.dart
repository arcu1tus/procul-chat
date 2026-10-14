import 'package:flutter/widget_previews.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'src/app_theme.dart';
import 'src/widgets/chat_welcome.dart';
import 'src/widgets/response_activity.dart';
import 'src/models.dart';

Widget lightPreview(Widget child) => ShadcnApp(
  theme: proculLightTheme,
  home: Scaffold(child: child),
);

Widget darkPreview(Widget child) => ShadcnApp(
  theme: proculDarkTheme,
  home: Scaffold(child: child),
);

@Preview(
  group: 'Chat',
  name: 'Welcome · light',
  size: Size(800, 650),
  wrapper: lightPreview,
)
@Preview(
  group: 'Chat',
  name: 'Welcome · dark',
  size: Size(800, 650),
  wrapper: darkPreview,
)
@Preview(
  group: 'Chat',
  name: 'Welcome · phone',
  size: Size(360, 650),
  wrapper: lightPreview,
)
Widget welcomePreview() => const _WelcomePreview();

class _WelcomePreview extends StatefulWidget {
  const _WelcomePreview();

  @override
  State<_WelcomePreview> createState() => _WelcomePreviewState();
}

class _WelcomePreviewState extends State<_WelcomePreview> {
  final _draft = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: ChatWelcome(
          onSuggestion: (text) {
            _draft.text = text;
            _focus.requestFocus();
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(24),
        child: TextField(
          controller: _draft,
          focusNode: _focus,
          placeholder: const Text('Try a starter above…'),
        ),
      ),
    ],
  );
}

@Preview(
  group: 'Chat',
  name: 'Response activity · light',
  size: Size(650, 350),
  wrapper: lightPreview,
)
@Preview(
  group: 'Chat',
  name: 'Response activity · dark',
  size: Size(650, 350),
  wrapper: darkPreview,
)
@Preview(
  group: 'Chat',
  name: 'Response activity · phone',
  size: Size(360, 450),
  wrapper: lightPreview,
)
Widget responseActivityPreview() => ResponseActivity(
  isStreaming: false,
  message: ChatMessage(
    text: 'Here is your answer.',
    role: MessageRole.assistant,
    reasoning: 'Provider-supplied reasoning appears here.',
    toolCalls: [
      ToolCall(
        id: 'clock',
        name: 'get_current_time',
        result: '2026-10-14T12:00:00Z',
        status: 'completed',
      ),
    ],
  ),
);
