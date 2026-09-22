import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'src/feature_cache.dart';
import 'package:logging/logging.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

final _log = Logger('FeatureHub');

class FeatureHubConfig {
  final List<String> _apiKeys;
  final FeatureServiceApi _api;
  final ClientFeatureRepository _repository;
  String? xFeatureHubHeader;
  bool _deadConnection = false;
  DateTime _cacheTimeout;
  int _timeoutInSeconds;

  /// The shortest time that may elapse between two real API calls. While a
  /// cached payload is younger than this, [request] serves it instead of
  /// going to the network - the same contract as Firebase Remote Config's
  /// `minimumFetchInterval`.
  ///
  /// When null the SDK keeps its original behaviour, where the polling window
  /// is driven by [timeout] and the server's `Cache-Control` header.
  final Duration? minimumFetchInterval;

  /// Null when [minimumFetchInterval] was not supplied, in which case no
  /// caching is performed at all.
  final FeatureHubCache? _cache;

  /// True once the repository has been populated in this process, either from
  /// the cache or from a successful network call. Used to make sure a cache
  /// hit on a cold start still fills the repository.
  bool _repositoryPopulated = false;

  /// The feature keys the application expects the server to provide, usually
  /// the keys it holds local defaults for.
  ///
  /// Purely diagnostic - nothing is requested differently because of it. It
  /// lets [foundKeys] and [missingKeys] report whether the environment is
  /// actually configured the way the application assumes.
  final List<String> expectedKeys;

  FeatureHubConfig(String host, this._apiKeys, this._repository,
      {int timeout = 360,
      this.minimumFetchInterval,
      this.expectedKeys = const []})
      : _api = FeatureServiceApi(ApiClient(basePath: host)),
        _timeoutInSeconds = timeout,
        _cache = minimumFetchInterval == null
            ? null
            : FeatureHubCache(host, _apiKeys),
        _cacheTimeout = DateTime.now()
            .subtract(Duration(seconds: 1)) // allow for immediate polling
  {
    if (_apiKeys.any((key) => key.contains('*'))) {
      throw Exception(
          'You are using a client evaluated API Key in Dart and this is not supported.');
    }

    _repository.clientContext.registerChangeHandler((header) async {
      xFeatureHubHeader = header;
    });
  }

  bool get isConnectionDead => _deadConnection;
  int get timeoutInSeconds => _timeoutInSeconds;
  DateTime get whenNextPollAllowed => _cacheTimeout;

  /// The repository this config feeds. It is the same instance that was
  /// passed to the constructor and that [request] returns, exposed so that
  /// holders of a config do not have to carry the repository separately.
  ClientFeatureRepository get repository => _repository;

  /// True when this config was created with a [minimumFetchInterval] and is
  /// therefore caching payloads across restarts.
  bool get isCachingEnabled => _cache != null;

  /// Every key the server actually delivered.
  ///
  /// Deliberately not [ClientFeatureRepository.availableFeatures], which is
  /// misleading as a measure of what the server sent: `getFeatureState` uses
  /// `putIfAbsent`, so merely *reading* an unknown key inserts an empty
  /// placeholder into that map. A placeholder has no underlying
  /// `FeatureState` and therefore a null `key`, which is what distinguishes a
  /// real feature from a phantom one.
  List<String> get serverKeys => _repository.availableFeatures
      .whereType<String>()
      .where((k) => _repository.feature(k).key != null)
      .toList();

  /// The [expectedKeys] the server actually delivered.
  List<String> get foundKeys => expectedKeys
      .where((k) => _repository.feature(k).key != null)
      .toList();

  /// The [expectedKeys] the server did not deliver. These resolve to whatever
  /// local default the application holds, regardless of the console.
  List<String> get missingKeys => expectedKeys
      .where((k) => _repository.feature(k).key == null)
      .toList();

  /// When the currently cached payload was fetched from the server, or null
  /// if nothing is cached (or caching is disabled).
  Future<DateTime?> get lastFetchTime async => (await _cache?.read())?.fetchedAt;

  /// How old the currently cached payload is, or null if nothing is cached.
  Future<Duration?> get cacheAge async => (await _cache?.read())?.age;

  void success(List<FeatureEnvironmentCollection> environments) {
    final states = <FeatureState>[];
    environments.forEach((e) {
      e.features.forEach((f) {
        f.environmentId = e.id;
      });
      states.addAll(e.features);
    });

    _repository.notify(SSEResultState.features, states);
    _repositoryPopulated = true;
  }

  void decodeCacheControl(List<String> cacheControlHeader) {
    final reg = RegExp(r'max-age=(\d+)', caseSensitive: false);

    cacheControlHeader.forEach((header) {
      final match = reg.firstMatch(header);
      if (match != null && match.group(0) != null) {
        try {
          var cacheAge = int.parse(match.group(0).toString().substring(8));
          if (cacheAge > 0) {
            _timeoutInSeconds = cacheAge;
          }
        } catch (e) {}
      }
    });
  }

  void checkForCacheControl(ApiResponse response) {
    // When the caller has specified a minimum fetch interval that value is
    // authoritative and the server is not permitted to change the polling
    // rate, matching Firebase Remote Config's behaviour.
    if (minimumFetchInterval != null) return;

    if (response.headers.containsKey('cache-control')) {
      decodeCacheControl(response.headers['cache-control']!);
    }
  }

  /// Discards any cached payload so that the next call to [request] performs
  /// a real API call regardless of [minimumFetchInterval].
  ///
  /// Safe to call when caching is disabled, in which case it does nothing.
  Future<void> invalidateCache() async {
    await _cache?.clear();
    // Also reopen the legacy polling window so the next request is not
    // blocked by it either.
    _cacheTimeout = DateTime.now().subtract(Duration(seconds: 1));
  }

  Future<void> decodeResponse(ApiResponse response) async {
    if (response.statusCode == 200 || response.statusCode == 236) {
      checkForCacheControl(response);

      // The body is a single-subscription stream, so it is read to a string
      // once here: the string both feeds the decoder and is what gets cached.
      final raw = await utf8.decodeStream(response.body!);

      success(_decodePayload(raw));

      await _cache?.write(raw, _contextSha());

      if (response.statusCode == 236) {
        _log.warning(
            "featurehub: this environment has gone stale and will not receive further updates.");
        _deadConnection = true;
      }
    } else if (response.statusCode == 400 || response.statusCode == 404) {
      _repository.notify(SSEResultState.failure, null);
    }

    if (_timeoutInSeconds > 0) {
      _cacheTimeout = DateTime.now().add(Duration(seconds: _timeoutInSeconds));
    }
  }

  List<FeatureEnvironmentCollection> _decodePayload(String raw) {
    return (LocalApiClient.deserializeFromString(
            raw, 'List<FeatureEnvironmentCollection>') as List)
        .map((item) => item as FeatureEnvironmentCollection)
        .toList();
  }

  /// The sha of the current client context, used both as a cache-busting
  /// query parameter and to decide whether a cache entry is still applicable.
  String _contextSha() => xFeatureHubHeader == null
      ? '0'
      : sha256.convert(utf8.encode(xFeatureHubHeader!)).toString();

  Future<ClientFeatureRepository> request() async {
    if (_deadConnection) return _repository;

    final sha = _contextSha();

    if (_cache != null) {
      final cached = await _cache!.read();

      // A payload fetched under a different client context may hold different
      // values, so it is not reusable even if it is still young.
      if (cached != null && cached.contextSha == sha) {
        if (cached.age < minimumFetchInterval!) {
          // On a cold start the repository is empty even though the cache is
          // fresh, so fill it before handing it back.
          if (!_repositoryPopulated) {
            try {
              success(_decodePayload(cached.payload));
            } catch (e, s) {
              _log.warning(
                  'featurehub: cached payload could not be decoded, refetching',
                  e,
                  s);
              await _cache!.clear();
              return _fetch(sha);
            }
          }

          _log.fine(
              'featurehub: serving cached features, age ${cached.age} < $minimumFetchInterval');
          return _repository;
        }
      }

      return _fetch(sha);
    }

    if (DateTime.now().isBefore(_cacheTimeout)) return _repository;

    return _fetch(sha);
  }

  Future<ClientFeatureRepository> _fetch(String sha) async {
    final options = xFeatureHubHeader == null
        ? null
        : (Options()..headers = {'x-featurehub': xFeatureHubHeader});

    final response = await _api.apiDelegate
        .getFeatureStates(_apiKeys, options: options, contextSha: sha);

    await decodeResponse(response);

    return _repository;
  }
}
