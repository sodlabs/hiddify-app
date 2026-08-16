import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

// Confirme une route avec un vrai transfert local.
class GfpSustainedProxyValidator {
  const GfpSustainedProxyValidator({required this.mixedPort, this.maxCandidates = 20});

  // Les faux positifs observés transféraient parfois quelques dizaines de Ko
  // avant de se figer. 64 Ko reste léger, mais prouve une réception soutenue.
  static const _minimumBytes = 64 * 1024;
  static final _testUrls = <Uri>[
    Uri.parse('https://speed.cloudflare.com/__down?bytes=$_minimumBytes'),
    Uri.parse('https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs'),
  ];

  final int mixedPort;
  final int maxCandidates;

  Future<List<String>> candidateOutboundTags(HiddifyCoreService core, {int? limit}) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return const [];
    final tags = _directCandidates(_selectionGroup(groups.items)).map((candidate) => candidate.tag);
    return limit == null ? tags.toList() : tags.take(limit).toList();
  }

  /// Le cœur attend ici le tag du groupe, pas le tag de chaque membre. Un seul
  /// test du groupe remplit les délais et horodatages de tous les candidats.
  Future<bool> urlTestCandidateGroup(HiddifyCoreService core) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return false;
    final group = _selectionGroup(groups.items);

    final result = await core.urlTest(group.tag).run().timeout(const Duration(seconds: 90));
    return result.match((_) => false, (_) => true);
  }

  Future<String?> selectStableOutbound(HiddifyCoreService core) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return null;
    final selectionGroup = _selectionGroup(groups.items);
    final previousSelection = selectionGroup.selected;

    // urlTestCandidateGroup vient juste de terminer. Certains builds Android
    // renvoient bien le délai mais laissent urlTestTime vide; le délai valide
    // est donc ici le signal de succès fiable et nécessairement récent.
    final candidates = _directCandidates(
      selectionGroup,
    ).where(_hasSuccessfulTest).toList(growable: false)
      ..sort((a, b) => a.urlTestDelay.compareTo(b.urlTestDelay));

    for (final candidate in candidates.take(maxCandidates)) {
      final wasSelected = await _selectCandidate(core, selectionGroup.tag, candidate.tag);
      if (!wasSelected) continue;

      if (await _canTransferPayload()) return candidate.tag;
    }

    // Ne jamais laisser le sélecteur sur le dernier candidat en échec.
    if (previousSelection.isNotEmpty) {
      await _selectCandidate(core, selectionGroup.tag, previousSelection);
    }
    return null;
  }

  OutboundGroup _selectionGroup(List<OutboundGroup> groups) {
    return groups.firstWhere(
      (group) => group.tag == 'select' && group.selectable && group.items.isNotEmpty,
      orElse: () =>
          groups.firstWhere((group) => group.selectable && group.items.isNotEmpty, orElse: () => groups.first),
    );
  }

  Iterable<OutboundInfo> _directCandidates(OutboundGroup group) =>
      group.items.where((candidate) => !candidate.isGroup && candidate.tag.isNotEmpty);

  bool _hasSuccessfulTest(OutboundInfo candidate) => ConnectionConst.isValidDelay(candidate.urlTestDelay);

  Future<bool> _selectCandidate(HiddifyCoreService core, String groupTag, String candidateTag) async {
    try {
      final selection = await core.selectOutbound(groupTag, candidateTag).run();
      return selection.match((_) => false, (_) => true);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _canTransferPayload() async {
    for (final url in _testUrls) {
      if (await _downloadAtLeast(url, _minimumBytes)) return true;
    }
    return false;
  }

  Future<bool> _downloadAtLeast(Uri url, int minimumBytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    client.userAgent = 'Mozilla/5.0';
    client.findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';

    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 7));
      final response = await request.close().timeout(const Duration(seconds: 7));
      if (response.statusCode != HttpStatus.ok) return false;

      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        received += chunk.length;
        if (received >= minimumBytes) return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
