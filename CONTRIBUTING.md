# Contributing to Sod

Bug reports, connection results, translations, documentation, and code contributions are welcome.

## Before opening an issue

Search the [existing issues](https://github.com/sodlabs/sod-app/issues) first. For a connection problem, include the platform, OS version, Sod version, country/provider, exact reproduction steps, and sanitized logs. Never publish subscription links, proxy credentials, UUIDs, or tokens.

## Development

Sod uses Flutter and the Hiddify/sing-box core stack. Prepare the target platform before running the application:

```shell
flutter pub get
make android-prepare   # or: make windows-prepare
flutter test
flutter run
```

Keep changes focused and include tests when behavior changes. Large changes should start with a GitHub issue so the intended behavior can be agreed before implementation.

## Releases

Public binaries must be produced by [the GitHub Actions release workflow](.github/workflows/release.yml). This is a requirement of the inherited [Hiddify Extended GPLv3 license](LICENSE.md).

By contributing, you agree that your contribution is distributed under the same license. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).
