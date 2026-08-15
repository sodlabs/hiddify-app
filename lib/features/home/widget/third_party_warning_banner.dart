import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ThirdPartyWarningBanner extends ConsumerWidget {
  const ThirdPartyWarningBanner({super.key, this.compact = true});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final accepted = ref.watch(Preferences.publicProxyNoticeAccepted);
    if (compact && accepted) return const SizedBox.shrink();

    return Semantics(
      container: true,
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, color: theme.colorScheme.onTertiaryContainer),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.pages.home.publicProxyNotice.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Gap(4),
                    Text(
                      t.pages.home.publicProxyNotice.message,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                    ),
                    if (compact) ...[
                      const Gap(8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton(
                          onPressed: () => ref.read(Preferences.publicProxyNoticeAccepted.notifier).update(true),
                          child: Text(t.pages.home.publicProxyNotice.accept),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
