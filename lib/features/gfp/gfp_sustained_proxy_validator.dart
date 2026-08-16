import 'dart:async';
import 'dart:convert';
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
    // Le endpoint HTTP évite les différences de gestion CONNECT/TLS de
    // dart:io sur Android. Le contenu est aléatoire et non sensible; ce test
    // sert uniquement à prouver 64 Ko réellement reçus via le proxy local.
    Uri.parse('http://speed.cloudflare.com/__down?bytes=$_minimumBytes'),
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
    try {
      final groups = await core.core.bgClient.outboundsInfo(Empty()).first.timeout(const Duration(seconds: 45));
      if (groups.items.isEmpty) return false;
      final group = _selectionGroup(groups.items);

      final result = await core.urlTest(group.tag).run().timeout(const Duration(seconds: 90));
      return result.match((_) => false, (_) => true);
    } catch (_) {
      return false;
    }
  }

  Future<String?> selectStableOutbound(HiddifyCoreService core) async {
    // CoreStarted est publié avant que l'inbound mixte soit nécessairement
    // prêt. Sur Android, son ouverture peut prendre près de cinq secondes.
    if (!await _waitForLocalProxy()) return null;

    final selectionGroup = await _waitForSelectionGroup(core);
    if (selectionGroup == null) return null;
    final previousSelection = selectionGroup.selected;

    // Le test collectif peut finir avant que tous ses résultats soient
    // publiés. Tester chaque outbound direct reste sûr: seuls 64 Ko réellement
    // reçus l'autorisent. Les délais valides passent simplement en premier.
    final candidates = _directCandidates(selectionGroup).toList(growable: false)
      ..sort((a, b) => _candidateDelay(a).compareTo(_candidateDelay(b)));

    for (final candidate in candidates.take(maxCandidates)) {
      final wasSelected = await _selectCandidate(core, selectionGroup.tag, candidate.tag);
      if (!wasSelected) continue;

      // selectOutbound confirme la commande avant que le routeur local ait
      // toujours propagé le nouveau membre à ses connexions entrantes.
      await Future<void>.delayed(const Duration(milliseconds: 500));
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

  int _candidateDelay(OutboundInfo candidate) =>
      ConnectionConst.isValidDelay(candidate.urlTestDelay) ? candidate.urlTestDelay : 1 << 30;

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

  Future<bool> _waitForLocalProxy() async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 12)) {
      Socket? probe;
      try {
        probe = await Socket.connect(
          InternetAddress.loopbackIPv4,
          mixedPort,
          timeout: const Duration(milliseconds: 500),
        );
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } finally {
        probe?.destroy();
      }
    }
    return false;
  }

  Future<OutboundGroup?> _waitForSelectionGroup(HiddifyCoreService core) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < const Duration(seconds: 12)) {
      try {
        final groups = await core.core.bgClient
            .outboundsInfo(Empty())
            .first
            .timeout(const Duration(seconds: 2));
        if (groups.items.isNotEmpty) {
          final group = _selectionGroup(groups.items);
          if (_directCandidates(group).isNotEmpty) return group;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _downloadAtLeast(Uri url, int minimumBytes) async {
    if (url.scheme == 'http') return _downloadHttpViaLocalProxy(url, minimumBytes);

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

  Future<bool> _downloadHttpViaLocalProxy(Uri url, int minimumBytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        mixedPort,
        timeout: const Duration(seconds: 7),
      );
      socket.write(
        'GET $url HTTP/1.1\r\n'
        'Host: ${url.host}\r\n'
        'Accept-Encoding: identity\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();

      final pending = <int>[];
      var headersRead = false;
      var received = 0;
      await for (final chunk in socket.timeout(const Duration(seconds: 8))) {
        if (headersRead) {
          received += chunk.length;
        } else {
          pending.addAll(chunk);
          final headerEnd = _httpHeaderEnd(pending);
          if (headerEnd < 0) {
            if (pending.length > 16 * 1024) return false;
            continue;
          }

          final statusLine = ascii
              .decode(pending.take(headerEnd).toList(), allowInvalid: true)
              .split('\r\n')
              .first;
          if (!RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(statusLine)) return false;
          headersRead = true;
          received = pending.length - headerEnd - 4;
          pending.clear();
        }
        if (received >= minimumBytes) return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  int _httpHeaderEnd(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index++) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return index;
      }
    }
    return -1;
  }
}
