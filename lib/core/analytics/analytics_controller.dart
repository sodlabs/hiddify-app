import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

const String enableAnalyticsPrefKey = "enable_analytics";

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async {
    // Cette distribution vise des réseaux à haut risque : aucun événement,
    // crash report ou journal ne doit quitter l'appareil. On écrase aussi une
    // ancienne préférence afin qu'une mise à jour ne réactive pas Sentry.
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    return false;
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider).requireValue;

  Future<void> enableAnalytics() async {
    loggy.info("analytics are disabled in this privacy-preserving build");
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    state = const AsyncData(false);
  }

  Future<void> disableAnalytics() async {
    if (state case AsyncData()) {
      loggy.debug("disabling analytics");
      state = const AsyncLoading();
      await _preferences.setBool(enableAnalyticsPrefKey, false);
      state = const AsyncData(false);
    }
  }
}
