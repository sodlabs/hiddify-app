// lib/features/gfp/gfp_proxy_parser.dart
//
// Port Dart de gfp-fetcher/src/parseProxies.js. Même logique : on ne
// réimplémente pas un parseur complet par protocole, juste ce qu'il faut
// pour tester la joignabilité et dédupliquer/trier. Le contenu brut de
// chaque ligne est conservé tel quel pour la subscription finale (hiddify
// re-parsera lui-même le detail du protocole).

import 'gfp_proxy_models.dart';

const Set<String> kSupportedSchemes = {
  'vless',
  'vmess',
  'trojan',
  'ss',
  'hy2',
  'hysteria2',
  'tuic',
};

Uri? _safeParseUri(String line) {
  try {
    final uri = Uri.parse(line.trim());
    if (uri.scheme.isEmpty || uri.host.isEmpty) return null;
    return uri;
  } catch (_) {
    return null;
  }
}

bool _isReality(Uri uri) {
  return (uri.queryParameters['security'] ?? '').toLowerCase() == 'reality';
}

String _extractLabel(Uri uri) {
  if (uri.fragment.isEmpty) return '';
  try {
    return Uri.decodeComponent(uri.fragment).trim();
  } catch (_) {
    return uri.fragment;
  }
}

/// @param rawText contenu brut d'un fichier de sources (une URI par ligne)
/// @param realityOnly ne garder que security=reality (vless)
List<GfpProxyCandidate> parseProxyList(String rawText, {bool realityOnly = false}) {
  final lines = rawText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);

  final candidates = <GfpProxyCandidate>[];
  final seen = <String>{};

  for (final line in lines) {
    final uri = _safeParseUri(line);
    if (uri == null) continue;

    final scheme = uri.scheme.toLowerCase();
    if (!kSupportedSchemes.contains(scheme)) continue;

    // Uri.host retire déjà les crochets IPv6 automatiquement (équivalent
    // au .replace(/^\[|\]$/g, '') qu'on faisait côté Node).
    final host = uri.host;
    final port = uri.port != 0 ? uri.port : 443;
    if (host.isEmpty) continue;

    final reality = scheme == 'vless' && _isReality(uri);
    if (realityOnly && !reality) continue;

    final dedupKey = '$scheme|$host|$port';
    if (seen.contains(dedupKey)) continue;
    seen.add(dedupKey);

    candidates.add(
      GfpProxyCandidate(
        scheme: scheme,
        host: host,
        port: port,
        reality: reality,
        label: _extractLabel(uri),
        raw: line,
      ),
    );
  }

  return candidates;
}

List<GfpProxyCandidate> sortByPriority(List<GfpProxyCandidate> candidates) {
  final sorted = List<GfpProxyCandidate>.from(candidates);
  sorted.sort((a, b) => a.priorityScore.compareTo(b.priorityScore));
  return sorted;
}
