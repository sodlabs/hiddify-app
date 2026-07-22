// lib/features/gfp/gfp_proxy_parser.dart
//
// Port Dart de gfp-fetcher/src/parseProxies.js. Même logique : on ne
// réimplémente pas un parseur complet par protocole, juste ce qu'il faut
// pour tester la joignabilité et dédupliquer/trier. Le contenu brut de
// chaque ligne est conservé tel quel pour la subscription finale (hiddify
// re-parsera lui-même le detail du protocole).

import 'dart:convert';

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

/// Validation structurelle minimale avant d'inclure un candidat dans la
/// subscription finale. Notre test réseau vérifie la joignabilité, pas la
/// validité complète de la config -- une liste publique scrapée contient
/// forcément des lignes incomplètes/cassées.
/// Une clé publique Reality (X25519) doit décoder en exactement 32 octets.
/// Certaines entrées scrapées ont une valeur qui ressemble à du base64 mais
/// qui ne décode pas à la bonne longueur -- ça passe une simple vérification
/// "non vide" mais peut faire planter le moteur natif au démarrage.
bool _isValidX25519PublicKey(String value) {
  try {
    final normalized = base64Url.normalize(value);
    final bytes = base64Url.decode(normalized);
    return bytes.length == 32;
  } catch (_) {
    return false;
  }
}

bool _isStructurallyValid(Uri uri, String scheme, bool reality) {
  if (uri.userInfo.isEmpty) return false;

  if (scheme == 'vless') {
    final params = uri.queryParameters;
    if ((params['encryption'] ?? '').isEmpty) return false;

    if (reality) {
      final pbk = params['pbk'] ?? '';
      if (pbk.isEmpty || !_isValidX25519PublicKey(pbk)) return false;
      if ((params['sni'] ?? '').isEmpty) return false;
      if ((params['fp'] ?? '').isEmpty) return false;
    }
  }

  return true;
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
    if (!_isStructurallyValid(uri, scheme, reality)) continue;

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
