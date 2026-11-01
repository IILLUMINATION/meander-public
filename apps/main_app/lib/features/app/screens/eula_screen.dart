import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Условия использования (EULA).
///
/// Требование App Store: на экране входа должна быть ссылка на EULA, а в
/// самом тексте — явное правило о нулевой толерантности к неприемлемому
/// контенту и токсичным пользователям. Английская формулировка оставлена
/// дословно: её проверяет ревью Apple.
class EulaScreen extends StatelessWidget {
  const EulaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(tr('Условия использования (EULA)')),
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: AdaptiveContent(
          maxWidth: 720,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Дата вступления в силу: 1 ноября 2026 г.'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                _EulaSection(
                  title: tr('1. Общие положения'),
                  body: tr(
                    'Используя Meander, вы соглашаетесь с настоящими Условиями использования (EULA) и Политикой конфиденциальности. Если вы не согласны с этими условиями, не используйте приложение.',
                  ),
                ),
                _EulaSection(
                  title: tr('2. Аккаунт'),
                  body: tr(
                    'Вы отвечаете за безопасность своего аккаунта и за действия, совершённые под ним. Запрещено создавать аккаунты для обхода блокировок и ограничений.',
                  ),
                ),
                _EulaSection(
                  title: tr('3. Нулевая толерантность'),
                  body: tr(
                    'В Meander нет терпимости к неприемлемому контенту и токсичным пользователям. Запрещены оскорбления, угрозы, травля, разжигание ненависти, спам, мошенничество и публикация незаконных материалов.',
                  ),
                  highlight: tr(
                    'There is no tolerance for objectionable content or abusive users.',
                  ),
                ),
                _EulaSection(
                  title: tr('4. Контент пользователей'),
                  body: tr(
                    'Вы сохраняете права на свой контент, но разрешаете Meander хранить, отображать и распространять его в рамках работы приложения. Вы подтверждаете, что имеете права на загружаемые материалы.',
                  ),
                ),
                _EulaSection(
                  title: tr('5. Модерация и жалобы'),
                  body: tr(
                    'Мы можем удалять контент, ограничивать доступ и блокировать аккаунты за нарушения. Пользователи могут жаловаться на контент и блокировать других авторов. Жалобы рассматриваются модерацией.',
                  ),
                ),
                _EulaSection(
                  title: tr('6. Прекращение доступа'),
                  body: tr(
                    'Мы можем приостановить или прекратить доступ к аккаунту при нарушении этих условий или по требованию закона.',
                  ),
                ),
                _EulaSection(
                  title: tr('7. Ответственность'),
                  body: tr(
                    'Приложение предоставляется «как есть». Мы не гарантируем бесперебойную работу и не несём ответственности за контент пользователей в пределах, разрешённых законом.',
                  ),
                ),
                _EulaSection(
                  title: tr('8. Контакты'),
                  body: tr('Вопросы по условиям и модерации: @meanderRu.'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EulaSection extends StatelessWidget {
  final String title;
  final String body;
  final String? highlight;

  const _EulaSection({required this.title, required this.body, this.highlight});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
          if (highlight != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
              child: Text(
                highlight!,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
