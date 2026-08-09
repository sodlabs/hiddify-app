// lib/features/gfp/gfp_proxy_tester.dart
//
// Port Dart de gfp-fetcher/src/tester.js. Test "tier 1" bon marché : est-ce
// que quelque chose répond sur host:port, et si un SNI est présent dans
// l'URI (typique Reality/TLS), est-ce que le handshake TLS aboutit.
//
// Contrairement au fetcher Node (qui tournait sur un seul poste), ici
// chaque test se fait depuis l'appareil de l'utilisateur final -- c'est
// tout l'intérêt du passage au 100% client-side.

import 'dart:io';

import 'gfp_proxy_models.dart';

class GfpTestResult {
  GfpTestResult({required this.reachable, this.latencyMs, required this.stage, this.error});

  final bool reachable;
  final int? latencyMs;
  final String stage;
  final String? error;
}

/// Teste un candidat : TCP d'abord, puis upgrade TLS si un SNI est présent
/// dans l'URI d'origine. Ne lève jamais d'exception -- toute erreur devient
/// un GfpTestResult(reachable: false), même chose que le try/catch
/// défensif ajouté côté Node après le crash rencontré en production.
Future<GfpTestResult> testCandidate(
  GfpProxyCandidate candidate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final start = DateTime.now();
  Socket socket;

  try {
    socket = await Socket.connect(candidate.host, candidate.port).timeout(timeout);
  } catch (e) {
    return GfpTestResult(reachable: false, stage: 'tcp', error: e.toString());
  }

  String? sni;
  try {
    final uri = Uri.parse(candidate.raw);
    final value = uri.queryParameters['sni'];
    if (value != null && value.isNotEmpty) sni = value;
  } catch (_) {
    sni = null;
  }

  if (sni == null) {
    // Pas de SNI attendu dans la config : le TCP est jugé suffisant,
    // même logique que côté Node.
    final latency = DateTime.now().difference(start).inMilliseconds;
    socket.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tcp');
  }

  // Le SNI ne peut jamais être une adresse IP (même contrainte que
  // net.isIP() côté Node -- ici InternetAddress.tryParse()). Beaucoup de
  // configs ont un sni vide ou égal à une IP : dans ce cas on fait le
  // handshake TLS sans host de vérification plutôt que de planter.
  final sniIsIp = InternetAddress.tryParse(sni) != null;

  try {
    final secure = await SecureSocket.secure(
      socket,
      host: sniIsIp ? null : sni,
      onBadCertificate: (cert) => true, // on veut juste voir si TLS répond
    ).timeout(timeout);
    final latency = DateTime.now().difference(start).inMilliseconds;
    secure.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tls');
  } catch (e) {
    socket.destroy();
    return GfpTestResult(reachable: false, stage: 'tls', error: e.toString());
  }
}

/// Teste une liste de candidats avec une limite de concurrence, via un
/// pool de workers manuel (pas de dépendance externe). Aucun await entre
/// la lecture et l'incrémentation de l'index -> pas de course possible
/// même si Dart est mono-thread côté event loop.
Future<List<GfpProxyCandidate>> testAll(
  List<GfpProxyCandidate> candidates, {
  int concurrency = 40,
  Duration timeout = const Duration(seconds: 4),
  void Function(int done, int total)? onProgress,
}) async {
  if (candidates.isEmpty) return [];

  final results = List<GfpProxyCandidate?>.filled(candidates.length, null);
  var index = 0;
  var done = 0;

  Future<void> worker() async {
    while (true) {
      final i = index;
      if (i >= candidates.length) return;
      index++;

      final candidate = candidates[i];
      final result = await testCandidate(candidate, timeout: timeout);
      results[i] = candidate.copyWith(
        reachable: result.reachable,
        latencyMs: result.latencyMs,
      );
      done++;
      onProgress?.call(done, candidates.length);
    }
  }

  final workerCount = concurrency < candidates.length ? concurrency : candidates.length;
  await Future.wait(List.generate(workerCount, (_) => worker()));

  return results.whereType<GfpProxyCandidate>().toList();
}
