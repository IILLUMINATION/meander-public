// Бот поддержки: меню, кнопки, языки, разбор свободного текста.
//
// Бот официальной поддержки обязан быть предсказуемым: одинаковый ответ на
// одинаковое действие, кнопки не теряются, а смена языка не сбрасывает
// выбранную категорию. Тесты ниже — контракт этих правил.

const test = require('node:test');
const assert = require('node:assert');

const {
  SUPPORT_CATEGORIES,
  detectLanguage,
  greetingReply,
  handleCallback,
  mainMenuButtons,
  normalizeButtons,
  replyToText,
  ticketSubjectFrom,
  ticketsReply,
} = require('../dist/services/support_bot');

const ids = (reply) => reply.buttons.map((button) => button.id);

test('приветствие содержит меню и не пустое', () => {
  const reply = greetingReply('ru');
  assert.ok(reply.body.includes('поддержка'));
  assert.deepStrictEqual(ids(reply).slice(0, 3), ['new', 'faq', 'my']);
});

test('меню переключает язык кнопкой, а не настройкой', () => {
  assert.ok(ids({ buttons: mainMenuButtons('ru') }).includes('lang:en'));
  assert.ok(ids({ buttons: mainMenuButtons('en') }).includes('lang:ru'));
});

test('выбор категории просит описание и запоминает категорию', () => {
  const result = handleCallback('cat:bug', 'ru', {});
  assert.equal(result.state.awaiting, 'description');
  assert.equal(result.state.category, 'bug');
  assert.equal(result.replies.length, 1);
  assert.ok(result.replies[0].body.includes('Опиши проблему'));
});

test('неизвестная категория не ломает диалог', () => {
  const result = handleCallback('cat:whatever', 'ru', {});
  assert.equal(result.state.awaiting, undefined);
  assert.ok(result.replies[0].body.length > 0);
});

test('все категории, которые предлагает меню, принимаются обработчиком', () => {
  const offered = mainMenuButtons('ru')
    .filter((button) => button.id.startsWith('cat:'))
    .map((button) => button.id.slice(4));
  for (const category of offered) {
    assert.ok(SUPPORT_CATEGORIES.includes(category), `категория ${category} неизвестна`);
    const result = handleCallback(`cat:${category}`, 'ru', {});
    assert.equal(result.state.category, category);
  }
});

test('смена языка меняет язык ответа и запоминается', () => {
  const result = handleCallback('lang:en', 'ru', {});
  assert.equal(result.language, 'en');
  assert.ok(result.replies[0].body.includes('English'));
});

test('«мои обращения» отдаёт статусы на языке пользователя', () => {
  const ru = ticketsReply('ru', [
    { id: '1', subject: 'Квест не грузится', status: 'open', createdAt: '2026-11-01' },
  ]);
  const en = ticketsReply('en', [
    { id: '1', subject: 'Quest fails', status: 'answered', createdAt: '2026-11-01' },
  ]);
  assert.ok(ru.body.includes('ждёт ответа команды'));
  assert.ok(en.body.includes('team replied'));
});

test('пустой список обращений — отдельный ответ, а не пустота', () => {
  const reply = ticketsReply('ru', []);
  assert.ok(reply.body.length > 0);
  assert.ok(reply.buttons.length > 0);
});

test('свободный текст без обращения не теряется и предлагает меню', () => {
  const reply = replyToText('у меня не работает звук', 'ru', {}, []);
  assert.ok(reply.body.includes('Не понял'));
  assert.ok(ids(reply).includes('new'));
});

test('команды /start и /new работают на обоих языках', () => {
  assert.ok(replyToText('/start', 'ru', {}, []).body.includes('поддержка'));
  assert.ok(replyToText('/new', 'en', {}, []).body.includes('Pick a topic'));
});

test('после выбора категории бот молчит: текст станет обращением', () => {
  const reply = replyToText('синий экран при старте', 'ru', { awaiting: 'description', category: 'bug' }, []);
  assert.equal(reply.body, '');
  assert.equal(reply.buttons.length, 0);
});

test('язык из заголовка распознаётся с регионом', () => {
  assert.equal(detectLanguage('en-US'), 'en');
  assert.equal(detectLanguage('ru-RU'), 'ru');
  assert.equal(detectLanguage('de'), 'ru');
  assert.equal(detectLanguage(undefined), 'ru');
});

test('заголовок обращения обрезается и чистится от переводов строк', () => {
  const subject = ticketSubjectFrom('Первая строка\n\nвторая строка');
  assert.equal(subject.includes('\n'), false);
  const long = ticketSubjectFrom('я'.repeat(400));
  assert.ok(long.length <= 120);
  assert.equal(ticketSubjectFrom('   '), 'Без описания');
});

test('кнопки из базы проходят проверку, мусор отбрасывается', () => {
  const buttons = normalizeButtons([
    { id: 'new', label: 'Создать', action: 'callback' },
    { id: '', label: 'пусто' },
    { id: 'x', label: 'y', action: 'link' },
    { id: 'link', label: 'Сайт', action: 'link', url: 'https://example.com' },
    'мусор',
  ]);
  assert.deepStrictEqual(
    buttons.map((button) => button.id),
    ['new', 'link'],
  );
});