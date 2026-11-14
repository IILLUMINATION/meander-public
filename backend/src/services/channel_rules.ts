/**
 * Правила доступа к каналам. Вынесены из роутов, потому что одни и те же
 * проверки нужны в пяти местах, а ошибиться в них (и не заметить) слишком
 * легко: подписчик, сумевший постить, ломает всю модель канала.
 */
export type ChannelRole = string | null | undefined;

/** Писать в канал может только владелец и назначенные админы канала. */
export const canManageChannel = (role: ChannelRole): boolean =>
  role === 'owner' || role === 'admin';

/** Закрытый канал виден только тем, кто в нём состоит. */
export const canReadChannel = (
  isPublic: boolean | null | undefined,
  role: ChannelRole,
): boolean => Boolean(isPublic) || Boolean(role);

/** Комментарии пишет любой подписчик, но не «прохожий». */
export const canCommentInChannel = (role: ChannelRole): boolean =>
  role !== null && role !== undefined;