# ComboGlow

Marks action bar buttons by class-resource count, proc, and your own aura —
for World of Warcraft 12.1 (Midnight), where the aura APIs are largely closed
to addons.

**[English](#english) · [Русский](#русский)**

---

# English

Highlights an action bar button on three states per spell:

| State | Lights up when | Default look |
|-------|----------------|--------------|
| **up** | your aura is on the unit | green frame |
| **gone** | the aura is missing | red frame |
| **ready / proc** | the resource threshold is met **or** the spell procced | gold glow |

Works for combo points, holy power, chi, soul shards, arcane charges, essence
and the rest. Optionally mirrors the same marks as icons in the middle of the
screen.

It is a standalone folder: EllesmereUI updates cannot overwrite it, but when
that suite is loaded ComboGlow borrows its glow engine (`EllesmereUI.Glows`)
so the animated markers match the rest of the interface.

## Getting started

Nothing to configure. The first time you log in on a specialization the addon
scans your bars and creates a rule for **every spell that spends the class
resource**, printing what it added.

A fixed cost becomes an "at least this much" threshold (Word of Glory — 3 holy
power); a variable one becomes "at maximum" (combo point finishers report a
minimum of 1, so the current cap is used: 5, or 6 with the talent). Spells the
Cooldown Manager tracks as auras get an aura rule as well. No hardcoded spell
ids and no per-class tables, so nothing rots across patches.

Open the options window with `/cg`. Pick a spell on the left, a state on top,
then click a marker — that click is also what creates the state, so setting one
up is a single click.

Re-scan after rearranging your bars with `/cg preset`; wipe the spec with
`/cg clear`.

## The options window

The list shows **one row per spell** with three pips on the right — green, red,
gold — lit for the states that are set up. The strip above the gallery switches
which state you are editing, and every gallery tile is a live preview: a real
overlay running the same code as the bar, drawn on that spell's own icon.

The **watching:** row matters for spells that apply another spell's debuff.
Primal Wrath puts Rip on everything, so its button has no aura of its own —
point it at Rip and the button lights from Rip's debuff. Every class has a pair
like it.

## Markers

Six in the gallery, all visually distinct:

| Key | What it is |
|-----|------------|
| `solid` | crisp coloured frame around the icon |
| `fill` | colour wash over the icon |
| `active` | Blizzard's soft highlight border |
| `pixel` | marching dashes |
| `shine` | orbiting sparkles |
| `modern` | proc glow |

`pixel`, `shine` and `modern` are drawn by EllesmereUI's engine when it is
loaded, and fall back to built-in looks when it is not. A few more styles
(`button`, `gcd`, `classic`) remain available through `/cg style` but are kept
out of the gallery: once tinted they are indistinguishable from the ones above.

A few seconds before the aura runs out the frame turns red — `/cg warn <#>
<seconds>`, 4 by default, `0` disables. The threshold works even when the
duration is secret: it is baked into a step colour curve the engine evaluates.

## Count formats

| Written | Means |
|---------|-------|
| `5` | 5 or more |
| `5+` | the same |
| `=5` | exactly 5 |
| `3-4` | between 3 and 4 |
| `max` | at the current maximum (follows talents that raise the cap) |

## Commands

| Command | What it does |
|---------|--------------|
| `/cg` | open the options window |
| `/cg help` | command list |
| `/cg preset` | scan the bars and set up what it finds |
| `/cg clear` | remove every rule of this spec |
| `/cg list` | list the rules, with data source and button count |
| `/cg add <count> <spell>` | resource rule |
| `/cg dot [spell]` \| `/cg buff [spell]` | aura rule; with no argument, the spell you cast last |
| `/cg missing <#>` | flip a rule to "glow while gone" |
| `/cg unit <#> <unit>` | player, target, focus, mouseover, pet |
| `/cg aura <#> <name\|id>` | watch a different aura than the spell itself |
| `/cg warn <#> <seconds>` | turn red this long before it ends |
| `/cg style <#\|all> <key>` | marker |
| `/cg color <#> r g b` | colour, 0–255 |
| `/cg alpha <#\|all> <0-100>` \| `/cg thick <#\|all> <1-10>` | brightness, frame thickness |
| `/cg timer <#> on\|off` | time left on the icon |
| `/cg center <#>` | mirror the mark to the middle of the screen |
| `/cg poll <ms>` | how often aura state is re-read (0 = events only) |
| `/cg mirror on\|off` | Cooldown Manager fallback |
| `/cg secret on\|off` | restricted-content mode |
| `/cg auracheck` \| `/cg cdtest` | diagnostics |

Rules are stored **per specialization, per character**.

## Why AdiButtonAuras stopped working, and what this does instead

AdiButtonAuras targets `## Interface: 110200` (11.2) and enumerates auras with
`GetAuraDataByIndex` / `GetAuraSlots` / `GetDebuffDataByIndex`. Under 12.1's
aura restrictions those **hard error** rather than returning nothing.

There is not a single enumeration here. Only direct per-spell queries:

* `C_UnitAuras.GetAuraDataBySpellName(unit, name, "HARMFUL|PLAYER")` — is your
  own aura there;
* `C_UnitAuras.GetUnitAuraBySpellID` / `GetPlayerAuraBySpellID` for the ids
  Blizzard kept readable;
* `C_UnitAuras.GetAuraDuration` → `Cooldown:SetCooldownFromDurationObject`,
  which renders engine-side and so survives a secret number;
* `C_Secrets.ShouldAurasBeSecret` / `ShouldSpellAuraBeSecret` to know which
  mode we are in.

In practice on 12.1 `ShouldAurasBeSecret` answers **true everywhere**, even on
a target dummy in a city, and `ShouldSpellAuraBeSecret` is true for ordinary
dots. So debuffs on a target cannot be read at all, and everything rests on the
Cooldown Manager mirror below: presence yes, remaining time no. Your own buffs
from Blizzard's readable set work fully, with a real timer.

`/cg auracheck` prints exactly what the API answers where you are standing.

## The Cooldown Manager mirror

When the aura cannot be read, the engine still knows: a Cooldown Manager item
frame tracks aura presence itself. Its answer is a **secret boolean**, which
must never be tested in Lua — it goes to `SetAlphaFromBoolean` and is resolved
engine-side. The remaining time rides the same trick: the engine has already
written it into its own FontString and `SetText` accepts secret strings, so the
text is passed through verbatim.

Only works for spells tracked in the Cooldown Manager, which is why it is a
fallback. `/cg mirror off` disables it.

## Display latency

The default UI redraws on `UNIT_AURA`, and when that event is late a debuff
appears a second after it landed, or only after re-targeting. Two extra paths:

* **instant on cast** — a successful cast of a tracked spell flips the display
  without waiting for confirmation, running the previous known duration. Real
  data overrides the guess; the window is 2 s, so an immunity or a miss clears
  itself.
* **polling** — aura state is re-read every 200 ms, not only on the event.
  `/cg poll 100`, `/cg poll 0` to rely on events alone.

`/cg auracheck` reports the measured gap between your cast and the first
successful read, so "is the data late or just the redraw" is answered with a
number.

## Bars

Buttons are found on:

* **EllesmereUIActionBars** (`EABButton<slot>`) — that module builds its own
  buttons and deliberately removes them from Blizzard's registry, so they have
  to be looked up by name or an EUI setup yields nothing at all;
* Blizzard's own bars (`ActionBarButtonEventsFrame.frames`);
* Dominos;
* anything built on `LibActionButton-1.0` (Bartender4, ElvUI, …);
* Cooldown Manager icons, optionally, with `/cg cdm on`.

Macros are resolved to the spell they cast, and base spells and overrides
(forms, talents that swap ids) are matched.

## Secret values

Under restrictions `UnitPower()` can return a *secret value*: a number that can
be handed to a C function but never compared in Lua. So visibility above a
threshold is produced geometrically rather than by a condition — the value goes
into `StatusBar:SetValue()` and the fill drives a clipping frame containing the
glow, so the whole comparison happens inside the engine.

If that path ever misbehaves, `/cg secret off` disables it: markers then simply
do not show in restricted instances and work normally everywhere else.

## Notes

* `/cg` is a short alias. If another addon claims it, ComboGlow falls back to
  `/cgl`, then `/cglow`; `/comboglow` always works.
* The addon only reads `UnitPower` and draws frames. It casts nothing and
  presses nothing — ordinary UI code.

## Licence

MIT, see [LICENSE](LICENSE).

## Support

If it saved you an evening of fighting Midnight's secret values, you can chip
in any amount you like:

**YooMoney:** https://yoomoney.ru/to/4100119613908309

---

# Русский

Подсветка кнопок панели по количеству классового ресурса, проку и твоей
собственной ауре — для World of Warcraft 12.1 (Midnight), где API аур почти
целиком закрыт для аддонов.

Три состояния на заклинание:

| Состояние | Когда горит | Вид по умолчанию |
|-----------|-------------|------------------|
| **висит** | твоя аура на цели | зелёная рамка |
| **нет** | ауры нет | красная рамка |
| **готово / прок** | набран ресурс **или** заклинание прокнуло | золотое свечение |

Работает с комбо-очками, святой силой, ци, осколками души, чародейскими
зарядами, сущностью и остальными. По желанию дублирует отметки иконками в
центре экрана.

Отдельная папка: обновления EllesmereUI её не затирают, но если сюита
загружена, ComboGlow берёт её движок подсветки (`EllesmereUI.Glows`), поэтому
анимированные отметки выглядят как в остальном интерфейсе.

## Быстрый старт

Настраивать ничего не нужно. При первом входе на специализацию аддон сам
сканирует панели и создаёт правило на **каждое заклинание, которое тратит
классовый ресурс**, и пишет в чат, что добавил.

Фиксированная стоимость становится порогом «столько и больше» (Слово Славы — 3
святой силы), переменная — «на максимуме» (финишеры на комбо-очках отдают
минимум 1, поэтому берётся текущий кап: 5, или 6 с талантом). Заклинания,
которые Cooldown Manager отслеживает как ауры, получают ещё и правило на ауру.
Никаких зашитых ID и списков по классам — ничего не протухает от патча к
патчу.

Окно настроек — `/cg`. Слева выбираешь заклинание, сверху состояние, потом
кликаешь отметку; этот же клик состояние и создаёт, так что настройка в один
клик.

Пересканировать после перестановки панелей — `/cg preset`, стереть всё на
спеке — `/cg clear`.

## Окно настроек

В списке **одна строка на заклинание**, справа три точки — зелёная, красная,
золотая, — горят те, чьи состояния настроены. Полоска над галереей переключает
редактируемое состояние, а каждая плитка галереи это живое превью: настоящий
оверлей тем же кодом, что рисует на панели, на иконке этого заклинания.

Строка **«следит за:»** нужна для заклинаний, вешающих чужой дебафф.
Первобытный гнев накладывает Разорвать, своей ауры у его кнопки нет — указываешь
ему следить за Разорвать, и кнопка загорается от его дебаффа. Такая пара есть у
каждого класса.

## Отметки

В галерее шесть, все визуально разные:

| Ключ | Что это |
|------|---------|
| `solid` | чёткая цветная рамка вокруг иконки |
| `fill` | заливка иконки цветом |
| `active` | мягкая рамка Blizzard |
| `pixel` | бегущий пунктир |
| `shine` | искры по кругу |
| `modern` | проковое свечение |

`pixel`, `shine` и `modern` рисует движок EllesmereUI, если он загружен; без
него заменяются собственными видами. Ещё несколько стилей (`button`, `gcd`,
`classic`) доступны через `/cg style`, но в галерею не выведены: после
тонировки они неотличимы от перечисленных.

За несколько секунд до конца ауры рамка краснеет — `/cg warn <№> <секунд>`, по
умолчанию 4, `0` выключает. Порог работает даже с секретной длительностью: он
запечён в ступенчатую цветовую кривую, которую вычисляет движок.

## Формат количества

| Запись | Значение |
|--------|----------|
| `5` | 5 и больше |
| `5+` | то же самое |
| `=5` | ровно 5 |
| `3-4` | от 3 до 4 |
| `max` | на текущем максимуме (учитывает таланты, поднимающие капу) |

## Команды

| Команда | Что делает |
|---------|-----------|
| `/cg` | открыть окно настроек |
| `/cg help` | список команд |
| `/cg preset` | просканировать панели и настроить найденное |
| `/cg clear` | удалить все правила этой спеки |
| `/cg list` | список правил, с источником данных и числом кнопок |
| `/cg add <кол-во> <заклинание>` | правило на ресурс |
| `/cg dot [закл]` \| `/cg buff [закл]` | правило на ауру; без аргумента — последний каст |
| `/cg missing <№>` | перевернуть: светиться когда ауры нет |
| `/cg unit <№> <юнит>` | player, target, focus, mouseover, pet |
| `/cg aura <№> <имя\|id>` | следить за другой аурой, а не за самим заклинанием |
| `/cg warn <№> <секунд>` | краснеть за столько до конца |
| `/cg style <№\|all> <ключ>` | отметка |
| `/cg color <№> r g b` | цвет, 0–255 |
| `/cg alpha <№\|all> <0-100>` \| `/cg thick <№\|all> <1-10>` | яркость, толщина рамки |
| `/cg timer <№> on\|off` | остаток времени на иконке |
| `/cg center <№>` | дублировать отметку в центр экрана |
| `/cg poll <мс>` | как часто перечитывать ауры (0 = только события) |
| `/cg mirror on\|off` | запасной путь через Cooldown Manager |
| `/cg secret on\|off` | режим закрытых значений |
| `/cg auracheck` \| `/cg cdtest` | диагностика |

Правила хранятся **отдельно для каждой специализации и персонажа**.

## Почему AdiButtonAuras перестал работать, и что здесь вместо него

У AdiButtonAuras в `.toc` стоит `## Interface: 110200` (11.2), и ауры он
перебирает через `GetAuraDataByIndex` / `GetAuraSlots` / `GetDebuffDataByIndex`.
Под ограничениями 12.1 такие переборы **падают с ошибкой**, а не отдают пустоту.

Здесь нет ни одного перебора. Только точечные запросы:

* `C_UnitAuras.GetAuraDataBySpellName(unit, name, "HARMFUL|PLAYER")` — есть ли
  конкретно твоя аура;
* `C_UnitAuras.GetUnitAuraBySpellID` / `GetPlayerAuraBySpellID` для ID, которые
  Blizzard оставила читаемыми;
* `C_UnitAuras.GetAuraDuration` → `Cooldown:SetCooldownFromDurationObject` —
  рисует на движке, поэтому переживает секретное число;
* `C_Secrets.ShouldAurasBeSecret` / `ShouldSpellAuraBeSecret` — в каком мы
  режиме.

На практике в 12.1 `ShouldAurasBeSecret` возвращает **true везде**, даже на
манекене в городе, а `ShouldSpellAuraBeSecret` — true для обычных дотов. То
есть дебаффы на цели не читаются в принципе, и всё держится на зеркале
Cooldown Manager: наличие есть, времени нет. Собственные баффы из читаемого
набора Blizzard работают полностью, с настоящим таймером.

`/cg auracheck` печатает, что именно отвечает API там, где ты стоишь.

## Зеркало Cooldown Manager

Если ауру прочитать нельзя, движок всё равно её знает: иконка Cooldown Manager
сама отслеживает наличие. Её ответ — **секретный булев**, его нельзя проверять
в Lua, поэтому он уходит в `SetAlphaFromBoolean` и разрешается на стороне
движка. Остаток времени тем же приёмом: движок уже написал его в свою
FontString, а `SetText` принимает секретные строки, так что текст переносится
как есть.

Работает только для заклинаний, отслеживаемых в Cooldown Manager — потому это
и запасной путь. Выключается `/cg mirror off`.

## Задержка отображения

Стандартный интерфейс перерисовывается по `UNIT_AURA`, и когда событие
опаздывает, дебафф появляется через секунду или только после перевыбора цели.
Два дополнительных пути:

* **мгновенно по касту** — успешный каст отслеживаемого заклинания сразу
  переключает отметку, не дожидаясь подтверждения, и берёт прошлую известную
  длительность. Настоящие данные перебивают догадку; окно 2 секунды, так что
  иммун или промах гаснут сами.
* **опрос** — состояние перечитывается каждые 200 мс, а не только по событию.
  `/cg poll 100`, `/cg poll 0` — жить только на событиях.

`/cg auracheck` показывает замеренный разрыв между твоим кастом и первым
удачным чтением, так что «опаздывают данные или перерисовка» отвечается цифрой.

## Панели

Кнопки ищутся:

* **EllesmereUIActionBars** (`EABButton<слот>`) — этот модуль делает свои
  кнопки и намеренно вычёркивает их из реестра Blizzard, поэтому искать их надо
  по имени, иначе на EUI-сборке не находится вообще ничего;
* стандартные панели Blizzard (`ActionBarButtonEventsFrame.frames`);
* Dominos;
* всё на `LibActionButton-1.0` (Bartender4, ElvUI и др.);
* иконки Cooldown Manager — по желанию, `/cg cdm on`.

Макросы разбираются до заклинания, которое они кастуют; учитываются базовые
заклинания и оверрайды (формы, таланты, подменяющие ID).

## Секретные значения

Под ограничениями `UnitPower()` может вернуть *secret value* — число, которое
можно отдать C-функции, но нельзя сравнить в Lua. Поэтому видимость выше порога
строится геометрией, а не условием: значение уходит в `StatusBar:SetValue()`, а
полоса заполнения двигает обрезающий фрейм со свечением внутри, и всё сравнение
происходит внутри движка.

Если этот путь поведёт себя странно — `/cg secret off`: тогда в таких инстансах
отметки просто не показываются, а везде остальном всё работает как обычно.

## Мелочи

* `/cg` — короткий алиас. Если его занял другой аддон, ComboGlow берёт `/cgl`,
  потом `/cglow`; `/comboglow` работает всегда.
* Аддон только читает `UnitPower` и рисует рамки. Ничего не кастует и не
  нажимает — обычный UI-код.

## Лицензия

MIT, см. [LICENSE](LICENSE).

## Поблагодарить

Если аддон сэкономил тебе вечер возни с секретными значениями Midnight — можно
поддержать любой комфортной суммой:

**ЮMoney:** https://yoomoney.ru/to/4100119613908309
