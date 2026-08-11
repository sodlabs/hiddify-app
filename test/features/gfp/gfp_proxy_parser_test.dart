import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_proxy_parser.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';

void main() {
  const reality =
      'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=public-key#reality';
  const tls = 'vless://22222222-2222-2222-2222-222222222222@tls.example:443?security=tls&sni=cdn.example#tls';

  test('parses the standard base64 VMess form used by public lists', () {
    final payload = base64Encode(
      utf8.encode(jsonEncode({'v': '2', 'ps': 'vmess test', 'add': 'vmess.example', 'port': '8443'})),
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

  test('rejects an unsupported VLESS flow before it can crash the core parser', () {
    const unsupported =
        'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example&pbk=public-key&flow=xtls-rprx-vision-udp443#bad-flow';
    expect(parseProxyList(unsupported), isEmpty);
  });

  test('spreads selected endpoints across hosts before taking a second port', () {
    final candidates = parseProxyList('''
$reality
vless://11111111-1111-1111-1111-111111111111@reality.example:8443?security=reality&sni=cdn.example&pbk=other-key#same-host
vless://33333333-3333-3333-3333-333333333333@other.example:443?security=reality&sni=cdn.example&pbk=third-key#other-host
''');

    final selected = selectDiverseCandidates(candidates, limit: 2);

    expect(selected.map((candidate) => candidate.host).toSet(), hasLength(2));
  });

  test('reserves fallback protocols when Reality candidates fill the list', () {
    final candidates = parseProxyList('''
$reality
vless://11111111-1111-1111-1111-111111111111@reality-two.example:443?security=reality&sni=cdn.example&pbk=other-key#reality-two
trojan://password@trojan.example:443?sni=cdn.example#trojan
''');

    final selected = selectDiverseCandidates(candidates, limit: 3);

    expect(selected.any((candidate) => candidate.scheme == 'trojan'), isTrue);
  });

  test('keeps a real protocol reserve when a Reality feed dominates', () {
    final realities = List.generate(
      30,
      (index) =>
          'vless://11111111-1111-1111-1111-111111111111@reality-$index.example:443?security=reality&sni=cdn.example&pbk=key-$index#reality-$index',
    );
    final vmessPayload = base64Encode(
      utf8.encode(jsonEncode({'v': '2', 'ps': 'vmess', 'add': 'vmess.example', 'port': '443'})),
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
}
