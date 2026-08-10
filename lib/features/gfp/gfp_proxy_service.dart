// lib/features/gfp/gfp_proxy_service.dart
//
// Orchestration 100% côté client : fetch des listes brutes gfpcom
// (infrastructure publique, pas la nôtre), parse/priorité, test de
// joignabilité depuis l'appareil de l'utilisateur, cache local, et
// construction du contenu à passer à `ProfileRepository.addLocal` /
// `offlineUpdate` -- jamais d'URL de subscription hébergée par nous.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:hiddify/features/gfp/gfp_proxy_models.dart';
import 'package:hiddify/features/gfp/gfp_proxy_parser.dart';
import 'package:hiddify/features/gfp/gfp_proxy_tester.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Titre utilisé à la fois dans le header `#profile-title` du contenu
/// généré et pour retrouver "notre" profil parmi ceux de l'utilisateur.
/// Ne pas changer sans mettre à jour les deux usages ensemble.
const String kGfpProfileTitle = 'sodlab (auto, non verifie)';

// V5 invalidates the former narrow, first-host-only selection. Existing
// user profiles are refreshed in place; no profile or unrelated preference
// is deleted.
const _cacheKeyContent = 'gfp_subscription_content_v5';
const _cacheKeyTimestamp = 'gfp_subscription_timestamp_v5';

class GfpNoReachableProxyException implements Exception {
  const GfpNoReachableProxyException();

  @override
  String toString() => 'Aucun proxy joignable n’a été trouvé sur ce réseau.';
}

const Map<String, String> _sources = {
  'vless': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vless.txt',
  'vmess': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vmess.txt',
  'trojan': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/trojan.txt',
};

class GfpProxyService {
  GfpProxyService({Dio? dio})
    : _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 12)));

  final Dio _dio;

  /// Contenu en cache si encore valide, sinon null.
  Future<String?> loadFreshCache({Duration maxAge = const Duration(minutes: 45)}) async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_cacheKeyTimestamp);
    final content = prefs.getString(_cacheKeyContent);
    if (ts == null || content == null) return null;

    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > maxAge.inMilliseconds) return null;
    return _containsProxy(content) ? content : null;
  }

  /// Dernier contenu connu, même périmé -- filet de secours si un refresh
  /// échoue (pas de réseau, toutes les sources indisponibles, etc).
  Future<String?> loadLastKnownGood() async {
    final prefs = await SharedPreferences.getInstance();
    final content = prefs.getString(_cacheKeyContent);
    return _containsProxy(content) ? content : null;
  }

  /// Appelé seulement après que ProfileRepository a validé le contenu avec
  /// le core. Ainsi une liste vide ou invalide ne peut jamais devenir le
  /// cache de démarrage suivant.
  Future<void> saveValidatedCache(String content) async {
    if (!_containsProxy(content)) throw const GfpNoReachableProxyException();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKeyContent, content);
    await prefs.setInt(_cacheKeyTimestamp, DateTime.now().millisecondsSinceEpoch);
  }

  /// Fetch + parse + priorité + test, écrit le cache, retourne le
  /// contenu prêt pour `addLocal`/`offlineUpdate`.
  ///
  /// [maxCandidatesToTest] borne le nombre de candidats réellement testés
  /// (les sources font 50-80k lignes à elles trois, inutile de tout
  /// tester -- on garde les plus prioritaires après tri).
  /// [concurrency] et [maxCandidatesToTest] doivent être réduits sur
  /// données mobiles (voir logique Wi-Fi/mobile dans l'appelant, via
  /// connectivity_plus, pas géré ici pour garder ce service simple et
  /// testable indépendamment du réseau).
  Future<String> refresh({
    int maxCandidatesToTest = 96,
    int concurrency = 6,
    Duration testTimeout = const Duration(seconds: 3),
    int maxFinal = 12,
    void Function(int done, int total)? onProgress,
  }) async {
    // Les listes publiques peuvent faire plusieurs dizaines de mégaoctets.
    // La lecture par flux s'arrête aussitôt qu'on possède suffisamment de
    // candidats : aucune liste complète n'est stockée en mémoire du téléphone.
    final perSourceLimit = maxCandidatesToTest * 2;
    final lists = await Future.wait(
      _sources.values.map((url) => _readCandidatePrefix(url, maxCandidates: perSourceLimit)),
    );
    final deduplicated = <String, GfpProxyCandidate>{};
    for (final candidate in lists.expand((list) => list)) {
      deduplicated.putIfAbsent('${candidate.scheme}|${candidate.host}|${candidate.port}', () => candidate);
    }
    final all = selectDiverseCandidates(deduplicated.values, limit: maxCandidatesToTest);

    final tested = await testAll(all, concurrency: concurrency, timeout: testTimeout, onProgress: onProgress);

    final reachable = selectDiverseCandidates(tested.where((c) => c.reachable), limit: maxFinal);

    if (reachable.isEmpty) throw const GfpNoReachableProxyException();

    final content = _buildSubscriptionContent(reachable);
    return content;
  }

  bool _containsProxy(String? content) {
    if (content == null) return false;
    return parseProxyList(content).isNotEmpty;
  }

  Future<List<GfpProxyCandidate>> _readCandidatePrefix(
    String url, {
    required int maxCandidates,
    int maxCharacters = 8 * 1024 * 1024,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(url, options: Options(responseType: ResponseType.stream));
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const [];

      // Public lists are grouped by provider. Taking their first entries
      // repeatedly selected the same expired clusters. Keep a bounded,
      // reservoir sample across the stream instead: the client sees hosts
      // from the whole downloaded portion without retaining the raw list.
      final candidates = <GfpProxyCandidate>[];
      final seen = <String>{};
      final perHost = <String, int>{};
      final random = Random();
      var eligibleCount = 0;
      var charactersRead = 0;
      await for (final line
          in body.stream.map<List<int>>((bytes) => bytes).transform(utf8.decoder).transform(const LineSplitter())) {
        charactersRead += line.length + 1;
        if (charactersRead > maxCharacters) break;

        // Cette API parse aussi le format vmess://base64 et conserve l'URI
        // brute pour le parseur complet du core.
        for (final candidate in parseProxyList(line)) {
          final key = '${candidate.scheme}|${candidate.host}|${candidate.port}';
          final hostKey = candidate.host.toLowerCase();
          final hostCount = perHost[hostKey] ?? 0;
          if (!seen.add(key) || hostCount >= 2) continue;

          eligibleCount++;
          if (candidates.length < maxCandidates) {
            perHost[hostKey] = hostCount + 1;
            candidates.add(candidate);
            continue;
          }

          final replacement = random.nextInt(eligibleCount);
          if (replacement < maxCandidates) {
            final previous = candidates[replacement];
            final previousHost = previous.host.toLowerCase();
            perHost[previousHost] = (perHost[previousHost] ?? 1) - 1;
            perHost[hostKey] = hostCount + 1;
            candidates[replacement] = candidate;
          }
        }
      }
      return candidates;
    } catch (_) {
      // Une source qui échoue ne doit pas bloquer les autres.
      return const [];
    }
  }

  String _buildSubscriptionContent(List<GfpProxyCandidate> candidates) {
    final header = ['#profile-title: $kGfpProfileTitle'].join('\n');
    final body = candidates.map((c) => c.raw).join('\n');
    return '$header\n$body\n';
  }
}

/// Prefer the requested protocol order without filling a user's list with
/// variants of one server. First take one endpoint per host, then a second,
/// and so on only when there are not enough independent hosts.
List<GfpProxyCandidate> selectDiverseCandidates(Iterable<GfpProxyCandidate> candidates, {required int limit}) {
  if (limit <= 0) return const [];

  final sorted = sortByPriority(candidates.toList());
  final selected = <GfpProxyCandidate>[];
  final selectedKeys = <String>{};
  final perHost = <String, int>{};

  void addSpread(Iterable<GfpProxyCandidate> pool, int target) {
    final list = pool.toList(growable: false);
    for (var allowedPerHost = 1; selected.length < target; allowedPerHost++) {
      var added = false;
      for (final candidate in list) {
        if (selected.length == target) break;
        final hostKey = candidate.host.toLowerCase();
        final key = '${candidate.scheme}|$hostKey|${candidate.port}';
        if (selectedKeys.contains(key) || (perHost[hostKey] ?? 0) >= allowedPerHost) continue;
        perHost[hostKey] = (perHost[hostKey] ?? 0) + 1;
        selectedKeys.add(key);
        selected.add(candidate);
        added = true;
      }
      if (!added) break;
    }
  }

  final reality = sorted.where((candidate) => candidate.reality).toList(growable: false);
  final fallback = sorted.where((candidate) => !candidate.reality).toList(growable: false);
  final realityTarget = fallback.isEmpty ? limit : (limit * 3 + 3) ~/ 4;

  // Keep Reality first, while reserving one quarter for other supported
  // protocols. Otherwise a stale Reality batch can starve viable fallbacks.
  addSpread(reality, realityTarget);
  addSpread(fallback, limit);
  addSpread(sorted, limit);
  return selected;
}
