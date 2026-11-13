/// Ширина декодирования для картинки, которая занимает 1/[divisor] экрана.
///
/// Возвращает физические пиксели: столько, сколько картинка реально может
/// занять на экране, — и ни пикселем больше. Без этого `Image`/`CachedNetworkImage`
/// декодирует исходный файл целиком: фото 12 Мп — это ~48 МБ в куче на кадр,
/// плюс загрузка этой текстуры в GPU в том кадре, где картинка появляется.
///
/// Файл намеренно без импортов: правило проверяется обычным `dart`, без
/// запуска Flutter и устройства.
int imageDecodeWidthFor(
  double physicalScreenWidth, {
  int divisor = 1,
  int min = 200,
  int max = 1440,
}) {
  if (physicalScreenWidth <= 0 || !physicalScreenWidth.isFinite) return min;
  final perTile = physicalScreenWidth / (divisor < 1 ? 1 : divisor);
  return perTile.round().clamp(min, max);
}