import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/gfp/gfp_proxy_service.dart';
import 'package:hiddify/features/gfp/gfp_sustained_proxy_validator.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
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
      _setStatus('testing routes locally');
      final allTags = await validator.candidateOutboundTags(core);
      if (allTags.isEmpty) {
        _setStatus('no route available — refresh manually');
        return;
      }
      if (!shouldContinue()) return;
      final tested = await validator.urlTestCandidateGroup(core);
      if (!tested) {
        _setStatus('route tests failed — refresh manually');
        return;
      }
      if (!shouldContinue()) return;

      _setStatus('checking sustained download');
      final stableTag = await validator.selectStableOutbound(core);
      if (!shouldContinue()) return;
      if (stableTag == null) {
        _setStatus('no verified route — refresh manually');
        return;
      }

      // La route est maintenant un outbound concret, pas le groupe round-robin.
      // Elle reste verrouillée jusqu'à une action explicite de l'utilisateur ou
      // au prochain démarrage du tunnel. Aucun basculement en arrière-plan.
      _setStatus('verified route locked — automatic switching off');
    } catch (error, stackTrace) {
      if (!shouldContinue()) return;
      debugPrint('sodlab local route validation error: $error\n$stackTrace');
      _setStatus('local route validation stopped');
    }
  }

  void _setStatus(String value) => ref.read(gfpHealthStatusProvider.notifier).update(value);
}

String _profileName(ProfileEntity profile) =>
    profile.map(remote: (profile) => profile.name, local: (profile) => profile.name);
