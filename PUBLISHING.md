# Публикация на CurseForge

## Как работать: правки локально, публикация когда готово

Копия папки для этого не нужна — git уже так устроен. Коммит остаётся на диске
и никуда не уходит, пока не сделан `push`.

```bash
git add -A && git commit -m "что сделал"   # столько раз, сколько нужно
git log --oneline origin/main..HEAD        # что накопилось, но ещё не опубликовано
git push                                    # когда доволен результатом
```

Пока не запушено, откатиться можно чем угодно: `git restore .` вернёт файлы к
последнему коммиту, `git reset --hard origin/main` — к тому, что лежит на
GitHub.

Версия, которую ставят люди, помечается тегом. Одной командой:

```powershell
.\release.ps1 1.0.1
```

Скрипт поднимает `## Version:` в `.toc`, коммитит это, ставит тег `v1.0.1` и
пушит всё. Если в рабочей копии есть незакоммиченное — останавливается: релиз
должен подводить черту под законченным, а не подметать заодно недоделанное.

Руками то же самое:

```bash
git tag -a v1.0.1 -m "1.0.1"
git push origin v1.0.1
```

Тега с именем вроде `release`, который переезжает с версии на версию, лучше
избегать: автосборка CurseForge реагирует на **появление** тега и передвинутый
не заметит, а история теряется — по одному слову потом не понять, какой код был
в той версии, что стоит у людей.

Тег и есть «готовый аддон»: `main` может уходить вперёд, а пользователи и
CurseForge берут отмеченную версию. Номер держи в согласии с `## Version:`
в `.toc`.

Отдельная ветка `dev` нужна только если хочется, чтобы **опубликованная**
история `main` оставалась чистой:

```bash
git switch -c dev            # работаешь тут
git switch main && git merge dev   # когда готово
```

Для одного разработчика это чаще лишний шаг: тегов достаточно.

## Что заливать

Архив собирается из папки аддона и должен содержать **папку внутри себя**, а не
файлы россыпью:

```
ComboGlow-1.0.0.zip
└── ComboGlow/
    ├── ComboGlow.toc
    ├── Core.lua
    ├── Auras.lua
    ├── Config.lua
    ├── Options.lua
    ├── Glow.lua
    ├── Glow.xml
    ├── README.md
    └── LICENSE
```

Это единственное жёсткое требование к структуре: клиент CurseForge распаковывает
архив прямо в `Interface\AddOns`, и если файлы лежат в корне архива, аддон
установится сломанным.

В архив **не идут**: `.git`, `.github`, `logo.png`, `INTEGRATION.md`,
`PUBLISHING.md` — это файлы репозитория, игре они не нужны.

### Пересобрать архив

```powershell
$src = "E:\World of Warcraft\_retail_\Interface\AddOns\ComboGlow"
$stage = "$env:TEMP\cg-pkg"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$stage\ComboGlow" | Out-Null
"ComboGlow.toc","Core.lua","Auras.lua","Config.lua","Options.lua","Glow.lua","Glow.xml","README.md","LICENSE" |
    ForEach-Object { Copy-Item (Join-Path $src $_) "$stage\ComboGlow\$_" }
Compress-Archive -Path "$stage\ComboGlow" -DestinationPath "$stage\ComboGlow-1.0.0.zip" -Force
explorer $stage
```

Номер версии в имени архива должен совпадать с `## Version:` в `.toc`.

## Создание проекта

1. Зайти на https://legacy.curseforge.com/wow/addons и нажать **Start Project**
   (новый интерфейс тоже работает, но у legacy-версии форма понятнее).
2. **Project Name:** ComboGlow.
3. **Summary:** одна строка, попадает в поиск. Например:
   `Marks action bar buttons by resource count, procs and your own auras — built for 12.1's closed aura API`
4. **Categories:** Combat, Buffs & Debuffs, Action Bars.
5. **Project Avatar:** `logo.png` из репозитория (512×512).
6. **Description:** взять из `README.md`. CurseForge понимает Markdown —
   можно вставить как есть. Языковые версии сразу пригодятся: английский,
   русский, китайский.
7. **License:** MIT. В поле кастомной лицензии можно дать ссылку на
   `LICENSE` в репозитории.
8. **Source / Issues:** https://github.com/SlivaNilow/ComboGlow

## Загрузка файла

**Upload File** в проекте, и там:

* **Display Name:** `ComboGlow 1.0.0`
* **Release Type:** для первой публикации честнее **Beta**. Аддон обкатан на
  одной сборке и двух специализациях, и `README` об этом прямо говорит —
  ставить Release стоит после отзывов.
* **Game Versions:** `12.1.0` (Midnight). Список должен совпадать с
  `## Interface: 120100` в `.toc`, иначе клиент CurseForge покажет аддон как
  несовместимый.
* **Changelog:** для первой версии достаточно короткого списка возможностей.

## Что стоит подготовить заранее

**Скриншоты.** У аддона визуальная функция, и без картинок его не поставят.
Минимум три: подсвеченная кнопка с таймером, полоса напоминаний над панелью
ресурса, окно настроек с галереей отметок. Свои скриншоты из тестов подходят.

**Модерация.** Первая версия проходит ручную проверку, обычно от нескольких
часов до суток. Пока она не пройдена, проект не виден в поиске.

## Automatic Packaging

В настройках проекта есть поле **Automatic Packaging**. Для первой публикации
оставь **No automatic packaging** и залей архив руками: опубликоваться это не
мешает, а лишний механизм на старте только запутает разбор, если что-то пойдёт
не так.

Когда захочешь включить — всё готово, в репозитории лежит `.pkgmeta`. Он нужен
потому, что корень репозитория и есть папка аддона: без него в установленный
аддон попадут `README`, `PUBLISHING.md`, логотипы и прочие бумаги репозитория.

Дальше выпуск версии выглядит так:

```bash
git tag -a v1.0.1 -m "1.0.1"
git push origin v1.0.1
```

CurseForge увидит тег, соберёт архив по `.pkgmeta` и создаст файл проекта сам.
Номер версии берётся из тега, поэтому его надо держать в согласии с
`## Version:` в `.toc`.

## Тег ≠ GitHub Release

Это ловушка, на которую натыкаются все: `git tag` создаёт метку в истории, а
Wago и автосборка CurseForge ищут **GitHub Release** — отдельный объект,
который делается из тега.

Пока релиза нет, Wago так и пишет: *The associated repository does not have any
releases, yet.*

Создаётся он на сайте: **Releases → Draft a new release**, выбрать существующий
тег, заполнить название и описание, прикрепить архив, опубликовать. Прямая
ссылка на нужный тег:

```
https://github.com/SlivaNilow/ComboGlow/releases/new?tag=v1.0.0
```

Архив прикреплять стоит всегда: сборщик умеет собирать из исходников сам, но с
готовым файлом всё работает независимо от того, разобрался ли он с `.pkgmeta`.

## Про Wago и WoWInterface

Тот же архив без изменений подходит для https://addons.wago.io и
https://www.wowinterface.com. Wago ощутимо популярнее у пользователей
EllesmereUI — у самой сюиты там есть `X-Wago-ID`.
