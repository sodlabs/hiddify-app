import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_proxy_parser.dart';

void main() {
  const reality =
      'vless://11111111-1111-1111-1111-111111111111@reality.example:443?security=reality&sni=cdn.example#reality';
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
}
