import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in FeatureHub edge server that counts how many times it was
/// actually called, so the tests can assert on real network traffic rather
/// than on the SDK's own bookkeeping.
class _FakeEdge {
  late HttpServer _server;
  int callCount = 0;
  bool Function(HttpRequest)? respond;

  String flagValue = 'first';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      callCount++;
      if (respond != null && respond!(req)) {
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..write(_payload(flagValue));
      await req.response.close();
    });
  }

  String get host => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);

  static String _payload(String value) => jsonEncode([
        {
          'id': 'env-1',
          'features': [
            {
              'id': 'f1',
              'key': 'my_flag',
              'version': 1,
              'type': 'STRING',
              'value': value,
            }
          ]
        }
      ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding installs an HttpOverrides that answers every real
  // request with a 400. These tests talk to a loopback server on purpose.
  HttpOverrides.global = null;

  late _FakeEdge edge;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    edge = _FakeEdge();
    await edge.start();
  });

  tearDown(() async {
    await edge.stop();
  });

  test('a request inside minimumFetchInterval is served from cache', () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1));

    await config.request();
    expect(edge.callCount, 1);
    expect(repo.getString('my_flag'), 'first');

    // The server would now answer differently, so if a call were made the
    // repository would change.
    edge.flagValue = 'second';

    await config.request();
    await config.request();

    expect(edge.callCount, 1, reason: 'no further API calls should be made');
    expect(repo.getString('my_flag'), 'first');
  });

  test('a request past minimumFetchInterval refetches and updates the cache',
      () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(milliseconds: 250));

    await config.request();
    expect(edge.callCount, 1);
    expect(repo.getString('my_flag'), 'first');

    edge.flagValue = 'second';
    await Future.delayed(Duration(milliseconds: 400));

    await config.request();

    expect(edge.callCount, 2);
    expect(repo.getString('my_flag'), 'second');
    expect((await config.cacheAge)!.inMilliseconds, lessThan(250));
  });

  test('invalidateCache forces the next request to hit the API', () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1));

    await config.request();
    expect(edge.callCount, 1);

    edge.flagValue = 'second';

    await config.request();
    expect(edge.callCount, 1, reason: 'still inside the interval');

    await config.invalidateCache();
    await config.request();

    expect(edge.callCount, 2);
    expect(repo.getString('my_flag'), 'second');
    expect(await config.lastFetchTime, isNotNull);
  });

  test('a cold start hydrates the repository from cache without a call',
      () async {
    final firstRepo = ClientFeatureRepository();
    final firstConfig = FeatureHubConfig(edge.host, ['env-1/key-1'], firstRepo,
        minimumFetchInterval: Duration(hours: 1));

    await firstConfig.request();
    expect(edge.callCount, 1);

    // Simulate an app restart: brand new repository and config objects, but
    // the same persisted shared_preferences store.
    final secondRepo = ClientFeatureRepository();
    final secondConfig = FeatureHubConfig(edge.host, ['env-1/key-1'], secondRepo,
        minimumFetchInterval: Duration(hours: 1));

    expect(secondRepo.getString('my_flag'), isNull,
        reason: 'repository starts empty');

    await secondConfig.request();

    expect(edge.callCount, 1, reason: 'cache was still fresh, no API call');
    expect(secondRepo.getString('my_flag'), 'first',
        reason: 'repository filled from the persisted cache');
    expect(secondRepo.readyness, Readyness.Ready);
  });

  test('the cache is keyed per host and api key', () async {
    final repoA = ClientFeatureRepository();
    await FeatureHubConfig(edge.host, ['env-1/key-1'], repoA,
            minimumFetchInterval: Duration(hours: 1))
        .request();
    expect(edge.callCount, 1);

    // Different API key - must not reuse the first entry.
    final repoB = ClientFeatureRepository();
    await FeatureHubConfig(edge.host, ['env-2/key-2'], repoB,
            minimumFetchInterval: Duration(hours: 1))
        .request();

    expect(edge.callCount, 2);
  });

  test('a corrupt cache entry falls back to the network', () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1));

    await config.request();
    expect(edge.callCount, 1);

    // Corrupt the stored payload, keeping the envelope valid so it is the
    // decode of the features that fails.
    final prefs = await SharedPreferences.getInstance();
    final key =
        prefs.getKeys().firstWhere((k) => k.contains('featurehub_cache_'));
    prefs.setString(
        key,
        jsonEncode({
          'payload': 'not json at all',
          'fetchedAt': DateTime.now().toUtc().toIso8601String(),
          'contextSha': '0',
        }));

    final coldRepo = ClientFeatureRepository();
    final coldConfig = FeatureHubConfig(edge.host, ['env-1/key-1'], coldRepo,
        minimumFetchInterval: Duration(hours: 1));

    await coldConfig.request();

    expect(edge.callCount, 2, reason: 'bad cache must not be fatal');
    expect(coldRepo.getString('my_flag'), 'first');
  });

  test('caching is off and Cache-Control still applies without the interval',
      () async {
    edge.respond = (req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..headers.set('cache-control', 'max-age=42, private')
        ..write(_FakeEdge._payload('first'));
      return true;
    };

    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo);

    await config.request();

    expect(config.isCachingEnabled, isFalse);
    expect(config.timeoutInSeconds, 42,
        reason: 'legacy Cache-Control handling is untouched');
    expect(await config.lastFetchTime, isNull);
  });

  test('expectedKeys reports found and missing keys', () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1),
        expectedKeys: ['my_flag', 'absent_one', 'absent_two']);

    await config.request();

    expect(config.expectedKeys.length, 3);
    expect(config.foundKeys, ['my_flag']);
    expect(config.missingKeys, ['absent_one', 'absent_two']);
    expect(config.serverKeys, ['my_flag']);
  });

  test('reading an absent key does not make it look present', () async {
    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1),
        expectedKeys: ['my_flag', 'absent_one']);

    await config.request();

    // getFeatureState uses putIfAbsent, so this inserts a placeholder and
    // inflates availableFeatures. The diagnostics must not be fooled by it.
    expect(repo.getString('absent_one'), isNull);
    expect(repo.getFlag('never_declared'), isNull);

    expect(repo.availableFeatures.length, greaterThan(1),
        reason: 'placeholders really do accumulate');

    expect(config.foundKeys, ['my_flag']);
    expect(config.missingKeys, ['absent_one']);
    expect(config.serverKeys, ['my_flag']);
  });

  test('minimumFetchInterval overrides the server Cache-Control header',
      () async {
    edge.respond = (req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..headers.set('cache-control', 'max-age=1, private')
        ..write(_FakeEdge._payload('first'));
      return true;
    };

    final repo = ClientFeatureRepository();
    final config = FeatureHubConfig(edge.host, ['env-1/key-1'], repo,
        minimumFetchInterval: Duration(hours: 1));

    await config.request();
    expect(edge.callCount, 1);

    // The server asked to be re-polled after a second; the client interval
    // must win.
    await Future.delayed(Duration(milliseconds: 1200));
    await config.request();

    expect(edge.callCount, 1);
    expect(config.timeoutInSeconds, 360,
        reason: 'server max-age must be ignored');
  });
}
