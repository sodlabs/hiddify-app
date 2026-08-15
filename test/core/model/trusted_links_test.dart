import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/trusted_links.dart';

void main() {
  group("TrustedLinks.isTrusted - Sod repository", () {
    test("exact repository URL is trusted", () {
      expect(TrustedLinks.isTrusted("https://github.com/sodlabs/sod-app"), isTrue);
    });

    test("scheme, host case, www, fragment, and trailing slash are normalized", () {
      expect(TrustedLinks.isTrusted("http://www.GITHUB.com/sodlabs/sod-app/#readme"), isTrue);
      expect(TrustedLinks.isTrusted("github.com/sodlabs/sod-app"), isTrue);
    });
  });

  group("TrustedLinks.isTrusted - untrusted links must warn", () {
    test("different repository paths are not implicitly trusted", () {
      expect(TrustedLinks.isTrusted("https://github.com/sodlabs"), isFalse);
      expect(TrustedLinks.isTrusted("https://github.com/sodlabs/sod-app/issues"), isFalse);
      expect(TrustedLinks.isTrusted("https://github.com/hiddify"), isFalse);
    });

    test("look-alike and suffix-attack domains are rejected", () {
      expect(TrustedLinks.isTrusted("https://github.example.com/sodlabs/sod-app"), isFalse);
      expect(TrustedLinks.isTrusted("https://github.com.evil.example/sodlabs/sod-app"), isFalse);
      expect(TrustedLinks.isTrusted("https://github.com/sodIabs/sod-app"), isFalse);
    });

    test("query parameters make the URL non-exact", () {
      expect(TrustedLinks.isTrusted("https://github.com/sodlabs/sod-app?redirect=evil"), isFalse);
    });

    test("empty and garbage input is rejected", () {
      expect(TrustedLinks.isTrusted(""), isFalse);
      expect(TrustedLinks.isTrusted("   "), isFalse);
      expect(TrustedLinks.isTrusted("not a url"), isFalse);
    });
  });
}
