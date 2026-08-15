# Sod privacy notice

Last updated: 15 August 2026

Sod does not require an account. This build does not send analytics, crash reports, advertising identifiers, browsing history, proxy lists, or connection logs to Sod Labs. Application and core logs remain on the device unless the user explicitly exports and shares them.

To provide its features, the app contacts third-party services directly from the user's device:

- public GitHub-hosted proxy feeds when creating or refreshing the default public network;
- the endpoints contained in a custom source added by the user;
- connection-test and IP-information services configured in the app;
- GitHub when the user checks for an application update.

Those third parties can observe the user's IP address and normal request metadata. When a proxy is active, the selected proxy operator can observe connection metadata and any traffic that is not protected by end-to-end encryption. Public proxies are untrusted: users should prefer HTTPS and avoid sensitive accounts, banking, or confidential data.

Profiles, preferences, cached public routes, and logs are stored locally. Removing the app removes its application data according to the operating system's normal behavior. Desktop users can also inspect or remove the working directory shown in the About screen.

Sod is based on open-source Hiddify components. Their copyright and license notices remain available in [LICENSE.md](LICENSE.md).

This notice describes version 1.0.1. It must be updated before enabling any future telemetry or hosted Sod service.
