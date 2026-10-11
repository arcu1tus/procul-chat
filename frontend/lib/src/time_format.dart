/// Renders a timestamp as a compact relative string: `just now`, `5m ago`,
/// `3h ago`, `2d ago`, or a `YYYY-MM-DD` date once it is older than a week.
///
/// Shared by the conversation sidebar and the Models screen health rows so the
/// two never drift apart.
String relativeTime(DateTime time) {
  final local = time.toLocal();
  final difference = DateTime.now().difference(local);
  if (difference.inSeconds < 60) return 'just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
