import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'attachments.dart';
import 'auth_controller.dart';
import 'chat_controller.dart';
import 'chat_screen.dart';
import 'conversation_sidebar.dart';
import 'model_catalog_controller.dart';
import 'models_screen.dart';
import 'motion.dart';
import 'settings_controller.dart';
import 'settings_screen.dart';
import 'usage_screen.dart';

/// The app's root layout: a persistent sidebar next to the chat on wide
/// screens, and the chat alone (with a slide-in sidebar) on narrow ones.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.chat,
    required this.settings,
    required this.auth,
    this.attachmentPicker = const FilePickerAttachmentPicker(),
  });

  final ChatController chat;
  final SettingsController settings;
  final AuthController auth;

  /// Picks and saves attachment files for the chat pane (injected in tests).
  final AttachmentPicker attachmentPicker;

  static const _sidebarBreakpoint = 840.0;
  static const _sidebarWidth = 300.0;
  static const _slideDuration = Duration(milliseconds: 200);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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

  /// Which destination the main pane shows. The chat is always mounted
  /// underneath, so its scroll position and buffer survive a switch to Usage,
  /// Models or Settings.
  SidebarSection _section = SidebarSection.chat;

  /// The shared model catalog for the app-bar picker and the Models screen.
  late final ModelCatalogController _catalog;

  /// A light periodic sync so two devices on the same backend stay roughly in
  /// step. Cancellable; never fires mid-stream or mid-edit.
  Timer? _syncTimer;
  static const _syncInterval = Duration(seconds: 25);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _catalog = ModelCatalogController(api: widget.chat.api);
    // Mirror the catalog's default into the controller so the app-bar picker
    // and a brand-new chat can fall back to it.
    _catalog.addListener(_syncDefaultModel);
    _catalog.load();
    _syncTimer = Timer.periodic(_syncInterval, (_) => _sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _catalog.removeListener(_syncDefaultModel);
    _catalog.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync();
  }

  /// Refreshes from the server when it is safe to do so: never while a reply
  /// streams, the user is editing, or a refresh is already running.
  ///
  /// The active conversation is *merged* (see
  /// [ChatController.syncActiveConversation]) rather than reloaded, so a
  /// background tick never discards history loaded by infinite scroll or yanks
  /// the viewport to the newest message.
  void _sync() {
    final chat = widget.chat;
    if (chat.isStreaming || chat.isEditing || chat.isRefreshing) return;
    chat.refreshConversations();
    chat.syncActiveConversation();
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

  void _openUsage() => _select(SidebarSection.usage);

  void _openModels() => _select(SidebarSection.models);

  void _openSettings() => _select(SidebarSection.settings);

  void _openChat() => _select(SidebarSection.chat);

  /// Switches the main pane's destination. The chat stays mounted; the selected
  /// pane is overlaid on top.
  void _select(SidebarSection section) {
    if (section != SidebarSection.chat || _section != SidebarSection.chat) {
      setState(() => _section = section);
    }
    _closeSidebar();
  }

  /// The main pane: the chat, always mounted, with the selected destination
  /// (Usage / Models / Settings) cross-faded in on top.
  ///
  /// The transition is a shared-axis fade + slide driven by [Motion] tokens, so
  /// switching destinations never snaps. The chat sits underneath so its scroll
  /// position and buffer survive.
  Widget _mainPane({required bool narrow}) {
    return Stack(
      children: [
        Positioned.fill(
          child: ChatScreen(
            chat: widget.chat,
            catalog: _catalog,
            picker: widget.attachmentPicker,
            showMenuButton: narrow,
            compactModelPicker: narrow,
            compactActions: narrow,
            onMenu: narrow ? _openSidebar : null,
          ),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: motionDuration(context, Motion.medium),
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.emphasized,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.03, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _sectionPane(narrow),
          ),
        ),
      ],
    );
  }

  Widget _sectionPane(bool narrow) {
    final onMenu = narrow ? _openSidebar : null;
    switch (_section) {
      case SidebarSection.chat:
        return const SizedBox.shrink(key: ValueKey('pane-chat'));
      case SidebarSection.usage:
        return UsageScreen(
          key: const ValueKey('pane-usage'),
          api: widget.chat.api,
          showMenuButton: narrow,
          onMenu: onMenu,
        );
      case SidebarSection.models:
        return ModelsScreen(
          key: const ValueKey('pane-models'),
          catalog: _catalog,
          showMenuButton: narrow,
          onMenu: onMenu,
        );
      case SidebarSection.settings:
        return SettingsScreen(
          key: const ValueKey('pane-settings'),
          settings: widget.settings,
          auth: widget.auth,
          api: widget.chat.api,
          showMenuButton: narrow,
          onMenu: onMenu,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    // Respect the platform's reduced-motion preference for the panel slide.
    _controller.duration = reduceMotion(context)
        ? Duration.zero
        : HomeShell._slideDuration;

    // shadcn's `showDropdown` presents as a bottom sheet on mobile platforms,
    // which routes through `openRawDrawer` and asserts a `DrawerOverlay`
    // ancestor. The chat pane has one via its `Scaffold`, but the sidebar (and
    // the whole shell on narrow screens) does not — so without this wrapper the
    // conversation-tile `…` menu silently fails on Android/iOS. One root layer
    // here covers every dropdown in the shell.
    return DrawerOverlay(
      child: LayoutBuilder(
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
                      section: _section,
                      onOpenUsage: _openUsage,
                      onOpenModels: _openModels,
                      onOpenSettings: _openSettings,
                      onOpenChat: _openChat,
                    ),
                  ),
                  Container(width: 1, color: colors.border),
                  Expanded(child: _mainPane(narrow: false)),
                ],
              ),
            );
          }

          return Stack(
            children: [
              Positioned.fill(child: _mainPane(narrow: true)),
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
                      section: _section,
                      onOpenUsage: _openUsage,
                      onOpenModels: _openModels,
                      onOpenSettings: _openSettings,
                      onOpenChat: _openChat,
                      onClose: _closeSidebar,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
