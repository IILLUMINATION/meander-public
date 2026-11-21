/**
 * Правила доступа к каналам. Вынесены из роутов, потому что одни и те же
 * проверки нужны в пяти местах, а ошибиться в них (и не заметить) слишком
 * легко: подписчик, сумевший постить, ломает всю модель канала.
 */
export type ChannelRole = string | null | undefined;

/** Писать в канал может только владелец и назначенные админы канала. */
export const canManageChannel = (role: ChannelRole): boolean =>
  role === 'owner' || role === 'admin';

/**
 * В официальном канале новостей писать может только его владелец.
 * Админы канала здесь не исключение: новость — лицо проекта, а не
 * редакционная лента, и одна случайная публикация стоит дороже, чем
 * ручное подтверждение каждой.
 */
export const canPublishInChannel = (
  isOfficial: boolean | null | undefined,
  ownerId: string | null | undefined,
  userId: string | null | undefined,
  role: ChannelRole,
): boolean => {
  if (!userId) return false;
  if (isOfficial) return Boolean(ownerId) && ownerId === userId;
  return canManageChannel(role);
};

/** Рассылку «Новости Meander» запускает только владелец официального канала. */
export const canBroadcastNews = (
  ownerId: string | null | undefined,
  userId: string | null | undefined,
): boolean => Boolean(ownerId && userId && ownerId === userId);

/** Закрытый канал виден только тем, кто в нём состоит. */
export const canReadChannel = (
  isPublic: boolean | null | undefined,
  role: ChannelRole,
): boolean => Boolean(isPublic) || Boolean(role);

/** Комментарии пишет любой подписчик, но не «прохожий». */
export const canCommentInChannel = (role: ChannelRole): boolean =>
  role !== null && role !== undefined;