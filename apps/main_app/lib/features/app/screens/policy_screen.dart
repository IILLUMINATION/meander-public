import 'package:canvas_app/features/shell/screens/menu_screen.dart';
import 'package:canvas_app/features/app/screens/onboarding_screen.dart'; // Убедись, что импорт правильный (или класс ниже)
import 'package:canvas_app/shared/dialogs/show_app_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

class PolicyScreen extends StatefulWidget {
  const PolicyScreen({super.key});

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen> {
  bool _isLoading = false;

  Future<bool> _askAge() async {
    final result = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Подтверждение возраста')),
        content: Text(
          tr('Контент 18+ может содержать нецензурную лексику, жестокость и материалы для взрослых.\n\nВам исполнилось 18 лет?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Мне меньше 18')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Мне есть 18 лет')),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _acceptPolicy() async {
    setState(() => _isLoading = true);

    // 1. Сохраняем согласие
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('policy_accepted', true);

    // 1.1 Сразу спрашиваем возраст, чтобы 18+ контент не потерялся.
    if (mounted) {
      final isAdult = await _askAge();
      await prefs.setBool('adult_confirmed', isAdult);
    }

    // 2. Проверяем, был ли пройден онбординг
    final hasCompletedOnboarding =
        prefs.getBool('has_completed_onboarding') ?? false;

    if (!mounted) return;

    // 3. Навигация
    if (hasCompletedOnboarding) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => MenuScreen()));
    } else {
      // Если у тебя OnboardingScreen в отдельном файле - импортируй его.
      // Если он в main.dart, придется либо вынести его, либо использовать именованный роут,
      // но лучше вынести OnboardingScreen в отдельный файл или использовать этот код:
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => OnboardingScreen(),
        ), // См. примечание ниже
      );
    }
  }

  void _openPolicy() async {
    final uri = Uri.parse('https://iillumination.github.io/polite/');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: AdaptiveContent(
        maxWidth: 720,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 40.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                // Лого или иконка
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scheme.primary.withOpacity(0.3)),
                  ),
                  child: Icon(
                    Icons.security_rounded,
                    color: scheme.primary,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 32),

                Text(
                  tr('Добро пожаловать\nв Meander'),
                  style: GoogleFonts.manrope(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('Перед началом игры, пожалуйста, ознакомьтесь и примите нашу политику конфиденциальности. Мы заботимся о безопасности ваших данных.'),
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const Spacer(),

                // Ссылка
                Center(
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      children: [
                        TextSpan(
                          text:
                              tr('Нажимая "Принять и продолжить", вы соглашаетесь с '),
                        ),
                        TextSpan(
                          text: tr('Политикой конфиденциальности'),
                          style: TextStyle(
                            color: scheme.primary,
                            decoration: TextDecoration.underline,
                            fontWeight: FontWeight.bold,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = _openPolicy,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Кнопка
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _acceptPolicy,
                    style: ElevatedButton.styleFrom(elevation: 0),
                    child: _isLoading
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: scheme.onPrimary,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            tr('Принять и продолжить'),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
