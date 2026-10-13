import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'auth_controller.dart';
import 'server_profile.dart';
import 'widgets/app_dialog.dart';
import 'widgets/icon_action.dart';

/// The "add server" form: Name (optional), Base URL and Password, plus the
/// Connect action and inline error / plain-HTTP warning.
///
/// Shared by the first-run Connect screen (embedded) and the Settings
/// "Add server" modal (via [showAddServerDialog]) so there is one
/// implementation.
class ServerForm extends StatefulWidget {
  const ServerForm({
    super.key,
    required this.auth,
    this.initialBaseUrl,
    this.initialName,
    this.onConnected,
    this.showSubmitButton = true,
    this.autofocusPassword = false,
  });

  final AuthController auth;

  /// Pre-fills the Base URL field (the Connect screen passes the dart-define).
  final String? initialBaseUrl;

  /// Pre-fills the Name field (used when a saved server is selected).
  final String? initialName;

  /// Called after a successful connect.
  final VoidCallback? onConnected;

  /// Whether to render the form's own Connect button. The modal hides it and
  /// drives [ServerFormState.submit] from the dialog's Save action instead.
  final bool showSubmitButton;

  final bool autofocusPassword;

  @override
  ServerFormState createState() => ServerFormState();
}

class ServerFormState extends State<ServerForm> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  final TextEditingController _password = TextEditingController();

  String? _localError;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName ?? '');
    _url = TextEditingController(text: widget.initialBaseUrl ?? '');
    _url.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onUrlChanged() => setState(() {});

  /// Validates the fields and attempts to connect. Returns whether it
  /// succeeded, so a hosting dialog can decide to stay open.
  Future<bool> submit() async {
    final rawUrl = _url.text.trim();

    if (parseServerBaseUrl(rawUrl) == null) {
      setState(() => _localError = 'Enter a valid http(s) server URL.');
      return false;
    }
    if (_password.text.isEmpty) {
      setState(() => _localError = 'Enter the password.');
      return false;
    }

    setState(() => _localError = null);

    final connected = await widget.auth.connect(
      baseUrl: rawUrl,
      password: _password.text,
      name: _name.text,
    );

    if (connected) {
      _password.clear();
      widget.onConnected?.call();
    }
    return connected;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);

    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final error = _localError ?? widget.auth.error;
        final warning = _plainHttpWarning(_url.text);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Server name (optional)').small.medium,
            const Gap(6),
            TextField(
              controller: _name,
              placeholder: const Text('Name (optional)'),
            ),
            const Gap(16),
            const Text('Server address').small.medium,
            const Gap(6),
            TextField(
              controller: _url,
              placeholder: const Text('Server URL'),
              autofocus: !widget.autofocusPassword,
            ),
            const Gap(16),
            const Text('Server password').small.medium,
            const Gap(6),
            TextField(
              controller: _password,
              placeholder: const Text('Password'),
              obscureText: !_showPassword,
              features: [
                InputFeature.trailing(
                  IconAction(
                    icon: _showPassword ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 16,
                    label: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ],
              autofocus: widget.autofocusPassword,
              onSubmitted: (_) => submit(),
            ),
            if (warning != null) ...[
              const Gap(10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.triangleAlert,
                    size: 15,
                    color: colors.destructive,
                  ),
                  const Gap(8),
                  Expanded(
                    child: Text(
                      warning,
                      style: TextStyle(color: colors.destructive, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            if (error != null) ...[
              const Gap(10),
              Text(
                error,
                style: TextStyle(color: colors.destructive, fontSize: 13),
              ),
            ],
            if (widget.showSubmitButton) ...[
              const Gap(16),
              PrimaryButton(
                onPressed: widget.auth.isLoading ? null : submit,
                child: Text(widget.auth.isLoading ? 'Connecting…' : 'Connect'),
              ),
            ],
          ],
        );
      },
    );
  }
}

String? _plainHttpWarning(String raw) {
  final uri = parseServerBaseUrl(raw);
  if (uri == null || uri.scheme != 'http' || isLocalHost(uri.host)) {
    return null;
  }
  return 'This server is not localhost and uses plain HTTP, so your password and '
      'messages are sent unencrypted.';
}

/// Opens the shared "add server" modal. Returns whether a server was added and
/// connected.
Future<bool> showAddServerDialog(
  BuildContext context,
  AuthController auth, {
  String? initialBaseUrl,
}) async {
  auth.clearError();
  final formKey = GlobalKey<ServerFormState>();

  final connected = await showAppDialog<bool>(
    context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Add server'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ServerForm(
            key: formKey,
            auth: auth,
            initialBaseUrl: initialBaseUrl,
            autofocusPassword: true,
            showSubmitButton: false,
            onConnected: () => Navigator.pop(context, true),
          ),
        ),
        actions: [
          OutlineButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          PrimaryButton(
            child: const Text('Save'),
            onPressed: () => formKey.currentState?.submit(),
          ),
        ],
      );
    },
  );

  return connected ?? false;
}

/// Confirms and removes [profile]. Removing the active server logs out.
Future<void> confirmRemoveServer(
  BuildContext context,
  AuthController auth,
  ServerProfile profile,
) async {
  final confirmed = await showAppDialog<bool>(
    context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Remove server?'),
        content: Text(
          'This removes "${profile.name}" (${profile.baseUrl}) and its saved '
          'session from this device.',
        ),
        actions: [
          OutlineButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          DestructiveButton(
            child: const Text('Remove'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    await auth.removeProfile(profile.id);
  }
}
