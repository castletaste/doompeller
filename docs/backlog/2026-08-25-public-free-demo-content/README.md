# Публичный свободный demo-content для Doompeller

- Дата: 2026-08-25
- Статус: открыт
- Затронутые компоненты/системы: content pipeline, WAD compatibility, assets, лицензирование, release packaging

## Проблема

Публичная сборка Doompeller не может включать оригинальный коммерческий
DOOM.WAD или извлечённые из него карты, текстуры, спрайты, палитры и звуки.
Одновременно showcase должен уметь запускаться без локальной копии игры. Нужен
свободно распространяемый demo-content, который демонстрирует тот же нативный
WAD → Flame 3D pipeline и не создаёт лицензионных или trademark-рисков.

Тема явно исключена из текущего E1M1 scope и отложена до отдельного решения.

## Текущее состояние

- CI и package-тесты используют генерируемый в Dart synthetic PWAD; он
  предназначен для проверки форматов и renderer-инвариантов, а не как
  пользовательский уровень.
- Оригинальный E1M1 доступен только developer-only через явный
  `DOOM_WAD_PATH`; `.local/` и WAD-расширения исключены из Git.
- Runtime не скачивает WAD, не сканирует файловую систему и не сохраняет
  извлечённые данные.

## Доказательства и источники

- `docs/PLAN.md` — content/licensing posture и явный out-of-scope для public demo.
- `lib/game/content_source.dart` — только explicit developer IWAD и synthetic fixture.
- `.gitignore` — `.local/`, `*.wad` и `*.WAD`.
- `packages/doom_wad/lib/src/fixtures.dart` — byte-deterministic legal fixture PWAD.

## Что можно сделать дальше

### Проверить существующий свободный IWAD-контент

- Подход: исследовать подходящий clean-room/free-content IWAD, проверить
  актуальную лицензию каждого типа данных, совместимость с текущим vanilla WAD
  parser и допустимость публичной перепаковки.
- Цена/усилия: неизвестно; требуется отдельный license audit и прогон geometry/gameplay corpus.
- Риски: несовместимые node formats, неоднородные лицензии, trademark и
  ошибочное впечатление об endorsement. Кандидаты намеренно не утверждены до
  исследования.

### Создать собственный небольшой showcase PWAD

- Подход: спроектировать оригинальную карту и оригинальные palette-indexed
  textures/sprites/audio, затем собирать WAD воспроизводимым toolchain.
- Цена/усилия: высокая; нужны level design, pixel art, sound design и отдельный QA.
- Риски: scope превращается из engine showcase в content-production проект;
  потребуется явно выбрать лицензию на assets.

### Расширить synthetic fixture до интерактивного tutorial level

- Подход: сохранить полностью code-generated content, но добавить осмысленный
  маршрут, doors/lifts/enemies/pickups/exit и более выразительные procedural assets.
- Цена/усилия: средняя.
- Риски: визуально слабее ручного контента; fixture и публичный уровень могут
  начать конфликтовать по целям, поэтому их лучше разделить.

## Ссылки

- Связанный production-план: `docs/PLAN.md`.
- Внешние лицензии и кандидаты ещё не исследованы.
