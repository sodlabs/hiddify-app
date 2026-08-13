// lib/features/gfp/gfp_proxy_tester.dart
//
// Port Dart de gfp-fetcher/src/tester.js. Test "tier 1" bon marché : est-ce
// que quelque chose répond sur host:port, et si un SNI est présent dans
// l'URI (typique Reality/TLS), est-ce que le handshake TLS aboutit.
//
// Contrairement au fetcher Node (qui tournait sur un seul poste), ici
// chaque test se fait depuis l'appareil de l'utilisateur final -- c'est
// tout l'intérêt du passage au 100% client-side.

import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/gfp/gfp_proxy_models.dart';

class GfpTestResult {
  GfpTestResult({required this.reachable, this.latencyMs, required this.stage, this.error});

  final bool reachable;
  final int? latencyMs;
  final String stage;
  final String? error;
}

/// Teste un candidat : TCP d'abord, puis handshake TLS seulement pour les
/// protocoles qui parlent réellement TLS standard. Ne lève jamais d'exception -- toute erreur devient
/// un GfpTestResult(reachable: false), même chose que le try/catch
/// défensif ajouté côté Node après le crash rencontré en production.
Future<GfpTestResult> testCandidate(
  GfpProxyCandidate candidate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final start = DateTime.now();
  Socket socket;
  final connect = Socket.connect(candidate.host, candidate.port);

  try {
    socket = await connect.timeout(timeout);
  } on TimeoutException catch (e) {
    // `Future.timeout` returns to us but does not cancel Socket.connect. On
    // Android, leaving those late sockets alive exhausts file descriptors
    // during a large manual scan and makes progress stop after a few dozen
    // candidates. Dispose the socket if the OS completes it later.
    unawaited(connect.then((lateSocket) => lateSocket.destroy()).catchError((_) {}));
    return GfpTestResult(reachable: false, stage: 'tcp', error: e.toString());
  } catch (e) {
    return GfpTestResult(reachable: false, stage: 'tcp', error: e.toString());
  }

  String? sni;
  var requiresStandardTls = candidate.scheme == 'trojan';
  try {
    final uri = Uri.parse(candidate.raw);
    final value = uri.queryParameters['sni'] ?? uri.queryParameters['serverName'];
    if (value != null && value.isNotEmpty) sni = value;
    requiresStandardTls =
        requiresStandardTls ||
        (candidate.scheme == 'vless' &&
            !candidate.reality &&
            (uri.queryParameters['security'] ?? '').toLowerCase() == 'tls');
  } catch (_) {
    sni = null;
  }
  // Keep the proven Node behaviour: a Reality server with a declared SNI
  // must complete the camouflage TLS handshake, not merely accept TCP.
  requiresStandardTls = sni != null;

  if (!requiresStandardTls) {
    // Reality n'est pas un serveur TLS classique : lui envoyer un ClientHello
    // TLS seul produit volontairement un échec. Un TCP ouvert est donc le
    // test léger correct ici; le core vérifiera le protocole complet lors de
    // la connexion, toujours localement sur l'appareil.
    final latency = DateTime.now().difference(start).inMilliseconds;
    socket.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tcp');
  }

  // Le SNI ne peut jamais être une adresse IP (même contrainte que
  // net.isIP() côté Node -- ici InternetAddress.tryParse()). L'API Dart
  // exige un nom d'hôte non nul : sans SNI valide, le TCP reste le test
  // léger sûr plutôt qu'un ClientHello incorrect ou un crash.
  final validatedSni = sni;
  if (InternetAddress.tryParse(validatedSni) != null) {
    final latency = DateTime.now().difference(start).inMilliseconds;
    socket.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tcp');
  }

  try {
    final secure = await SecureSocket.secure(
      socket,
      host: validatedSni,
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
  int concurrency = 6,
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
      results[i] = candidate.copyWith(reachable: result.reachable, latencyMs: result.latencyMs);
      done++;
      onProgress?.call(done, candidates.length);
    }
  }

  final workerCount = concurrency < candidates.length ? concurrency : candidates.length;
  await Future.wait(List.generate(workerCount, (_) => worker()));

  return results.whereType<GfpProxyCandidate>().toList();
}
