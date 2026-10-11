import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'chat_controller.dart';
import 'chat_screen.dart';
import 'conversation_sidebar.dart';
import 'model_catalog_controller.dart';
import 'models_screen.dart';
import 'settings_controller.dart';
import 'usage_screen.dart';

/// The app's root layout: a persistent sidebar next to the chat on wide
/// screens, and the chat alone (with a slide-in sidebar) on narrow ones.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.chat,
    required this.settings,
    required this.auth,
  });

  final ChatController chat;
  final SettingsController settings;
  final AuthController auth;

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

  /// Whether the main pane shows the usage dashboard instead of the chat. The
  /// chat stays mounted underneath so its scroll position and buffer survive.
  bool _showUsage = false;

  /// Whether the main pane shows the model catalog. Same overlay treatment.
  bool _showModels = false;

  /// The shared model catalog for the app-bar picker and the Models screen.
  late final ModelCatalogController _catalog;

  @override
  void initState() {
    super.initState();
    _catalog = ModelCatalogController(api: widget.chat.api);
    // Mirror the catalog's default into the controller so the app-bar picker
    // and a brand-new chat can fall back to it.
    _catalog.addListener(_syncDefaultModel);
    _catalog.load();
  }

  @override
  void dispose() {
    _catalog.removeListener(_syncDefaultModel);
    _catalog.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncDefaultModel() =>
      widget.chat.setDefaultModel(_catalog.defaultModel);

  void _openSidebar() {
    setState(() => _sidebarOpen = true);
    _controller.forward();
  }

  void _closeSidebar() {
    _controller.reverse().whenComplete(() {
      if (mounted) setState(() => _sidebarOpen = false);
    });
  }

  void _openUsage() {
    setState(() {
      _showUsage = true;
      _showModels = false;
    });
    _closeSidebar();
  }

  void _openModels() {
    setState(() {
      _showModels = true;
      _showUsage = false;
    });
    _closeSidebar();
  }

  void _openChat() {
    if (!_showUsage && !_showModels) return;
    setState(() {
      _showUsage = false;
      _showModels = false;
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
                    auth: widget.auth,
                    onOpenUsage: _openUsage,
                    onOpenModels: _openModels,
                    onOpenChat: _openChat,
                  ),
                ),
                Container(width: 1, color: colors.border),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ChatScreen(chat: widget.chat, catalog: _catalog),
                      ),
                      if (_showUsage)
                        Positioned.fill(
                          child: UsageScreen(api: widget.chat.api),
                        ),
                      if (_showModels)
                        Positioned.fill(child: ModelsScreen(catalog: _catalog)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Stack(
          children: [
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ChatScreen(
                      chat: widget.chat,
                      catalog: _catalog,
                      showMenuButton: true,
                      compactModelPicker: true,
                      onMenu: _openSidebar,
                    ),
                  ),
                  if (_showUsage)
                    Positioned.fill(
                      child: UsageScreen(
                        api: widget.chat.api,
                        showMenuButton: true,
                        onMenu: _openSidebar,
                      ),
                    ),
                  if (_showModels)
                    Positioned.fill(
                      child: ModelsScreen(
                        catalog: _catalog,
                        showMenuButton: true,
                        onMenu: _openSidebar,
                      ),
                    ),
                ],
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
                    auth: widget.auth,
                    onOpenUsage: _openUsage,
                    onOpenModels: _openModels,
                    onOpenChat: _openChat,
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
