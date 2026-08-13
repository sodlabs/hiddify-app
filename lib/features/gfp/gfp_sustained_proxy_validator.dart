import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

/// A second, local-only validation layer for public proxy lists.
///
/// sing-box URL tests use a lightweight HTTP HEAD request. A public endpoint
/// can answer that request and still reset or throttle real traffic seconds
/// later. This validator selects only candidates already accepted by the
/// local core, then requires one to transfer a small public payload through
/// the core's local mixed proxy. Nothing is reported or uploaded.
class GfpSustainedProxyValidator {
  const GfpSustainedProxyValidator({required this.mixedPort, this.maxCandidates = 4});

  static const _minimumBytes = 128 * 1024;
  static final _testUrls = <Uri>[
    Uri.parse('https://speed.cloudflare.com/__down?bytes=$_minimumBytes'),
    Uri.parse('https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs'),
  ];

  final int mixedPort;
  final int maxCandidates;

  /// Returns the selected outbound tag, or null when no already URL-tested
  /// candidate completes a small real transfer.
  Future<String?> selectStableOutbound(HiddifyCoreService core) async {
    final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
    // `balance` reports direct endpoint URL tests but is a round-robin
    // balancer. `select` is the final selector used by all routed traffic.
    // Selecting on `balance` therefore leaves a dead endpoint free to be
    // picked for the next connection.
    if (groups.items.isEmpty) return null;
    final candidateGroup = groups.items.firstWhere(
      (group) =>
          group.tag == 'balance' &&
          group.items.any((candidate) => ConnectionConst.isValidDelay(candidate.urlTestDelay)),
      orElse: () => groups.items.firstWhere(
        (group) =>
            group.selectable && group.items.any((candidate) => ConnectionConst.isValidDelay(candidate.urlTestDelay)),
        orElse: () => groups.items.first,
      ),
    );
    final selectionGroup = groups.items.firstWhere(
      // `select` is the configured final route selector. It is actionable
      // even when the core does not mark it as selectable in OutboundsInfo.
      (group) => group.tag == 'select',
      orElse: () => candidateGroup,
    );

    final candidates =
        candidateGroup.items
            .where((candidate) => ConnectionConst.isValidDelay(candidate.urlTestDelay))
            .toList(growable: false)
          ..sort((a, b) => a.urlTestDelay.compareTo(b.urlTestDelay));

    for (final candidate in candidates.take(maxCandidates)) {
      final wasSelected = await _selectCandidate(core, selectionGroup.tag, candidate.tag);
      if (!wasSelected) continue;

      if (await _canTransferPayload()) return candidate.tag;
    }
    return null;
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
