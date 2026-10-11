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
  static const _slideDuration = Duration(milliseconds: 200);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  /// 0 = fully hidden, 1 = fully open. Drives both the panel's slide and the
  /// scrim's fade, so the two stay in step and the scrim can animate *out*.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: HomeShell._slideDuration,
  );
  late final Animation<double> _eased = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  bool _sidebarOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSidebar() {
    setState(() => _sidebarOpen = true);
    _controller.forward();
  }

  void _closeSidebar() {
    _controller.reverse().whenComplete(() {
      if (mounted) setState(() => _sidebarOpen = false);
    });
  }

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
                child: AnimatedBuilder(
                  animation: _eased,
                  builder: (context, child) => Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: _closeSidebar,
                          behavior: HitTestBehavior.opaque,
                          child: ColoredBox(
                            color: const Color(0xFF000000)
                                .withValues(alpha: 0.5 * _eased.value),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: HomeShell._sidebarWidth,
                        child: FractionalTranslation(
                          translation: Offset(_eased.value - 1, 0),
                          child: child,
                        ),
                      ),
                    ],
                  ),
                  child: ConversationSidebar(
                    chat: widget.chat,
                    settings: widget.settings,
                    onClose: _closeSidebar,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
