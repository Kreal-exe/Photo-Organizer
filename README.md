# Photo Organizer

**Sort a messy folder of photos and videos into folders by the real capture date — on your Mac, with nothing uploaded.**

Photo Organizer is a small native macOS app (Objective-C / AppKit) for the folder everyone has: a phone backup, a
Google Takeout export, years of “Camera Uploads”. It finds out when every photo and video was really taken, shows the
library the way Apple Photos does, finds duplicates and thumbnails, recognises objects and people, and — when you ask —
moves the files into `2016/`, `2016/07 July/` or `2016-07-14/` folders. Files are **moved, never copied, renamed or
re-encoded**, nothing is ever overwritten, and every move can be undone.

Everything runs locally. No cloud, no account, no subscription.

[Русская версия ↓](#русский)

<p align="center">
  <img src="docs/screenshots/library.png" width="90%" alt="Photo Organizer library">
</p>

## Features

- **Organize by date** — by year (default), month or day, with your own folder names and a preview of the result
  where every folder can be renamed before anything moves.
  - Files are moved with an atomic “never replace” rename: a name clash gets a new name, nothing is overwritten.
  - A progress bar, a journal of every move, and **Undo (⌘Z)** that puts every file back.
- **The real capture date**, not the date the file was copied:
  - EXIF for photos; QuickTime / MP4 metadata for videos (with the 1904 / 1970 epoch bugs of some cameras fixed);
  - a date in the file name (`IMG_20160714_…`, `20220909_145141.mp4`, `IMG-20160714-WA0001`, `Screenshot 2019-07-14…`);
  - Google Takeout `.json` files next to the media;
  - copies of the same shot, and neighbouring frames of the same numbered series.
  - Files with no reliable date are **not guessed into a year**: they go to **No Date**, and **Suggested Dates**
    groups them by rule (“from the folder name *Photos from 2016*”, “like the neighbouring files IMG_0541 and IMG_0543”) with one
    *Confirm* button per rule. Any date can also be set by hand.
- **A library like Apple Photos** — a grid by year, month or day, a year strip on the right to jump through time,
  a built-in viewer for photos and videos with zoom, a **map** of photos with GPS, and *Show in Library* from any
  search result.
- **Duplicates and thumbnails** — exact copies, resized and recompressed versions; *Remove Duplicates* keeps the
  best-quality file of each set and moves the rest to the Trash.
- **Search**
  - **by text**: what’s in the picture (macOS’ built-in image classifier) or a file name;
  - **by photo**: drop a picture and get the visually similar ones;
  - **by object**: drop a photo, draw a frame around a thing (a dog, a car, a mug) and find the photos where
    *that* thing appears — by visual similarity, not by tags.
- **People** — faces are found by Vision and grouped with an ArcFace model (MLX, downloaded on demand);
  face thumbnails in the sidebar, “only photos with this person”, names you give stay.
- **Explicit content detection** (optional) — pick a model by your Mac: MLX on Apple Silicon, Core ML on Intel.
- **VK album download** — sign in to your own VK account in the app and download an album (including *Saved
  photos*) in original size, numbered in the album’s order; an interrupted download resumes where it stopped.
- Drag files out to Finder, ⌘C / ⌘V, adjustable sidebar (⌘+ / ⌘−) and thumbnail size.
- No rescans after work: trash, move or undo, and the library updates in place — recognition results are kept per
  file, so they survive moves on the same disk.
- English and Russian interface (follows the system language), light and dark themes, ~2 MB universal binary.

## Requirements

- macOS 12 Monterey or later, Apple Silicon or Intel
- People and the MLX models need Apple Silicon and Python 3.10+ (or [uv](https://github.com/astral-sh/uv)); the app
  sets up its own environment and downloads the models when you turn the feature on in *Settings*.

## Install

Download `PhotoOrganizer-x.y.z.zip` from [Releases](../../releases), unzip it and drag `PhotoOrganizer.app` to
*Applications*.

The build is not notarized yet, so macOS says it “could not verify” the app. Remove the quarantine flag and launch it:

```bash
xattr -dr com.apple.quarantine /Applications/PhotoOrganizer.app
open /Applications/PhotoOrganizer.app
```

Or: *System Settings → Privacy & Security* → **Open Anyway** (on macOS 15 “right-click → Open” no longer works).

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘O | Open a folder (or drop one on the window) |
| ⌘↩ | Organize into folders… |
| ⌘F / ⇧⌘F | Search / Search by photo |
| ⌘↓ / ⌘↑ | Open in the viewer / back to the grid |
| ⌘⌫ | Move to Trash |
| ⇧⌘M | Move what is shown to a folder… |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘+ / ⌘− / ⌘0 / ⌘9 | Zoom in / out / actual size / fit (viewer); sidebar size (grid) |
| ⌘R / ⇧⌘R | Rescan / Show the folder in Finder |

## Build from source

Only the Xcode Command Line Tools are needed (`xcode-select --install`):

```bash
./build.sh          # → build/PhotoOrganizer.app (universal, ad-hoc signed)
./build.sh run      # build and launch
./build.sh test     # core tests: dates, plan, duplicates, moves, undo
./build.sh zip      # → build/PhotoOrganizer-<version>.zip
./build.sh strings  # check that every Russian string has an English translation
```

**Releasing**: push a version tag — GitHub Actions runs the tests, builds the app with that version and publishes
the release with the zip attached. Nothing is built or uploaded by hand.

```bash
git tag v1.0.1
git push origin v1.0.1
```

### How it works

```
AppKit UI (Objective-C)
  POScanner      walks the folder, reads EXIF / QuickTime / Takeout dates, sizes, GPS
  POPlan         dates from names, copies and neighbours; groups, duplicates, thumbnails, undated files
  PODateSuggestions  rules for undated files (folder name, file name, neighbouring files…)
  POOrganizer    safe moves (renamex_np RENAME_EXCL), journal, undo
  POAnalyzer     Vision: labels, feature prints, salient objects, faces  → cached per file
  POObjectIndex  object search: fp16 feature prints of the whole photo and up to 3 objects
  POPeople       face grouping ── vit_mlx.py (ArcFace / nudity models on MLX, one long-lived process)
  POVKAlbum      VK API: album pages → original-size downloads, 4 at a time
```

| Where | What |
|---|---|
| `~/Library/Application Support/Photo Organizer` | recognition results, object index, dates set by hand, people’s names, the move journal, the MLX environment, the VK sign-in token (readable only by you) |
| `~/.cache/huggingface/hub` | downloaded models (the standard Hugging Face cache, shared with other apps) |

The photos and videos themselves are never modified — only moved, when you ask.

## License

MIT — see [LICENSE](LICENSE). Downloaded models keep their authors’ licenses.

---

<a id="русский"></a>

# Photo Organizer (по-русски)

**Раскладывает папку с фото и видео по папкам по настоящей дате съёмки — на вашем Mac, ничего никуда не загружая.**

Photo Organizer — небольшое нативное macOS-приложение (Objective-C / AppKit) для папки, которая есть у всех: бэкап
телефона, выгрузка Google Takeout, годы «Camera Uploads». Оно выясняет, когда на самом деле снят каждый файл,
показывает медиатеку как «Фото» от Apple, находит дубликаты и миниатюры, распознаёт объекты и людей и — когда вы
попросите — раскладывает файлы по папкам `2016/`, `2016/07 Июль/` или `2016-07-14/`. Файлы **перемещаются, а не
копируются, не переименовываются и не пережимаются**, ничего не перезаписывается, любое перемещение можно отменить.

Всё работает локально: без облака, аккаунтов и подписок.

<p align="center">
  <img src="docs/screenshots/library.png" width="90%" alt="Медиатека Photo Organizer">
</p>

## Возможности

- **Раскладка по датам** — по годам (по умолчанию), месяцам или дням, со своими названиями папок и предпросмотром,
  где любую папку можно переименовать, пока ничего не перемещено.
  - Перемещение — атомарное переименование «без замены»: при совпадении имён файл получает новое имя, ничего не
    перезаписывается.
  - Прогресс, журнал всех перемещений и **отмена (⌘Z)**, которая возвращает каждый файл на место.
- **Настоящая дата съёмки**, а не дата копирования:
  - EXIF у фото; метаданные QuickTime / MP4 у видео (с исправлением ошибок эпохи 1904 / 1970 у некоторых камер);
  - дата в имени файла (`IMG_20160714_…`, `20220909_145141.mp4`, `IMG-20160714-WA0001`, `Screenshot 2019-07-14…`);
  - файлы `.json` из Google Takeout рядом с медиа;
  - копии того же снимка и соседние кадры одной нумерованной серии.
  - Файлам без надёжной даты год **не придумывается**: они попадают в **«Без даты»**, а раздел **«Предполагаемые
    даты»** группирует их по правилам («из названия папки *Photos from 2016*», «как у соседних файлов IMG_0541 и IMG_0543») с кнопкой
    *«Подтвердить»* для каждого правила. Любую дату можно задать вручную.
- **Медиатека как в «Фото»** — сетка по годам, месяцам или дням, полоса годов справа для быстрого перехода,
  встроенный просмотр фото и видео с масштабированием, **карта** снимков с GPS и *«Показать в медиатеке»* из любой выборки.
- **Дубликаты и миниатюры** — точные копии, уменьшенные и пережатые версии; *«Удалить дубликаты»* оставляет файл
  лучшего качества из каждого набора, остальные перемещает в Корзину.
- **Поиск**
  - **по тексту**: что на снимке (встроенный классификатор macOS) или имя файла;
  - **по фото**: перетащите снимок — найдутся похожие;
  - **по предмету**: перетащите фото, обведите рамкой предмет (собаку, машину, кружку) — найдутся снимки, где есть
    *именно он*, по визуальному сходству, а не по тегам.
- **Люди** — лица находит Vision, группирует модель ArcFace (MLX, скачивается по желанию); миниатюры лиц в боковой
  панели, «только фото с этим человеком», заданные имена сохраняются.
- **Распознавание откровенных снимков** (по желанию) — модель подбирается под ваш Mac: MLX на Apple Silicon, Core ML
  на Intel.
- **Загрузка альбома ВК** — войдите в свой аккаунт прямо в приложении и скачайте альбом (в том числе «Сохранённые
  фотографии») в оригинальном размере, с нумерацией в порядке альбома; прерванная загрузка продолжается с того же места.
- Перетаскивание файлов в Finder, ⌘C / ⌘V, масштаб боковой панели (⌘+ / ⌘−) и размера миниатюр.
- Без пересканирования: после удаления, перемещения или отмены медиатека обновляется на месте — результаты
  распознавания хранятся для каждого файла и переживают перемещение в пределах диска.
- Английский и русский интерфейс (по языку системы), светлая и тёмная тема, универсальный бинарник ~2 МБ.

## Требования и установка

macOS 12 Monterey или новее, Apple Silicon или Intel. Для людей и моделей MLX нужны Apple Silicon и Python 3.10+
(или [uv](https://github.com/astral-sh/uv)) — окружение и модели приложение ставит само, когда вы включаете функцию в
«Настройках».

Скачайте `PhotoOrganizer-x.y.z.zip` в [Releases](../../releases), распакуйте и перетащите `PhotoOrganizer.app` в
«Программы».

Сборка пока не нотаризована, поэтому macOS пишет, что «не удалось подтвердить» приложение. Снимите карантинную
пометку и запустите:

```bash
xattr -dr com.apple.quarantine /Applications/PhotoOrganizer.app
open /Applications/PhotoOrganizer.app
```

Или: «Системные настройки» → «Конфиденциальность и безопасность» → **«Всё равно открыть»** (в macOS 15 «правый клик →
Открыть» больше не работает).

## Сочетания клавиш

| Клавиши | Действие |
|---|---|
| ⌘O | Открыть папку (или перетащите её на окно) |
| ⌘↩ | Разложить по папкам… |
| ⌘F / ⇧⌘F | Поиск / Поиск по фото |
| ⌘↓ / ⌘↑ | Открыть в просмотре / вернуться к сетке |
| ⌘⌫ | Переместить в Корзину |
| ⇧⌘M | Переместить показанное в папку… |
| ⌘Z / ⇧⌘Z | Отменить / Повторить |
| ⌘+ / ⌘− / ⌘0 / ⌘9 | Увеличить / уменьшить / реальный размер / по окну (просмотр); размер боковой панели (сетка) |
| ⌘R / ⇧⌘R | Пересканировать / Показать папку в Finder |

## Сборка из исходников

Нужны только Command Line Tools (`xcode-select --install`), Xcode не обязателен:

```bash
./build.sh          # → build/PhotoOrganizer.app (универсальная сборка)
./build.sh run      # собрать и запустить
./build.sh test     # тесты ядра: даты, план, дубликаты, перемещения, отмена
./build.sh zip      # → build/PhotoOrganizer-<версия>.zip
```

**Релиз**: отправьте тег версии — GitHub Actions прогонит тесты, соберёт приложение с этой версией и опубликует релиз
с архивом. Вручную ничего не собирается и не загружается.

```bash
git tag v1.0.1
git push origin v1.0.1
```

## Где хранятся данные

`~/Library/Application Support/Photo Organizer` — результаты распознавания, индекс предметов, заданные вручную даты,
имена людей, журнал перемещений, окружение MLX и токен входа ВК (доступен только вам). Скачанные модели — в общем
кеше Hugging Face `~/.cache/huggingface/hub`. Сами фото и видео приложение не изменяет — только перемещает, когда вы
об этом просите.

## Лицензия

MIT — см. [LICENSE](LICENSE). Скачиваемые модели распространяются по лицензиям их авторов.
