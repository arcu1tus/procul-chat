import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/widgets/composer.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

Future<void> _shiftEnter(WidgetTester tester, LogicalKeyboardKey shift) async {
  await tester.sendKeyDownEvent(shift);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(shift);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Shift+Enter inserts at the caret and replaces a selection', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok'),
    );
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    addTearDown(chat.dispose);
    var sends = 0;
    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        home: Align(
          alignment: Alignment.bottomCenter,
          child: Composer(
            controller: controller,
            focusNode: focus,
            chat: chat,
            onSubmit: () => sends++,
            onAttach: (_) {},
            onCancelEdit: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (kIsWeb) {
      // Headless Chrome needs an active view for hardware keyboard events.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.platformDispatcher.onViewFocusChange?.call(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.focused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await tester.pumpAndSettle();
    }
    focus.requestFocus();
    controller.value = const TextEditingValue(
      text: 'Hello world',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pumpAndSettle();
    // Chrome can return focus to the route while opening the input connection.
    focus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    expect(focus.hasFocus, isTrue);
    expect(controller.text, 'Hello world');
    await _shiftEnter(tester, LogicalKeyboardKey.shiftLeft);
    expect(controller.text, 'Hello\n world');
    expect(controller.selection.baseOffset, 6);
    expect(sends, 0);

    controller.selection = const TextSelection(baseOffset: 12, extentOffset: 7);
    await _shiftEnter(tester, LogicalKeyboardKey.shiftRight);
    expect(controller.text, 'Hello\n \n');
    expect(controller.selection.baseOffset, 8);
    expect(sends, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(controller.text, 'Hello\n \n');
    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.send,
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(sends, 2);
    expect(tester.takeException(), isNull);
  });
}
