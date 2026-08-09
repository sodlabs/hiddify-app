// lib/features/gfp/gfp_proxy_models.dart
//
// Modèle de candidat, équivalent Dart de ce que produisait
// gfp-fetcher/src/parseProxies.js côté Node.

class GfpProxyCandidate {
  GfpProxyCandidate({
    required this.scheme,
    required this.host,
    required this.port,
    required this.reality,
    required this.label,
    required this.raw,
    this.reachable = false,
    this.latencyMs,
  });

  final String scheme;
  final String host;
  final int port;
  final bool reality;
  final String label;
  final String raw;
  final bool reachable;
  final int? latencyMs;

  GfpProxyCandidate copyWith({bool? reachable, int? latencyMs}) {
    return GfpProxyCandidate(
      scheme: scheme,
      host: host,
      port: port,
      reality: reality,
      label: label,
      raw: raw,
      reachable: reachable ?? this.reachable,
      latencyMs: latencyMs ?? this.latencyMs,
    );
  }

  /// Priorité de tri : reality > vless > vmess > trojan > le reste.
  /// Plus petit = plus prioritaire (même logique que priorityScore côté JS).
  int get priorityScore {
    if (reality) return 0;
    if (scheme == 'vless') return 1;
    if (scheme == 'vmess') return 2;
    if (scheme == 'trojan') return 3;
    return 4;
  }
}
