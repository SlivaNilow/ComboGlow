# Публикация на CurseForge

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

**Автообновление.** Позже можно подключить GitHub Actions, чтобы релиз в
репозитории сам собирал архив и заливал его. Для этого понадобится API-токен
CurseForge и `.pkgmeta`; на старте это не нужно.

## Про Wago и WoWInterface

Тот же архив без изменений подходит для https://addons.wago.io и
https://www.wowinterface.com. Wago ощутимо популярнее у пользователей
EllesmereUI — у самой сюиты там есть `X-Wago-ID`.
