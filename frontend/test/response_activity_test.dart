import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/models.dart';
import 'package:procul_chat_flutter/src/widgets/response_activity.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  testWidgets(
    'historical reasoning is collapsed and tool details expand on tap',
    (tester) async {
      final message = ChatMessage.fromJson({
        'id': 'm',
        'text': 'answer',
        'messageRole': 2,
        'reasoning': 'visible reasoning',
        'toolCalls': [
          {
            'callId': 'c',
            'name': 'clock',
            'arguments': '{}',
            'result': null,
            'error': null,
            'status': 'completed',
          },
        ],
      });
      expect(message.toolCalls.single.isPending, isFalse);
      await tester.pumpWidget(
        ShadcnApp(
          theme: proculLightTheme,
          home: Scaffold(
            child: ResponseActivity(message: message, isStreaming: false),
          ),
        ),
      );
      expect(find.text('visible reasoning'), findsNothing);
      expect(find.text('Used clock'), findsOneWidget);
      await tester.tap(find.text('Reasoning'));
      await tester.pump();
      expect(find.text('visible reasoning'), findsOneWidget);
      await tester.tap(find.text('Used clock'));
      await tester.pump();
      expect(
        find.textContaining('Completed without a result.'),
        findsOneWidget,
      );
    },
  );
}
