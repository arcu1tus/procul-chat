import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file. The web fonts are not bundled, so keep
/// `google_fonts` from trying to fetch them over the network in tests; the
/// themes fall back to the platform face and no assertion depends on the face.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
