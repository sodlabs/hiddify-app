// lib/features/gfp/gfp_proxy_parser.dart
//
// Port Dart de gfp-fetcher/src/parseProxies.js. Même logique : on ne
// réimplémente pas un parseur complet par protocole, juste ce qu'il faut
// pour tester la joignabilité et dédupliquer/trier. Le contenu brut de
// chaque ligne est conservé tel quel pour la subscription finale (hiddify
// re-parsera lui-même le detail du protocole).

import 'gfp_proxy_models.dart';

// Temporairement restreint à vless le temps de diagnostiquer un crash du
// moteur natif au démarrage du tunnel (voir CLAUDE.md). vmess/trojan/etc
// remis plus tard une fois la cause isolée.
const Set<String> kSupportedSchemes = {
  'vless',
};

/// Validation structurelle minimale avant d'inclure un candidat -- un
/// candidat qui répond au TCP/TLS mais dont l'URI est incomplète peut
/// quand même faire planter le moteur natif au moment de construire la
/// config réelle. On écarte ici tout ce qui semble structurellement
/// incomplet plutôt que de laisser le moteur en décider (il ne le fait
/// visiblement pas gracieusement).
bool _looksStructurallyValid(Uri uri) {
  // vless: le userInfo porte l'UUID, jamais vide
  if (uri.userInfo.isEmpty) return false;

  final security = (uri.queryParameters['security'] ?? '').toLowerCase();
  if (security == 'reality') {
    final pbk = uri.queryParameters['pbk'] ?? '';
    final sni = uri.queryParameters['sni'] ?? '';
    if (pbk.isEmpty || sni.isEmpty) return false;
  } else if (security == 'tls') {
    final sni = uri.queryParameters['sni'] ?? '';
    if (sni.isEmpty) return false;
  }

  return true;
}

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
/// forcément des lignes incomplètes/cassées. sing-box est strict au
/// démarrage : une seule config invalide dans le lot peut faire planter
/// tout le moteur natif. On filtre donc ce qu'on peut vérifier au niveau
/// de l'URI avant de la transmettre.
bool _isStructurallyValid(Uri uri, String scheme, bool reality) {
  // uuid (userInfo, avant le @) obligatoire pour vless/vmess/trojan
  if (uri.userInfo.isEmpty) return false;

  if (scheme == 'vless') {
    final params = uri.queryParameters;
    if ((params['encryption'] ?? '').isEmpty) return false;

    if (reality) {
      // reality exige une clé publique et un SNI non vides ; le short id
      // peut légitimement être vide, donc on ne le vérifie pas.
      if ((params['pbk'] ?? '').isEmpty) return false;
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
    if (!_looksStructurallyValid(uri)) continue;

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
