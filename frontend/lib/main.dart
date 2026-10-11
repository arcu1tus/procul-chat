import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'src/app_theme.dart';
import 'src/chat_api.dart';
import 'src/chat_controller.dart';
import 'src/home_shell.dart';
import 'src/settings_controller.dart';

/// Backend base URL. Override at build/run time with, e.g.:
/// `flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010`
const apiBaseUrl = String.fromEnvironment(
  'PROCUL_API_BASE',
  defaultValue: 'http://localhost:5010',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preload the stored theme and the web fonts *before* the first frame so the
  // app never flashes the default theme or a fallback face.
  final settings = SettingsController();
  await settings.init();
  await GoogleFonts.pendingFonts([interTextStyle, GoogleFonts.coiny()]);

  runApp(ProculChatApp(settings: settings));
}

class ProculChatApp extends StatefulWidget {
  const ProculChatApp({super.key, required this.settings});

  final SettingsController settings;

  @override
  State<ProculChatApp> createState() => _ProculChatAppState();
}

class _ProculChatAppState extends State<ProculChatApp> {
  late final ChatController _chat;

  @override
  void initState() {
    super.initState();
    _chat = ChatController(api: ChatApi(baseUrl: apiBaseUrl));
    _chat.init();
  }

  @override
  void dispose() {
    _chat.dispose();
    widget.settings.dispose();
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
          home: HomeShell(chat: _chat, settings: widget.settings),
        );
      },
    );
  }
}
