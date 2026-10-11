/// Backend base URL compiled in at build/run time. Override with, e.g.:
/// `flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010`
///
/// Used only to pre-fill the "Add server" form on first run; the saved server
/// profile is what the app actually connects to afterwards.
const apiBaseUrl = String.fromEnvironment(
  'PROCUL_API_BASE',
  defaultValue: 'http://localhost:5010',
);
