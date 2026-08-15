# Sod RELEASE_TAG

This is a community beta for Android and Windows. It is intended for real-network testing before a stable release.

> **Safety:** public proxies are operated by third parties. Do not use them for banking, passwords, confidential work, or other sensitive activity.

## Downloads

- **Android:** `Sod-Android-universal.apk` is the simplest choice for most devices. Architecture-specific APKs are also included.
- **Windows:** `Sod-Windows-Portable-x64.zip` runs without installation. `Sod-Windows-Setup-x64.exe` is the installer build.

Android beta builds may use a development signing key until the permanent Sod signing identity is established. A future signing-key change can require uninstalling an earlier beta.

## What to test

- initial route discovery;
- sustained incoming traffic after connection;
- reconnection after changing networks;
- manual deep refresh when routes stop working;
- custom subscription import and persistence.

Report results through [GitHub Issues](https://github.com/sodlabs/sod-app/issues/new/choose). Include country/provider, device, OS, and Sod version, but never include subscriptions, proxy credentials, UUIDs, tokens, or unsanitized logs.

Sod is an independently maintained fork of [Hiddify App](https://github.com/hiddify/hiddify-app). See the [license and change summary](https://github.com/sodlabs/sod-app#origin-license-and-changes).
