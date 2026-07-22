// lib/features/gfp/gfp_proxy_service.dart
//
// Orchestration 100% côté client : fetch des listes brutes gfpcom
// (infrastructure publique, pas la nôtre), parse/priorité, test de
// joignabilité depuis l'appareil de l'utilisateur, cache local, et
// construction du contenu à passer à `ProfileRepository.addLocal` /
// `offlineUpdate` -- jamais d'URL de subscription hébergée par nous.

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gfp_proxy_models.dart';
import 'gfp_proxy_parser.dart';
import 'gfp_proxy_tester.dart';

/// Titre utilisé à la fois dans le header `#profile-title` du contenu
/// généré et pour retrouver "notre" profil parmi ceux de l'utilisateur.
/// Ne pas changer sans mettre à jour les deux usages ensemble.
const String kGfpProfileTitle = 'sodlab (auto, non verifie)';

const _cacheKeyContent = 'gfp_subscription_content';
const _cacheKeyTimestamp = 'gfp_subscription_timestamp';

const Map<String, String> _sources = {
  'vless': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vless.txt',
  'vmess': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/vmess.txt',
  'trojan': 'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/trojan.txt',
};

class GfpProxyService {
  GfpProxyService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Contenu en cache si encore valide, sinon null.
  Future<String?> loadFreshCache({Duration maxAge = const Duration(minutes: 45)}) async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_cacheKeyTimestamp);
    final content = prefs.getString(_cacheKeyContent);
    if (ts == null || content == null) return null;

    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > maxAge.inMilliseconds) return null;
    return content;
  }

  /// Dernier contenu connu, même périmé -- filet de secours si un refresh
  /// échoue (pas de réseau, toutes les sources indisponibles, etc).
  Future<String?> loadLastKnownGood() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cacheKeyContent);
  }

  Future<void> _saveCache(String content) async {
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
    int maxCandidatesToTest = 400,
    int concurrency = 40,
    Duration testTimeout = const Duration(seconds: 4),
    int maxFinal = 40,
    void Function(int done, int total)? onProgress,
  }) async {
    var all = <GfpProxyCandidate>[];

    for (final entry in _sources.entries) {
      try {
        final response = await _dio.get<String>(
          entry.value,
          options: Options(responseType: ResponseType.plain),
        );
        all.addAll(parseProxyList(response.data ?? ''));
      } catch (_) {
        // Une source qui échoue ne doit pas bloquer les autres --
        // même philosophie défensive que côté Node.
      }
    }

    all = sortByPriority(all).take(maxCandidatesToTest).toList();

    final tested = await testAll(
      all,
      concurrency: concurrency,
      timeout: testTimeout,
      onProgress: onProgress,
    );

    final reachable = sortByPriority(
      tested.where((c) => c.reachable).toList(),
    ).take(maxFinal).toList();

    final content = _buildSubscriptionContent(reachable);
    await _saveCache(content);
    return content;
  }

  String _buildSubscriptionContent(List<GfpProxyCandidate> candidates) {
    final header = [
      '#profile-title: $kGfpProfileTitle',
      '#profile-update-interval: 3',
    ].join('\n');
    final body = candidates.map((c) => c.raw).join('\n');
    return '$header\n$body\n';
  }
}
