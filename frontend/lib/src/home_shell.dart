import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_controller.dart';
import 'chat_screen.dart';
import 'conversation_sidebar.dart';
import 'settings_controller.dart';

/// The app's root layout: a persistent sidebar next to the chat on wide
/// screens, and the chat alone (with a slide-in sidebar) on narrow ones.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.chat, required this.settings});

  final ChatController chat;
  final SettingsController settings;

  static const _sidebarBreakpoint = 840.0;
  static const _sidebarWidth = 300.0;
  static const _slideDuration = Duration(milliseconds: 180);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _sidebarOpen = false;

  void _openSidebar() => setState(() => _sidebarOpen = true);
  void _closeSidebar() => setState(() => _sidebarOpen = false);

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= HomeShell._sidebarBreakpoint) {
          return Container(
            color: colors.background,
            child: Row(
              children: [
                SizedBox(
                  width: HomeShell._sidebarWidth,
                  child: ConversationSidebar(
                    chat: widget.chat,
                    settings: widget.settings,
                  ),
                ),
                Container(width: 1, color: colors.border),
                Expanded(child: ChatScreen(chat: widget.chat)),
              ],
            ),
          );
        }

        return Stack(
          children: [
            Positioned.fill(
              child: ChatScreen(
                chat: widget.chat,
                showMenuButton: true,
                onMenu: _openSidebar,
              ),
            ),
            if (_sidebarOpen)
              Positioned.fill(
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: _closeSidebar,
                      child: Container(color: const Color(0x80000000)),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: HomeShell._sidebarWidth,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: -1, end: 0),
                        duration: HomeShell._slideDuration,
                        curve: Curves.easeOut,
                        builder: (context, value, child) =>
                            FractionalTranslation(
                              translation: Offset(value, 0),
                              child: child,
                            ),
                        child: ConversationSidebar(
                          chat: widget.chat,
                          settings: widget.settings,
                          onClose: _closeSidebar,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
