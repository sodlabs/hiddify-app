import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/gfp/gfp_sustained_proxy_validator.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final gfpHealthStatusProvider = NotifierProvider<GfpHealthStatus, String>(GfpHealthStatus.new);

class GfpHealthStatus extends Notifier<String> {
  @override
  String build() => 'idle';

  void update(String nextValue) {
    if (state == nextValue) return;
    state = nextValue;
  }
}

final gfpHealthMonitorProvider = Provider<GfpHealthMonitor>((ref) {
  final monitor = GfpHealthMonitor(ref)..start();
  ref.onDispose(monitor.stop);
  return monitor;
});

class GfpHealthMonitor {
  GfpHealthMonitor(this.ref);

  final Ref ref;
  StreamSubscription<CoreStatus>? _subscription;
  var _generation = 0;

  void start() {
    final core = ref.read(hiddifyCoreServiceProvider);
    _subscription = core.statusController.stream.listen((coreStatus) {
      _generation++;
      if (coreStatus is! CoreStarted) return;
      final runGeneration = _generation;
      unawaited(_findAndMonitorRoute(shouldContinue: () => _generation == runGeneration));
    });
  }

  void stop() {
    _generation++;
    unawaited(_subscription?.cancel());
  }

  Future<void> _findAndMonitorRoute({required bool Function() shouldContinue}) async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (!shouldContinue() || activeProfile == null || !isGfpProfileName(_profileName(activeProfile))) return;

    try {
      final core = ref.read(hiddifyCoreServiceProvider);
      final validator = GfpSustainedProxyValidator(mixedPort: ref.read(ConfigOptions.mixedPort));
      _setStatus('testing the first 10 routes');
      final allTags = await validator.candidateOutboundTags(core);
      final quickTags = allTags.take(10).toList();
      if (!shouldContinue()) return;
      await _urlTestTags(core, quickTags, concurrency: 5);
      if (!shouldContinue()) return;

      _setStatus('checking real internet access');
      final attempted = <String>{};
      var stableTag = await validator.selectStableOutbound(core, onAttempt: attempted.add);
      if (stableTag == null && allTags.length > quickTags.length) {
        _setStatus('testing the remaining routes');
        await _urlTestTags(core, allTags.skip(quickTags.length).toList(), concurrency: 4);
        if (!shouldContinue()) return;
        stableTag = await validator.selectStableOutbound(core, excludedTags: attempted);
      }
      if (!shouldContinue()) return;
      if (stableTag == null) {
        _setStatus('no locally verified route');
        return;
      }

      _setStatus('using locally verified route');
      await _monitorRoute(core, validator, shouldContinue: shouldContinue);
    } catch (error, stackTrace) {
      if (!shouldContinue()) return;
      debugPrint('sodlab local route validation error: $error\n$stackTrace');
      _setStatus('local route validation stopped');
    }
  }

  Future<void> _monitorRoute(
    HiddifyCoreService core,
    GfpSustainedProxyValidator validator, {
    required bool Function() shouldContinue,
  }) async {
    final streaks = <String, int>{};
    var cycle = 0;

    while (shouldContinue() && _isGfpProfileActive()) {
      final delay = switch (cycle) {
        0 => const Duration(seconds: 15),
        1 => const Duration(minutes: 2),
        _ => const Duration(minutes: 15),
      };
      await Future<void>.delayed(delay);
      if (!shouldContinue() || !_isGfpProfileActive()) return;

      _setStatus('refreshing standby routes');
      await _urlTestGroup(core);
      if (!shouldContinue() || !_isGfpProfileActive()) return;

      final healthy = await validator.healthyOutboundTags(core);
      final knownTags = {...streaks.keys, ...healthy};
      for (final tag in knownTags) {
        streaks[tag] = healthy.contains(tag) ? (streaks[tag] ?? 0) + 1 : 0;
      }

      final activeWorks = await validator.canTransferActiveRoute();
      if (!shouldContinue() || !_isGfpProfileActive()) return;
      if (!activeWorks) {
        _setStatus('active route lost — finding a replacement');
        final replacement = await validator.selectStableOutbound(core);
        if (!shouldContinue()) return;
        if (replacement == null) {
          _setStatus('no working route — retrying soon');
          cycle = 0;
          continue;
        }
        cycle = 0;
      } else {
        cycle++;
      }

      final stableCount = streaks.values.where((streak) => streak >= 2).length;
      final confirmedCount = streaks.values.where((streak) => streak >= 3).length;
      _setStatus(
        confirmedCount > 0 ? '$confirmedCount confirmed routes ($stableCount stable)' : '$stableCount stable routes',
      );
    }
  }

  Future<void> _urlTestTags(HiddifyCoreService core, List<String> tags, {required int concurrency}) async {
    var index = 0;

    Future<void> worker() async {
      while (true) {
        final current = index;
        if (current >= tags.length) return;
        index++;
        try {
          await core.urlTest(tags[current]).run().timeout(const Duration(seconds: 25));
        } catch (_) {
          // L'échec reste enregistré par le moteur.
        }
      }
    }

    final workerCount = concurrency < tags.length ? concurrency : tags.length;
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _urlTestGroup(HiddifyCoreService core) async {
    try {
      final result = await core.urlTest('balance').run().timeout(const Duration(seconds: 90));
      if (result.isRight()) return;
    } catch (_) {
      // Certains profils n'ont pas de groupe balance.
    }
    try {
      await core.urlTest('select').run().timeout(const Duration(seconds: 90));
    } catch (_) {
      // Nouvelle tentative au prochain passage.
    }
  }

  bool _isGfpProfileActive() {
    final profile = ref.read(activeProfileProvider).valueOrNull;
    return profile != null && isGfpProfileName(_profileName(profile));
  }

  void _setStatus(String value) => ref.read(gfpHealthStatusProvider.notifier).update(value);
}

String _profileName(ProfileEntity profile) =>
    profile.map(remote: (profile) => profile.name, local: (profile) => profile.name);
