import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/gfp/gfp_sustained_proxy_validator.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/third_party_warning_banner.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // final hasAnyProfile = ref.watch(hasAnyProfileProvider);
    final activeProfile = ref.watch(activeProfileProvider);

    // 100% client-side: on ne pointe plus vers une URL de subscription
    // hébergée par nous. L'app fetch/teste elle-même les listes publiques
    // gfpcom, en local.
    final gfpError = useState<String?>(null);
    final gfpStatus = useState<String>('idle');

    useEffect(() {
      Future<void> run() async {
        try {
          gfpStatus.value = 'starting';
          final repo = await ref.read(profileRepositoryProvider.future);
          final service = GfpProxyService();

          List<ProfileEntity> allProfiles = [];
          try {
            final either = await repo.watchAll().first;
            allProfiles = either.getOrElse((_) => <ProfileEntity>[]);
          } catch (_) {
            // pas grave, on retentera au prochain lancement
          }

          final existing = allProfiles
              .where(
                (profile) =>
                    profile.map(remote: (profile) => profile.name, local: (profile) => profile.name) ==
                    kGfpProfileTitle,
              )
              .firstOrNull;

          if (existing == null) {
            gfpStatus.value = 'fetching';
            final cached = await service.loadLastKnownGood();
            final content = cached ?? await _refreshForCurrentNetwork(service, gfpStatus);
            gfpStatus.value = 'adding profile';
            final result = await repo.addLocal(content).run();
            await result.match((failure) => Future<void>.value(gfpError.value = 'addLocal a échoué: $failure'), (
              _,
            ) async {
              if (cached == null) await service.saveValidatedCache(content);
              gfpStatus.value = 'done';
            });
          } else {
            final fresh = await service.loadFreshCache();
            if (fresh == null) {
              gfpStatus.value = 'refreshing';
              unawaited(_updateExistingProfile(repo, existing, service, gfpStatus));
            }
            gfpStatus.value = 'done (existing)';
          }
        } catch (e, st) {
          gfpError.value = '$e';
          debugPrint('sodlab gfp error: $e\n$st');
        }
      }

      run();
      return null;
    }, const []);

    // The upstream default selector is a round-robin balancer. With public
    // lists it can send each new connection to a different, already-dead
    // endpoint. Once the core starts, keep this auto profile on its local
    // lowest-delay group instead; the core still performs every handshake and
    // URL test on the user's own network.
    useEffect(() {
      final core = ref.read(hiddifyCoreServiceProvider);
      final subscription = core.statusController.stream.whereType<CoreStarted>().listen((_) {
        unawaited(_selectLocalLowestProxy(ref, gfpStatus));
      });
      return () {
        unawaited(subscription.cancel());
      };
    }, const []);

    return Scaffold(
      appBar: AppBar(
        // leading: (RootScaffold.stateKey.currentState?.hasDrawer ?? false) && showDrawerButton(context)
        //     ? DrawerButton(
        //         onPressed: () {
        //           RootScaffold.stateKey.currentState?.openDrawer();
        //         },
        //       )
        //     : null,
        title: Row(
          children: [
            Assets.images.logo.svg(height: 24),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.common.appTitle),
                  const TextSpan(text: " "),
                  const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // IconButton(
          //     onPressed: () => const QuickSettingsRoute().push(context),
          //     icon: const Icon(FluentIcons.options_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.config.quickSettings,
          //         )),
          // IconButton(
          //     onPressed: () => const AddProfileRoute().push(context),
          //     icon: const Icon(FluentIcons.add_circle_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.profile.add.buttonText,
          //         )),
          Semantics(
            key: const ValueKey("profile_quick_settings"),
            label: t.pages.home.quickSettings,
            child: IconButton(
              icon: Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
            ),
          ),
          const Gap(8),
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Column(
        children: [
          const ThirdPartyWarningBanner(),
          if (gfpError.value != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade900,
              padding: const EdgeInsets.all(8),
              child: Text('sodlab debug: ${gfpError.value}', style: const TextStyle(color: Colors.white, fontSize: 11)),
            )
          else if (gfpStatus.value != 'done' && gfpStatus.value != 'done (existing)')
            Container(
              width: double.infinity,
              color: Colors.blue.shade900,
              padding: const EdgeInsets.all(6),
              child: Text('sodlab: ${gfpStatus.value}', style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: const AssetImage('assets/images/world_map.png'), // Replace with your image path
                  fit: BoxFit.cover,
                  opacity: 0.09,
                  colorFilter: theme.brightness == Brightness.dark
                      ? ColorFilter.mode(Colors.white.withValues(alpha: .15), BlendMode.srcIn) //
                      : ColorFilter.mode(
                          Colors.grey.withValues(alpha: 1),
                          BlendMode.srcATop,
                        ), // Apply white tint in dark mode
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 600, // Set the maximum width here
                      ),
                      child: CustomScrollView(
                        slivers: [
                          // switch (activeProfile) {
                          // AsyncData(value: final profile?) =>
                          MultiSliver(
                            children: [
                              // const Gap(100),
                              switch (activeProfile) {
                                AsyncData(value: final profile?) => ProfileTile(
                                  profile: profile,
                                  isMain: true,
                                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                ),
                                _ => const Text(""),
                              },
                              const SliverFillRemaining(
                                hasScrollBody: false,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [ConnectionButton(), ActiveProxyDelayIndicator()],
                                      ),
                                    ),
                                    ActiveProxyFooter(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          // AsyncData() => switch (hasAnyProfile) {
                          //     AsyncData(value: true) => const EmptyActiveProfileHomeBody(),
                          //     _ => const EmptyProfilesHomeBody(),
                          //   },
                          // AsyncError(:final error) => SliverErrorBodyPlaceholder(t.presentShortError(error)),
                          // _ => const SliverToBoxAdapter(),
                          // },
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String> _refreshForCurrentNetwork(GfpProxyService service, ValueNotifier<String> status) async {
  final networks = await Connectivity().checkConnectivity();
  final onWifi = networks.contains(ConnectivityResult.wifi) || networks.contains(ConnectivityResult.ethernet);

  // Les bornes évitent les pics de mémoire/file-descriptors qui faisaient
  // tomber le service Android avec des centaines d'outbounds. Elles restent
  // plus généreuses en Wi-Fi, sans faire de scan sans limite sur le téléphone.
  return service.refresh(
    maxCandidatesToTest: onWifi ? 400 : 120,
    concurrency: onWifi ? 16 : 6,
    maxFinal: onWifi ? 200 : 60,
    onProgress: (done, total) => status.value = 'test $done/$total',
  );
}

Future<void> _updateExistingProfile(
  ProfileRepository repo,
  ProfileEntity profile,
  GfpProxyService service,
  ValueNotifier<String> status,
) async {
  try {
    final content = await _refreshForCurrentNetwork(service, status);
    final result = await repo.offlineUpdate(profile, content).run();
    await result.match((_) => Future<void>.value(), (_) => service.saveValidatedCache(content));
  } catch (_) {
    // Le profil précédent et validé reste disponible hors-ligne.
  }
}

Future<void> _selectLocalLowestProxy(WidgetRef ref, ValueNotifier<String> status) async {
  final profile = ref.read(activeProfileProvider).valueOrNull;
  if (profile == null || _profileName(profile) != kGfpProfileTitle) return;

  try {
    status.value = 'waiting for local protocol tests';
    // sing-box starts its own URL tests asynchronously. Waiting avoids treating
    // the initial zero/failed delay values as usable routes.
    await Future<void>.delayed(const Duration(seconds: 30));
    final stillActive = ref.read(activeProfileProvider).valueOrNull;
    if (stillActive == null || _profileName(stillActive) != kGfpProfileTitle) return;

    status.value = 'checking real local transfer';
    final core = ref.read(hiddifyCoreServiceProvider);
    final validator = GfpSustainedProxyValidator(mixedPort: ref.read(ConfigOptions.mixedPort));
    final stableTag = await validator.selectStableOutbound(core);
    if (stableTag != null) {
      status.value = 'using locally verified route';
      return;
    }

    // If no small transfer succeeds, retain the core's own lowest-delay choice
    // rather than leaving an arbitrary round-robin endpoint selected.
    final result = await core.selectOutbound('select', 'lowest').run();
    result.match((_) => status.value = 'local route selection failed', (_) => status.value = 'using lowest-delay route');
  } catch (e, st) {
    // The user may stop the VPN or switch profile during the local check. This
    // must remain a failed validation, never an uncaught app-level exception.
    debugPrint('sodlab local route validation error: $e\n$st');
    status.value = 'local route validation stopped';
  }
}

String _profileName(ProfileEntity profile) => profile.map(remote: (profile) => profile.name, local: (profile) => profile.name);

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
