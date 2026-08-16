import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/gfp/gfp_proxy_models.dart';

const _coreOnlyPreflightSchemes = {'hy2', 'hysteria2', 'tuic', 'awg'};

class GfpTestResult {
  GfpTestResult({required this.reachable, this.latencyMs, required this.stage, this.error});

  final bool reachable;
  final int? latencyMs;
  final String stage;
  final String? error;
}

Future<GfpTestResult> testCandidate(
  GfpProxyCandidate candidate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  // QUIC et WireGuard seront testés par le moteur.
  if (_coreOnlyPreflightSchemes.contains(candidate.scheme)) {
    return GfpTestResult(reachable: true, stage: 'core');
  }

  final start = DateTime.now();
  Socket socket;
  final connect = Socket.connect(candidate.host, candidate.port);

  try {
    socket = await connect.timeout(timeout);
  } on TimeoutException catch (e) {
    // Le timeout n'annule pas Socket.connect : fermer la socket si elle arrive plus tard.
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
  if (candidate.reality || !requiresStandardTls) {
    final latency = DateTime.now().difference(start).inMilliseconds;
    socket.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tcp');
  }

  final validatedSni = sni ?? candidate.host;
  if (InternetAddress.tryParse(validatedSni) != null) {
    final latency = DateTime.now().difference(start).inMilliseconds;
    socket.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tcp');
  }

  try {
    final secure = await SecureSocket.secure(
      socket,
      host: validatedSni,
      onBadCertificate: (cert) => true, // On vérifie la réponse TLS, pas le certificat.
    ).timeout(timeout);
    final latency = DateTime.now().difference(start).inMilliseconds;
    secure.destroy();
    return GfpTestResult(reachable: true, latencyMs: latency, stage: 'tls');
  } catch (e) {
    socket.destroy();
    return GfpTestResult(reachable: false, stage: 'tls', error: e.toString());
  }
}

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
