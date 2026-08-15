class GfpProxyCandidate {
  GfpProxyCandidate({
    required this.scheme,
    required this.host,
    required this.port,
    required this.reality,
    required this.label,
    required this.raw,
    required this.identityKey,
    this.reachable = false,
    this.latencyMs,
  });

  final String scheme;
  final String host;
  final int port;
  final bool reality;
  final String label;
  final String raw;
  final String identityKey;
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
      identityKey: identityKey,
      reachable: reachable ?? this.reachable,
      latencyMs: latencyMs ?? this.latencyMs,
    );
  }

  // Ordre utilisé avant les tests locaux.
  int get priorityScore {
    if (reality) return 0;
    if (scheme == 'awg') return 1;
    if (scheme == 'hy2' || scheme == 'hysteria2' || scheme == 'tuic') return 2;
    if (scheme == 'trojan') return 3;
    if (scheme == 'ss') return 4;
    if (scheme == 'vless') return 5;
    if (scheme == 'vmess') return 6;
    return 7;
  }
}
