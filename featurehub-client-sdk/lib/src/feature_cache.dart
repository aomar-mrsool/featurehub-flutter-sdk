import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger('FeatureHub');

/// A feature payload that was previously fetched from the server, together
/// with the moment it was fetched so its age can be determined.
class CachedFeatures {
  /// The raw JSON body exactly as the server returned it. Kept as a string
  /// rather than as decoded models so that it round-trips through storage
  /// without depending on the generated model classes staying stable.
  final String payload;

  /// When [payload] was received from the server.
  final DateTime fetchedAt;

  /// The `contextSha` that was in effect when [payload] was fetched. If the
  /// client context changes the server may return different values, so a
  /// cache entry recorded under a different sha must not be reused.
  final String contextSha;

  CachedFeatures({
    required this.payload,
    required this.fetchedAt,
    required this.contextSha,
  });

  /// How long ago this entry was fetched.
  Duration get age => DateTime.now().difference(fetchedAt);

  Map<String, dynamic> toJson() => {
        'payload': payload,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        'contextSha': contextSha,
      };

  static CachedFeatures? fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    final fetchedAt = json['fetchedAt'];
    final contextSha = json['contextSha'];

    if (payload is! String || fetchedAt is! String) return null;

    final parsed = DateTime.tryParse(fetchedAt);
    if (parsed == null) return null;

    return CachedFeatures(
      payload: payload,
      fetchedAt: parsed.toLocal(),
      contextSha: contextSha is String ? contextSha : '0',
    );
  }

  @override
  String toString() =>
      'CachedFeatures[fetchedAt=$fetchedAt, age=$age, contextSha=$contextSha, '
      'bytes=${payload.length}]';
}

/// Persists the most recent successful feature payload so that it survives an
/// application restart, in the manner of Firebase Remote Config.
///
/// Backed by `shared_preferences`. Entries are keyed by host and API keys, so
/// pointing at a different environment will not read another environment's
/// cache.
class FeatureHubCache {
  static const _keyPrefix = 'featurehub_cache_';

  final String _storageKey;

  /// Mirrors what is in storage so that the common path does not have to go
  /// back to `shared_preferences` on every request.
  CachedFeatures? _memory;
  bool _loaded = false;

  FeatureHubCache(String host, List<String> apiKeys)
      : _storageKey = _keyPrefix +
            sha256
                .convert(utf8.encode('$host|${apiKeys.join(',')}'))
                .toString()
                .substring(0, 32);

  /// Visible for testing and diagnostics.
  String get storageKey => _storageKey;

  /// The currently known entry, or null if nothing is cached. Returns the
  /// in-memory copy once loaded, otherwise reads from storage.
  Future<CachedFeatures?> read() async {
    if (_loaded) return _memory;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);

      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _memory = CachedFeatures.fromJson(decoded);
        }
      }
    } catch (e, s) {
      // A corrupt or unreadable cache must never stop the SDK working - the
      // caller simply falls through to a network request.
      _log.warning('featurehub: unable to read feature cache', e, s);
      _memory = null;
    }

    _loaded = true;
    return _memory;
  }

  /// Stores [payload] against the current time.
  Future<CachedFeatures> write(String payload, String contextSha) async {
    final entry = CachedFeatures(
      payload: payload,
      fetchedAt: DateTime.now(),
      contextSha: contextSha,
    );

    _memory = entry;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(entry.toJson()));
    } catch (e, s) {
      // Keep the in-memory copy - losing durability is not worth failing the
      // request that just succeeded.
      _log.warning('featurehub: unable to persist feature cache', e, s);
    }

    return entry;
  }

  /// Removes the cached payload so the next request performs a real API call.
  Future<void> clear() async {
    _memory = null;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (e, s) {
      _log.warning('featurehub: unable to clear feature cache', e, s);
    }
  }
}
