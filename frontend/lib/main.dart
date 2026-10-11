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

void main() {
  runApp(const ProculChatApp());
}

class ProculChatApp extends StatefulWidget {
  const ProculChatApp({super.key});

  @override
  State<ProculChatApp> createState() => _ProculChatAppState();
}

class _ProculChatAppState extends State<ProculChatApp> {
  late final ChatController _chat;
  late final SettingsController _settings;

  @override
  void initState() {
    super.initState();
    _chat = ChatController(api: ChatApi(baseUrl: apiBaseUrl));
    _settings = SettingsController();
    _chat.init();
    _settings.init();
  }

  @override
  void dispose() {
    _chat.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return MaterialShadcnApp(
          title: 'Procul Chat',
          debugShowCheckedModeBanner: false,
          theme: proculLightTheme,
          darkTheme: proculDarkTheme,
          themeMode: _settings.themeMode,
          home: HomeShell(chat: _chat, settings: _settings),
        );
      },
    );
  }
}
