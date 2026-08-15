import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

// Confirme une route avec un vrai transfert local.
class GfpSustainedProxyValidator {
  const GfpSustainedProxyValidator({required this.mixedPort, this.maxCandidates = 10});

  static const _minimumBytes = 8 * 1024;
  static final _testUrls = <Uri>[
    Uri.parse('https://speed.cloudflare.com/__down?bytes=$_minimumBytes'),
    Uri.parse('https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs'),
  ];

  final int mixedPort;
  final int maxCandidates;

  Future<List<String>> candidateOutboundTags(HiddifyCoreService core, {int? limit}) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return const [];
    final tags = _candidateGroup(groups.items).items.map((candidate) => candidate.tag);
    return limit == null ? tags.toList() : tags.take(limit).toList();
  }

  Future<Set<String>> healthyOutboundTags(HiddifyCoreService core) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return const {};
    final group = _candidateGroup(groups.items);
    return group.items.where(_hasFreshSuccessfulTest).map((candidate) => candidate.tag).toSet();
  }

  Future<bool> canTransferActiveRoute() => _canTransferPayload();

  Future<String?> selectStableOutbound(
    HiddifyCoreService core, {
    Set<String> excludedTags = const {},
    void Function(String tag)? onAttempt,
  }) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    if (groups.items.isEmpty) return null;
    final candidateGroup = _candidateGroup(groups.items);
    final selectionGroup = groups.items.firstWhere((group) => group.tag == 'select', orElse: () => candidateGroup);

    final candidates =
        candidateGroup.items
            .where((candidate) => _hasFreshSuccessfulTest(candidate) && !excludedTags.contains(candidate.tag))
            .toList(growable: false)
          ..sort((a, b) => a.urlTestDelay.compareTo(b.urlTestDelay));

    for (final candidate in candidates.take(maxCandidates)) {
      onAttempt?.call(candidate.tag);
      final wasSelected = await _selectCandidate(core, selectionGroup.tag, candidate.tag);
      if (!wasSelected) continue;

      if (await _canTransferPayload()) return candidate.tag;
    }
    return null;
  }

  OutboundGroup _candidateGroup(List<OutboundGroup> groups) {
    return groups.firstWhere(
      (group) => group.tag == 'balance' && group.items.isNotEmpty,
      orElse: () =>
          groups.firstWhere((group) => group.selectable && group.items.isNotEmpty, orElse: () => groups.first),
    );
  }

  bool _hasFreshSuccessfulTest(OutboundInfo candidate) {
    if (!ConnectionConst.isValidDelay(candidate.urlTestDelay) || !candidate.hasUrlTestTime()) return false;
    final age = DateTime.now().toUtc().difference(candidate.urlTestTime.toDateTime());
    return age >= const Duration(minutes: -1) && age <= const Duration(minutes: 5);
  }

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
    client.findProxy = (_) => 'PROXY localhost:$mixedPort';

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
