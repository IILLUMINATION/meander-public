/**
 * Бот поддержки.
 *
 * Здесь нет модели и нет магии: набор текстов, меню и inline-кнопок, которые
 * бот отдаёт клиенту. Дерево задано кодом, потому что ответы официальной
 * поддержки должны быть одинаковыми у всех и проверяться тестами, а не
 * переписываться на каждый запрос.
 *
 * Модуль намеренно без БД: маршрут решает, что записать, а бот — что ответить.
 * Так диалог проверяется юнит-тестами, и правка текста не требует базы.
 */

export type SupportLanguage = 'ru' | 'en';

export interface BotButton {
  /** Идентификатор действия — его присылает клиент при нажатии. */
  id: string;
  label: string;
  /** Группировка для отрисовки: сетка кнопок под сообщением. */
  action: 'callback' | 'link';
  /** Для action=link — адрес. */
  url?: string;
}

export interface BotReply {
  body: string;
  buttons: BotButton[];
}

export interface BotState {
  /** Что бот ждёт от следующего сообщения человека. */
  awaiting?: 'description';
  category?: SupportCategory;
}

export type SupportCategory =
  | 'quest'
  | 'account'
  | 'bug'
  | 'payment'
  | 'other';

export const SUPPORT_CATEGORIES: SupportCategory[] = [
  'quest',
  'account',
  'bug',
  'payment',
  'other',
];

const T = {
  ru: {
    greeting:
      'Привет! Это поддержка Meander. Я бот: помогу с частыми вопросами и передам обращение команде.',
    greetingAgain: 'Чем помочь?',
    menuHint: 'Выбери, с чем нужна помощь, или просто опиши проблему одним сообщением.',
    categories: {
      quest: 'Проблема с квестом',
      account: 'Аккаунт и вход',
      bug: 'Ошибка в приложении',
      payment: 'Платежи и покупки',
      other: 'Другое',
    } as Record<SupportCategory, string>,
    askDescription:
      'Опиши проблему одним сообщением — что произошло и что ты ожидал. Можно приложить до 5 фото.',
    ticketCreated: 'Обращение создано. Команда увидит его и ответит здесь же.',
    ticketClosed: 'Обращение закрыто. Если проблема вернётся — напиши, я создам новое.',
    noTickets: 'Обращений пока нет.',
    faqTitle: 'Частые вопросы:',
    faq: [
      'Не запускается квест — обнови каталог и проверь, что скачалась последняя версия.',
      'Не приходит код входа — проверь папку «Спам» и повтори через минуту.',
      'Слетел прогресс — прогресс хранится в облаке: «Мои квесты» → «Синхронизация».',
    ],
    statusOpen: 'ждёт ответа команды',
    statusAnswered: 'команда ответила',
    statusClosed: 'закрыто',
    langSwitch: 'Язык переключён на русский.',
    staffNote: 'Ответ команды придёт в это же окно.',
    unknown: 'Не понял команду. Вот что я умею:',
  },
  en: {
    greeting:
      "Hi! This is Meander support. I'm a bot: I can answer common questions and pass your issue to the team.",
    greetingAgain: 'How can I help?',
    menuHint: 'Pick a topic or just describe the problem in one message.',
    categories: {
      quest: 'Quest problem',
      account: 'Account and sign-in',
      bug: 'App bug',
      payment: 'Payments and purchases',
      other: 'Something else',
    } as Record<SupportCategory, string>,
    askDescription:
      'Describe the problem in one message — what happened and what you expected. You can attach up to 5 photos.',
    ticketCreated: 'Ticket created. The team will see it and reply right here.',
    ticketClosed: 'Ticket closed. If it comes back, write to me and I will open a new one.',
    noTickets: 'No tickets yet.',
    faqTitle: 'Frequently asked:',
    faq: [
      "A quest won't start — refresh the catalogue and make sure the latest version is downloaded.",
      'The sign-in code never arrives — check spam and retry in a minute.',
      'Progress is gone — progress lives in the cloud: "My quests" → "Sync".',
    ],
    statusOpen: 'waiting for the team',
    statusAnswered: 'team replied',
    statusClosed: 'closed',
    langSwitch: 'Language switched to English.',
    staffNote: 'The team reply will arrive in this chat.',
    unknown: "I didn't catch that. Here is what I can do:",
  },
} as const;

export type SupportTexts = (typeof T)[SupportLanguage];

export const supportTexts = (language: SupportLanguage): SupportTexts =>
  T[language] ?? T.ru;

export const detectLanguage = (value: unknown): SupportLanguage => {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return raw.startsWith('en') ? 'en' : 'ru';
};

const categoryButtons = (language: SupportLanguage): BotButton[] => {
  const texts = supportTexts(language);
  return SUPPORT_CATEGORIES.map((category) => ({
    id: `cat:${category}`,
    label: texts.categories[category],
    action: 'callback',
  }));
};

export const mainMenuButtons = (language: SupportLanguage): BotButton[] => {
  const texts = supportTexts(language);
  return [
    {
      id: 'new',
      label: language === 'en' ? 'New ticket' : 'Создать обращение',
      action: 'callback',
    },
    {
      id: 'faq',
      label: language === 'en' ? 'FAQ' : 'Частые вопросы',
      action: 'callback',
    },
    {
      id: 'my',
      label: language === 'en' ? 'My tickets' : 'Мои обращения',
      action: 'callback',
    },
    {
      id: `lang:${language === 'en' ? 'ru' : 'en'}`,
      label: language === 'en' ? 'Русский' : 'English',
      action: 'callback',
    },
    ...(texts.faq.length > 0 ? [] : categoryButtons(language)),
  ];
};

export const greetingReply = (language: SupportLanguage): BotReply => {
  const texts = supportTexts(language);
  return {
    body: `${texts.greeting}\n\n${texts.menuHint}`,
    buttons: mainMenuButtons(language),
  };
};

/** Кнопка «Создать обращение»: сначала категория, потом описание. */
export const newTicketReply = (language: SupportLanguage): BotReply => ({
  body: supportTexts(language).menuHint,
  buttons: categoryButtons(language),
});

export const askDescriptionReply = (
  language: SupportLanguage,
  category: SupportCategory,
): BotReply => ({
  body: `${supportTexts(language).categories[category]}\n\n${supportTexts(language).askDescription}`,
  buttons: [],
});

export const faqReply = (language: SupportLanguage): BotReply => {
  const texts = supportTexts(language);
  return {
    body: `${texts.faqTitle}\n\n${texts.faq.map((line) => `• ${line}`).join('\n')}`,
    buttons: [
      { id: 'new', label: language === 'en' ? 'New ticket' : 'Создать обращение', action: 'callback' },
      { id: 'menu', label: language === 'en' ? 'Back' : 'Назад', action: 'callback' },
    ],
  };
};

export const langSwitchReply = (language: SupportLanguage): BotReply => ({
  body: `${supportTexts(language).langSwitch}\n\n${supportTexts(language).greetingAgain}`,
  buttons: mainMenuButtons(language),
});

export const unknownReply = (language: SupportLanguage): BotReply => ({
  body: supportTexts(language).unknown,
  buttons: mainMenuButtons(language),
});

export interface TicketSummary {
  id: string;
  subject: string;
  status: 'open' | 'answered' | 'closed';
  createdAt: Date | string;
}

const statusLabel = (language: SupportLanguage, status: TicketSummary['status']): string => {
  const texts = supportTexts(language);
  if (status === 'closed') return texts.statusClosed;
  if (status === 'answered') return texts.statusAnswered;
  return texts.statusOpen;
};

export const ticketsReply = (
  language: SupportLanguage,
  tickets: TicketSummary[],
): BotReply => {
  const texts = supportTexts(language);
  if (tickets.length === 0) {
    return {
      body: texts.noTickets,
      buttons: mainMenuButtons(language),
    };
  }
  const lines = tickets
    .slice(0, 10)
    .map((ticket) => {
      const date = new Date(ticket.createdAt);
      const stamp = Number.isNaN(date.getTime())
        ? ''
        : date.toISOString().slice(0, 10);
      return `• ${ticket.subject} — ${statusLabel(language, ticket.status)}${stamp ? ` (${stamp})` : ''}`;
    })
    .join('\n');
  return {
    body: lines,
    buttons: [
      { id: 'new', label: language === 'en' ? 'New ticket' : 'Создать обращение', action: 'callback' },
      { id: 'menu', label: language === 'en' ? 'Back' : 'Назад', action: 'callback' },
    ],
  };
};

export const ticketClosedReply = (language: SupportLanguage): BotReply => ({
  body: supportTexts(language).ticketClosed,
  buttons: mainMenuButtons(language),
});

export const ticketCreatedReply = (language: SupportLanguage): BotReply => ({
  body: `${supportTexts(language).ticketCreated}\n${supportTexts(language).staffNote}`,
  buttons: [
    { id: 'my', label: language === 'en' ? 'My tickets' : 'Мои обращения', action: 'callback' },
  ],
});

/**
 * Ответ на свободный текст, когда открытого обращения нет.
 *
 * Всё, что не команда, — попытка описать проблему: бот не гадает и предлагает
 * создать обращение кнопкой, но сам текст не теряет — он станет описанием.
 */
export function replyToText(
  text: string,
  language: SupportLanguage,
  state: BotState,
  tickets: TicketSummary[],
): BotReply {
  const command = text.trim().toLowerCase();
  if (command === '/start' || command === '/help' || command === 'меню' || command === 'menu') {
    return greetingReply(language);
  }
  if (command === '/new' || command === 'обращение' || command === 'ticket') {
    return newTicketReply(language);
  }
  if (command === '/status' || command === 'статус' || command === 'status') {
    return ticketsReply(language, tickets);
  }
  if (command.startsWith('/lang')) {
    const next = command.split(/\s+/)[1];
    return langSwitchReply(next === 'en' || next === 'ru' ? next : language === 'ru' ? 'en' : 'ru');
  }
  if (state.awaiting === 'description') {
    // Категория уже выбрана кнопкой — маршрут создаст обращение из этого текста.
    return { body: '', buttons: [] };
  }
  return unknownReply(language);
}

/** Разбор нажатия кнопки: что ответить и что запомнить в состоянии диалога. */
export interface CallbackResult {
  replies: BotReply[];
  state: BotState;
  language?: SupportLanguage;
  /** Пользователь выбрал категорию — следующий текст станет обращением. */
  awaitingCategory?: SupportCategory;
}

export function handleCallback(
  buttonId: string,
  language: SupportLanguage,
  state: BotState,
): CallbackResult {
  if (buttonId === 'menu' || buttonId === 'start') {
    return { replies: [greetingReply(language)], state: {} };
  }
  if (buttonId === 'new') {
    return { replies: [newTicketReply(language)], state: {} };
  }
  if (buttonId === 'faq') {
    return { replies: [faqReply(language)], state: {} };
  }
  if (buttonId === 'my') {
    return { replies: [], state, awaitingCategory: undefined };
  }
  if (buttonId.startsWith('lang:')) {
    const next = detectLanguage(buttonId.slice(5));
    return {
      replies: [langSwitchReply(next)],
      state: {},
      language: next,
    };
  }
  if (buttonId.startsWith('cat:')) {
    const category = buttonId.slice(4) as SupportCategory;
    if (!SUPPORT_CATEGORIES.includes(category)) {
      return { replies: [unknownReply(language)], state: {} };
    }
    return {
      replies: [askDescriptionReply(language, category)],
      state: { awaiting: 'description', category },
      awaitingCategory: category,
    };
  }
  return { replies: [unknownReply(language)], state };
}

/** Короткий заголовок обращения из первого сообщения человека. */
export const ticketSubjectFrom = (text: string): string => {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  if (oneLine.length === 0) return 'Без описания';
  return oneLine.length <= 120 ? oneLine : `${oneLine.slice(0, 117)}…`;
};
/**
 * Кнопки из jsonb: чужая/старая запись не должна ломать ленту, поэтому
 * проверяем каждое поле, а не приводим массив вслепую.
 */
export function normalizeButtons(raw: unknown): BotButton[] {
  if (!Array.isArray(raw)) return [];
  const result: BotButton[] = [];
  for (const item of raw.slice(0, 8)) {
    if (!item || typeof item !== 'object' || !('id' in item) || !('label' in item)) {
      continue;
    }
    const id = typeof item.id === 'string' ? item.id.slice(0, 64) : '';
    const label = typeof item.label === 'string' ? item.label.slice(0, 64) : '';
    if (!id || !label) continue;
    const action =
      'action' in item && item.action === 'link' ? 'link' : 'callback';
    const url =
      action === 'link' && 'url' in item && typeof item.url === 'string'
        ? item.url.slice(0, 300)
        : undefined;
    if (action === 'link' && !url) continue;
    result.push({ id, label, action, ...(url ? { url } : {}) });
  }
  return result;
}
