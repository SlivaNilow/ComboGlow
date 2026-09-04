# ComboGlow — notes for EllesmereUI maintainers

A companion addon that highlights action bar buttons on two conditions:

1. **Class resource count** — combo points, holy power, chi, soul shards,
   arcane charges, essence… "glow Ferocious Bite at max combo points",
   "glow Word of Glory at 3 holy power".
2. **Your own aura** — glow while your debuff from that spell is on the
   target (or while it is *missing*), with the remaining time on the icon.

It works standalone, and uses EllesmereUI's glow engine when the suite is
present so the look matches the rest of the UI.

## It does not touch any suite file

No file in `EllesmereUI*` is edited, hooked or replaced. The only coupling is
the documented public surface:

```lua
EllesmereUI.Glows.StartGlow(wrapper, styleIdx, w, r, g, b, opts, h)
EllesmereUI.Glows.StopGlow(wrapper)
EllesmereUI.Glows.RestrictionSafeStyle(styleIdx)
```

`EllesmereUI.Glows.STYLES` indices 1–7 are exposed to the user by name. When
the suite is absent, two built-in looks are used instead (Blizzard's proc
flipbook and a coloured alert border), so nothing hard-depends on it.

`RestrictionSafeStyle` is applied **only** in restricted contexts, so a user
who picked Pixel Glow keeps Pixel Glow everywhere else.

## Adopting it as a suite module

`EllesmereUI:RegisterModule` (EllesmereUI.lua) rejects callers outside the
suite's own folders, so as a third-party addon it cannot add an options page —
it ships slash commands instead. To take it in:

1. Rename the folder to `EllesmereUIComboGlow` and update the `.toc`.
2. Add that folder name to the `ALLOWED` table in `EllesmereUI:RegisterModule`.
3. Add an options file under `EllesmereUIOptions` that calls
   `EllesmereUI:RegisterModule("EllesmereUIComboGlow", { ... })`. The rule list
   maps cleanly onto the suite's widget kit: one row per rule with a spell
   picker, a count field, a style dropdown, two colour swatches and three
   checkboxes.
4. `Config.lua` can then be reduced to the diagnostics (`/cg auracheck`) or
   dropped entirely.

Saved variables are `ComboGlowDB`, per character, keyed by specialization ID.

## 12.1 constraints it already handles

These are the parts worth reviewing, because they are where a naive
implementation breaks on this patch:

* **`UnitPower` can be a secret value.** It is never compared in Lua — not even
  against `nil`. Presence is tracked in a parallel plain table and the type
  check goes through `type()`. Above the threshold, visibility is produced
  geometrically: the value is fed to `StatusBar:SetValue()` over a
  `[min-1, min]` range and the fill drives a clipping frame that contains the
  glow, so the whole comparison happens engine-side. An upper bound uses a
  second, vertical bar the same way. `/cg secret off` disables that path.

* **Auras.** No index or slot scan anywhere — those hard-error under aura
  restrictions, which is what breaks AdiButtonAuras on 12.1. Lookups are
  `C_UnitAuras.GetAuraDataBySpellName(unit, name, "HARMFUL|PLAYER")` (by name,
  so cast id ≠ aura id needs no mapping table), with
  `GetUnitAuraBySpellID` when the user pins a specific id. Duration comes from
  `C_UnitAuras.GetAuraDuration` → `Cooldown:SetCooldownFromDurationObject`,
  which renders even when the number is secret; a plain reading additionally
  gets text. `C_Secrets.ShouldAurasBeSecret` / `ShouldSpellAuraBeSecret` are
  used for reporting.

* **Display latency.** The aura event can arrive late. A successful cast of a
  tracked spell flips the display immediately (2 s window, self-correcting from
  the previous known duration), and state is re-read on a 200 ms poll rather
  than only on `UNIT_AURA`. `/cg auracheck` prints the measured gap between
  cast and first successful read.

* **Buttons.** `EABButton<slot>` first — EllesmereUIActionBars builds its own
  buttons and then nils them out of `ActionBarButtonEventsFrame.frames`, so a
  scan of Blizzard's registry alone finds nothing on an EUI setup (this cost a
  debugging round). Then Blizzard's registry, Dominos, and any
  `LibActionButton-1.0` consumer, de-duplicated. Macros are resolved to the
  spell they cast; base spells and overrides are matched. `/cg list` reports
  how many buttons each rule landed on, so "added but nothing glows" is one
  command away from an answer.

* **Defaults.** On the first login of a spec, the bars are scanned and every
  spell that *spends* the class resource becomes a rule — fixed cost becomes a
  threshold, variable cost (combo point finishers report a minimum of 1)
  becomes "at maximum". No hardcoded spell ids or per-class tables, so it does
  not rot across patches.

## Files

| File | Contents |
|---|---|
| `Glow.xml` | overlay + centre icon templates, flipbook and alert textures, timer widgets |
| `Glow.lua` | glow art control, EllesmereUI.Glows bridge, the secret-value clipping gate |
| `Core.lua` | saved variables, rules, button scanning, events, update loop |
| `Auras.lua` | aura queries, timers, cast-time optimism, polling, diagnostics |
| `Config.lua` | slash commands, preset builder |

## Author's note

Written for a user of the suite, not by its author. Untested against a live
restricted instance at the time of writing — the secret-value paths are built
from the patterns the suite itself uses, and `/cg auracheck` exists to confirm
behaviour in M+ from a real report rather than an assumption.
