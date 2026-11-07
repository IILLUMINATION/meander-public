# Adwaita symbolic icons

Символические иконки GNOME из темы `adwaita-icon-theme` 51 (Arch Linux,
`/usr/share/icons/Adwaita/symbolic/`). Скопированы только те, что нужны
экрану библиотеки.

Пакет `adwaita_icons` с pub.dev сюда не подходит: последний релиз 0.2.1
объявляет `environment: sdk: ">=2.12.0 <3.0.0"` и зависит от `flutter_svg 1.x`,
который конфликтует с `pdf` (`xml` 6 против 7). Поэтому SVG лежат в
репозитории как ассеты и рендерятся через `flutter_svg` 2.x.

Лицензия иконок — `CC-BY-SA-3.0 OR LGPL-3.0-only`; текст LGPL-3.0 лежит рядом
(`LICENSE-LGPL-3.0`). Иконки не изменялись. Перекраска в цвет текста
(`ColorFilter.mode(..., BlendMode.srcIn)`) — способ отрисовки, не правка
файлов.

Источник: <https://gitlab.gnome.org/GNOME/adwaita-icon-theme>