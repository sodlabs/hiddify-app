import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/gfp/gfp_proxy_models.dart';

const Set<String> kSupportedSchemes = {'vless', 'vmess', 'trojan', 'ss', 'hy2', 'hysteria2', 'tuic', 'awg'};
final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _shortIdPattern = RegExp(r'^[0-9a-fA-F]{2,16}$');

bool _isValidNetworkHost(String value) {
  var host = value.trim();
  if (host.isEmpty || host.length > 253 || host.contains('%')) return false;
  if (InternetAddress.tryParse(host) != null) return true;

  // Uri accepte et encode certains textes Unicode dans la partie hôte. Dart IO
  // les interprète ensuite comme des IPv6 avec scope et peut lever avant même
  // que le Future de connexion existe. Les listes publiques doivent fournir
  // une IP ou un nom DNS ASCII (punycode pour un domaine internationalisé).
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  final labels = host.split('.');
  if (labels.any(
    (label) =>
        label.isEmpty ||
        label.length > 63 ||
        label.startsWith('-') ||
        label.endsWith('-') ||
        !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(label),
  )) {
    return false;
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

GfpProxyCandidate? _parseVmess(String line) {
  const prefix = 'vmess://';
  if (!line.toLowerCase().startsWith(prefix)) return null;

  try {
    var encoded = line.substring(prefix.length).trim();
    encoded = encoded.replaceAll('-', '+').replaceAll('_', '/');
    encoded = encoded.padRight(encoded.length + (4 - encoded.length % 4) % 4, '=');
    final config = jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>;
    final host = config['add']?.toString().trim() ?? '';
    final port = int.tryParse(config['port']?.toString() ?? '') ?? 443;
    final id = config['id']?.toString().trim() ?? '';
    if (!_isValidNetworkHost(host) || port < 1 || port > 65535 || !_uuidPattern.hasMatch(id)) return null;

    return GfpProxyCandidate(
      scheme: 'vmess',
      host: host,
      port: port,
      reality: false,
      label: config['ps']?.toString().trim() ?? '',
      raw: line,
      identityKey: 'vmess|${jsonEncode(_canonicalVmessConfig(config))}',
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _canonicalVmessConfig(Map<String, dynamic> config) {
  final normalized = <String, dynamic>{};
  for (final key in config.keys.where((key) => key != 'ps').toList()..sort()) {
    normalized[key] = config[key];
  }
  return normalized;
}

bool _isReality(Uri uri) {
  return (uri.queryParameters['security'] ?? '').toLowerCase() == 'reality';
}

bool _hasCompleteRealityParameters(Uri uri) {
  final serverName = (uri.queryParameters['sni'] ?? uri.queryParameters['serverName'] ?? '').trim();
  final publicKey = (uri.queryParameters['pbk'] ?? uri.queryParameters['publicKey'] ?? '').trim();
  final shortId = (uri.queryParameters['sid'] ?? uri.queryParameters['shortId'] ?? '').trim();
  if (serverName.isEmpty || !_isX25519PublicKey(publicKey)) return false;
  return shortId.isEmpty || (shortId.length.isEven && _shortIdPattern.hasMatch(shortId));
}

bool _isX25519PublicKey(String value) {
  try {
    final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
    return base64Url.decode(padded).length == 32;
  } catch (_) {
    return false;
  }
}

bool _hasValidVlessIdentity(Uri uri) {
  final id = uri.userInfo.split(':').first.trim();
  return _uuidPattern.hasMatch(id);
}

bool _hasSupportedVlessEncryption(Uri uri) {
  final encryption = (uri.queryParameters['encryption'] ?? '').trim().toLowerCase();
  return encryption.isEmpty || encryption == 'none';
}

bool _hasSupportedVlessFlow(Uri uri) {
  final flow = (uri.queryParameters['flow'] ?? '').trim().toLowerCase();
  return flow.isEmpty || flow == 'xtls-rprx-vision';
}

String _extractLabel(Uri uri) {
  if (uri.fragment.isEmpty) return '';
  try {
    return Uri.decodeComponent(uri.fragment).trim();
  } catch (_) {
    return uri.fragment;
  }
}

List<GfpProxyCandidate> parseProxyList(String rawText, {bool realityOnly = false}) {
  final lines = rawText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);

  final candidates = <GfpProxyCandidate>[];
  final seen = <String>{};

  for (final line in lines) {
    final vmess = _parseVmess(line);
    if (vmess != null) {
      if (!realityOnly && seen.add(vmess.identityKey)) candidates.add(vmess);
      continue;
    }

    final uri = _safeParseUri(line);
    if (uri == null) continue;

    final scheme = uri.scheme.toLowerCase();
    if (!kSupportedSchemes.contains(scheme)) continue;

    final host = uri.host;
    final port = uri.port != 0 ? uri.port : 443;
    if (!_isValidNetworkHost(host)) continue;

    final reality = scheme == 'vless' && _isReality(uri);
    if (realityOnly && !reality) continue;
    if (reality && !_hasCompleteRealityParameters(uri)) continue;
    if (scheme == 'vless' &&
        (!_hasValidVlessIdentity(uri) || !_hasSupportedVlessEncryption(uri) || !_hasSupportedVlessFlow(uri))) {
      continue;
    }

    // Le fragment ne change que le nom affiché.
    final dedupKey = '$scheme|${uri.replace(fragment: '')}';
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
        identityKey: dedupKey,
      ),
    );
  }

  return candidates;
}

List<GfpProxyCandidate> sortByPriority(List<GfpProxyCandidate> candidates) {
  final sorted = List<GfpProxyCandidate>.from(candidates);
  sorted.sort((a, b) {
    final byProtocol = a.priorityScore.compareTo(b.priorityScore);
    if (byProtocol != 0) return byProtocol;

    return (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30);
  });
  return sorted;
}
