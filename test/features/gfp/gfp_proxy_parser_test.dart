import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_proxy_parser.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/gfp/gfp_proxy_tester.dart';

void main() {
  const reality =
      'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc#reality';
  const tls = 'vless://22222222-2222-2222-2222-222222222222@tls.example:443?security=tls&sni=cdn.example#tls';

  test('parses the standard base64 VMess form used by public lists', () {
    final payload = base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'ps': 'vmess test',
          'add': 'vmess.example',
          'port': '8443',
          'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        }),
      ),
    );

    final candidates = parseProxyList('vmess://$payload');

    expect(candidates, hasLength(1));
    expect(candidates.single.scheme, 'vmess');
    expect(candidates.single.host, 'vmess.example');
    expect(candidates.single.port, 8443);
  });

  test('keeps Reality first and excludes non-Reality candidates in Reality-only mode', () {
    final candidates = parseProxyList('$tls\n$reality', realityOnly: true);

    expect(candidates, hasLength(1));
    expect(candidates.single.reality, isTrue);
    expect(sortByPriority(parseProxyList('$tls\n$reality')).first.reality, isTrue);
  });

  test('rejects a Reality URI without its required public key', () {
    const incomplete =
        'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example#bad';
    expect(parseProxyList(incomplete), isEmpty);
  });

  test('rejects malformed VLESS credentials before importing the profile', () {
    const invalidUuid = 'vless://IP-CF@invalid.example:443?security=none&encryption=none&type=tcp';
    const invalidRealityKey =
        'vless://11111111-1111-1111-1111-111111111111@invalid.example:443?security=reality&sni=cdn.example&pbk=not-a-key';
    const invalidEncryption =
        'vless://11111111-1111-1111-1111-111111111111@invalid.example:443?security=none&encryption=broken';

    expect(parseProxyList('$invalidUuid\n$invalidRealityKey\n$invalidEncryption'), isEmpty);
  });

  test('rejects an unsupported VLESS flow before it can crash the core parser', () {
    const unsupported =
        'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc&flow=xtls-rprx-vision-udp443#bad-flow';
    expect(parseProxyList(unsupported), isEmpty);
  });

  test('spreads selected endpoints across hosts before taking a second port', () {
    final candidates = parseProxyList('''
$reality
vless://11111111-1111-1111-1111-111111111111@reality.example:8443?security=reality&sni=cdn.example&pbk=-FJ39r74kpiTshb4xuc6mxgAqvc4P_qJEE5IahxK2wE#same-host
vless://33333333-3333-3333-3333-333333333333@other.example:443?security=reality&sni=cdn.example&pbk=ZzNK9IcoUd93qqUXfejbUMH0B3y3vJ49bePlBhUO3Gk#other-host
''');

    final selected = selectDiverseCandidates(candidates, limit: 2);

    expect(selected.map((candidate) => candidate.host).toSet(), hasLength(2));
  });

  test('keeps distinct credentials and Reality settings on the same socket', () {
    final candidates = parseProxyList('''
vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc#first
vless://22222222-2222-2222-2222-222222222222@reality.example:443?security=reality&sni=cdn.example&pbk=-FJ39r74kpiTshb4xuc6mxgAqvc4P_qJEE5IahxK2wE#second
''');

    expect(candidates, hasLength(2));
    expect(candidates.map((candidate) => candidate.identityKey).toSet(), hasLength(2));
  });

  test('ignores display-only differences when deduplicating links', () {
    final candidates = parseProxyList('''
vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc#first-name
vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc#second-name
''');

    expect(candidates, hasLength(1));
  });

  test('defers UDP protocol reachability to the core', () async {
    final candidates = parseProxyList('''
hy2://password@hysteria.example:443?sni=cdn.example#hysteria
awg://key@awg.example:51820#amnezia
''');

    expect(candidates, hasLength(2));
    for (final candidate in candidates) {
      final result = await testCandidate(candidate);
      expect(result.reachable, isTrue);
      expect(result.stage, 'core');
    }
  });

  test('does not send a standard TLS handshake to Reality', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final candidate = parseProxyList(
        'vless://11111111-1111-1111-1111-111111111111@127.0.0.1:${server.port}'
        '?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc',
      ).single;

      final result = await testCandidate(candidate);

      expect(result.reachable, isTrue);
      expect(result.stage, 'tcp');
    } finally {
      await server.close();
    }
  });

  test('reserves fallback protocols when Reality candidates fill the list', () {
    final candidates = parseProxyList('''
$reality
vless://11111111-1111-1111-1111-111111111111@reality-two.example:443?security=reality&sni=cdn.example&pbk=-FJ39r74kpiTshb4xuc6mxgAqvc4P_qJEE5IahxK2wE#reality-two
trojan://password@trojan.example:443?sni=cdn.example#trojan
''');

    final selected = selectDiverseCandidates(candidates, limit: 3);

    expect(selected.any((candidate) => candidate.scheme == 'trojan'), isTrue);
  });

  test('keeps a real protocol reserve when a Reality feed dominates', () {
    final realities = List.generate(
      30,
      (index) =>
          'vless://11111111-1111-1111-1111-111111111111@reality-$index.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc#reality-$index',
    );
    final vmessPayload = base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'ps': 'vmess',
          'add': 'vmess.example',
          'port': '443',
          'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        }),
      ),
    );
    final candidates = parseProxyList('''
${realities.join('\n')}
trojan://password@trojan.example:443?sni=cdn.example#trojan
vmess://$vmessPayload
ss://method:password@ss.example:443#ss
''');

    final selected = selectDiverseCandidates(candidates, limit: 20);

    expect(selected.any((candidate) => candidate.scheme == 'trojan'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'vmess'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'ss'), isTrue);
  });

  test('keeps protocol fallbacks even when Reality candidates dominate', () {
    final realities = List.generate(
      20,
      (index) =>
          'vless://11111111-1111-1111-1111-111111111111@dominant-$index.example:443?security=reality&sni=cdn.example&pbk=b14Nibi1pMPwFPqgiyZRS3a6-Y-Q8EsE5urKnA-RkAc',
    );
    final vmessPayload = base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'add': 'vmess-fallback.example',
          'port': '443',
          'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        }),
      ),
    );
    final selected = selectDiverseCandidates(
      parseProxyList('''
${realities.join('\n')}
trojan://password@trojan-fallback.example:443?sni=cdn.example
vmess://$vmessPayload
ss://method:password@ss-fallback.example:443
vless://22222222-2222-2222-2222-222222222222@vless-fallback.example:443?security=tls&sni=cdn.example
hy2://password@hy2-fallback.example:443?sni=cdn.example
awg://key@awg-fallback.example:51820
'''),
      limit: 12,
    );

    expect(selected.where((candidate) => candidate.reality), hasLength(6));
    expect(selected.any((candidate) => candidate.scheme == 'trojan'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'vmess'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'ss'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'vless' && !candidate.reality), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'hy2'), isTrue);
    expect(selected.any((candidate) => candidate.scheme == 'awg'), isTrue);
  });

  test('preflight completes the entire candidate sample', () async {
    final candidates = parseProxyList(
      List.generate(20, (index) => 'hy2://password@candidate-$index.example:443?sni=cdn.example').join('\n'),
    );
    var completed = 0;

    final tested = await testAll(candidates, concurrency: 4, onProgress: (done, _) => completed = done);

    expect(tested, hasLength(20));
    expect(completed, 20);
  });
}
