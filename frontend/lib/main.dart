import 'dart:async';

import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'src/app_theme.dart';
import 'src/auth_controller.dart';
import 'src/chat_api.dart';
import 'src/chat_controller.dart';
import 'src/connect_screen.dart';
import 'src/home_shell.dart';
import 'src/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preload the stored theme, the saved server session and the web fonts
  // *before* the first frame so the app never flashes the wrong theme, the
  // Connect screen when already signed in, or a fallback face.
  final settings = SettingsController();
  final auth = AuthController();
  await _preload(settings, auth);

  runApp(ProculChatApp(settings: settings, auth: auth));
}

/// Best-effort startup preloading. Each step is guarded so a failure — most
/// likely an offline runtime font fetch — still lets the app start (falling
/// back to the platform face) instead of throwing before `runApp`.
Future<void> _preload(SettingsController settings, AuthController auth) async {
  try {
    await settings.init();
  } catch (_) {
    // Keep the default theme.
  }

  try {
    await auth.init();
  } catch (_) {
    // Start signed out.
  }

  try {
    await GoogleFonts.pendingFonts([interTextStyle]);
  } catch (_) {
    // Fonts are cosmetic; the platform face is fine.
  }
}

class ProculChatApp extends StatefulWidget {
  const ProculChatApp({super.key, required this.settings, required this.auth});

  final SettingsController settings;
  final AuthController auth;

  @override
  State<ProculChatApp> createState() => _ProculChatAppState();
}

class _ProculChatAppState extends State<ProculChatApp> {
  @override
  void dispose() {
    widget.settings.dispose();
    widget.auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        return MaterialShadcnApp(
          title: 'Procul Chat',
          debugShowCheckedModeBanner: false,
          theme: proculLightTheme,
          darkTheme: proculDarkTheme,
          themeMode: widget.settings.themeMode,
          builder: (context, child) =>
              ShadcnMaterialBridge(child: child ?? const SizedBox.shrink()),
          home: ListenableBuilder(
            listenable: widget.auth,
            builder: (context, _) {
              final session = widget.auth.active;
              if (session == null) {
                return ConnectScreen(auth: widget.auth);
              }
              return AuthenticatedShell(
                // Keyed by profile + token so switching sessions rebuilds the whole
                // shell (and a fresh ChatController) instead of leaking state.
                key: ValueKey((session.profile.id, session.token)),
                auth: widget.auth,
                settings: widget.settings,
              );
            },
          ),
        );
      },
    );
  }
}

/// Owns the [ChatController] for one authenticated server profile.
class AuthenticatedShell extends StatefulWidget {
  const AuthenticatedShell({
    super.key,
    required this.auth,
    required this.settings,
  });

  final AuthController auth;
  final SettingsController settings;

  @override
  State<AuthenticatedShell> createState() => _AuthenticatedShellState();
}

class _AuthenticatedShellState extends State<AuthenticatedShell>
    with WidgetsBindingObserver {
  late final ChatController _chat;
  Timer? _sessionTimer;
  bool _sessionChecked = false;
  bool _checkingSession = false;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    final session = widget.auth.active!;
    _chat = ChatController(
      api: ChatApi(
        baseUrl: session.baseUrl,
        token: session.token,
        // An expired / rejected token bounces the app back to the Connect
        // screen instead of leaving the user with silent failures.
        onUnauthorized: () => widget.auth.invalidateSession(session),
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    _validateSession();
    _sessionTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _validateSession(),
    );
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _chat.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _validateSession();
  }

  Future<void> _validateSession() async {
    if (_checkingSession) return;
    _checkingSession = true;
    try {
      await _chat.api.validateSession();
      if (!mounted) return;
      if (!_sessionChecked) {
        setState(() {
          _sessionChecked = true;
          _sessionError = null;
        });
        _chat.init();
      }
    } catch (e) {
      if (mounted && !_sessionChecked) setState(() => _sessionError = '$e');
    } finally {
      _checkingSession = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_sessionChecked) {
      return Scaffold(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_sessionError ?? 'Checking your session…'),
              if (_sessionError != null)
                OutlineButton(
                  onPressed: _validateSession,
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      );
    }
    return HomeShell(chat: _chat, settings: widget.settings, auth: widget.auth);
  }
}
