import 'package:flutter/material.dart';

class ThirdPartyWarningBanner extends StatelessWidget {
  const ThirdPartyWarningBanner({super.key});

  static const Map<String, String> _messages = {
    'en': "⚠ Third-party public proxies. Never enter passwords, banking or "
        "personal accounts while connected. Use at your own risk.",
    'fr': "⚠ Proxys publics tiers. N'entrez jamais de mots de passe, "
        "comptes bancaires ou identifiants sensibles pendant la connexion. "
        "Utilisation à vos risques.",
    'ru': "⚠ Стороннние публичные прокси. Никогда не вводите пароли, "
        "банковские данные или личные аккаунты во время подключения. "
        "Используйте на свой риск.",
    'zh': "⚠ 第三方公共代理。连接期间请勿输入密码、银行或个人账户信息。"
        "使用风险自负。",
    'ar': "⚠ وكلاء عامة تابعون لجهات خارجية. لا تُدخل أبدًا كلمات المرور "
        "أو بيانات مصرفية أو حسابات شخصية أثناء الاتصال. الاستخدام على "
        "مسؤوليتك الخاصة.",
  };

  String _resolveMessage(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    return _messages[code] ?? _messages['en']!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRtl = Localizations.localeOf(context).languageCode == 'ar';

    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: theme.colorScheme.errorContainer,
        child: Text(
          _resolveMessage(context),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onErrorContainer,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}