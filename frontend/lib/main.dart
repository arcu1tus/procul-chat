import 'package:flutter/material.dart';

import 'src/chat_api.dart';
import 'src/chat_controller.dart';
import 'src/chat_screen.dart';

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
  late final ChatController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatController(api: ChatApi(baseUrl: apiBaseUrl));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Procul Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: ChatScreen(controller: _controller),
    );
  }
}
