/// Shared `GET /v1/models` payloads for tests, so the model catalog, the
/// picker, and the Models screen are exercised against one fixture.
library;

/// Two models: a healthy default that accepts images, and an unhealthy
/// non-default that accepts audio and `pdf` (which maps to the `file` badge).
const testModelsJson = <String, dynamic>{
  'defaultModel': 'openai/gpt-4o-mini',
  'models': [
    {
      'slug': 'openai/gpt-4o-mini',
      'name': 'GPT-4o mini',
      'description': 'Fast and cheap',
      'provider': 'openrouter',
      'isDefault': true,
      'capabilities': {
        'input': ['text', 'image'],
        'output': ['text'],
      },
      'health': {
        'status': 'healthy',
        'lastCheckedAt': '2026-10-11T12:00:00Z',
        'latencyMs': 123,
        'lastError': null,
        'lastUsedAt': '2026-10-11T12:05:00Z',
        'source': 'startup',
      },
    },
    {
      'slug': 'local/llama',
      'name': 'Llama',
      'description': null,
      'provider': 'openai-compatible',
      'isDefault': false,
      'capabilities': {
        'input': ['text', 'audio', 'pdf'],
        'output': ['text'],
      },
      'health': {
        'status': 'unhealthy',
        'lastCheckedAt': '2026-10-11T11:00:00Z',
        'latencyMs': null,
        'lastError': 'connection refused',
        'lastUsedAt': null,
        'source': 'idle',
      },
    },
  ],
};

/// A single-model payload, so the app-bar picker stays hidden (nothing to pick).
const testSingleModelJson = <String, dynamic>{
  'defaultModel': 'solo',
  'models': [
    {
      'slug': 'solo',
      'name': 'Solo',
      'provider': 'openai-compatible',
      'isDefault': true,
      'capabilities': {
        'input': ['text'],
        'output': ['text'],
      },
      'health': {'status': 'healthy'},
    },
  ],
};
