import 'models.dart';

/// Token totals for the usage dashboard, mirroring the backend's `usage` DTOs.
///
/// `lifetime`, each day, and each model all share this shape; `turns` counts the
/// model calls the totals cover.
class UsageBreakdown {
  const UsageBreakdown({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.totalTokens = 0,
    this.turns = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int totalTokens;
  final int turns;

  factory UsageBreakdown.fromJson(Map<String, dynamic> json) => UsageBreakdown(
    inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    cachedInputTokens: (json['cachedInputTokens'] as num?)?.toInt() ?? 0,
    totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
    turns: (json['turns'] as num?)?.toInt() ?? 0,
  );

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cachedInputTokens == 0 &&
      totalTokens == 0;

  UsageBreakdown operator +(UsageBreakdown other) => UsageBreakdown(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
    totalTokens: totalTokens + other.totalTokens,
    turns: turns + other.turns,
  );

  /// The same counts as a chat-counter [TokenUsage].
  TokenUsage toTokenUsage() => TokenUsage(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    totalTokens: totalTokens,
    turns: turns,
  );
}

/// One UTC day's token totals (`date` is an ISO `yyyy-MM-dd` string).
class UsageDay {
  const UsageDay({required this.date, required this.totals});

  final String date;
  final UsageBreakdown totals;

  factory UsageDay.fromJson(Map<String, dynamic> json) => UsageDay(
    date: '${json['date'] ?? ''}',
    totals: UsageBreakdown.fromJson(json),
  );
}

/// One model's token totals over the selected window.
class UsageModel {
  const UsageModel({required this.model, required this.totals});

  final String model;
  final UsageBreakdown totals;

  factory UsageModel.fromJson(Map<String, dynamic> json) => UsageModel(
    model: '${json['model'] ?? ''}',
    totals: UsageBreakdown.fromJson(json),
  );
}

/// `GET /v1/usage` — lifetime totals plus a windowed per-day and per-model breakdown.
class UsageSummary {
  const UsageSummary({
    required this.lifetime,
    required this.days,
    required this.models,
  });

  final UsageBreakdown lifetime;
  final List<UsageDay> days;
  final List<UsageModel> models;

  factory UsageSummary.fromJson(Map<String, dynamic> json) => UsageSummary(
    lifetime: UsageBreakdown.fromJson(
      (json['lifetime'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    days: (json['days'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(UsageDay.fromJson)
        .toList(growable: false),
    models: (json['models'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(UsageModel.fromJson)
        .toList(growable: false),
  );
}
