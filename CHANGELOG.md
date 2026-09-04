# Changelog

## 1.1.0

**Ready and proc are now separate states.** They used to share one marker,
which answered "can I press this?" but not "what does it cost me?" — and that
is the question worth answering, because a procced finisher and a full resource
bar ask for different decisions. Each spell now has four states:

- **up** — your aura is on the unit
- **gone** — the aura is missing
- **ready** — the resource threshold is met, or a burst came off cooldown
- **proc** — the spell lit up on its own; this cast is free

Gold means you saved up for it, cyan means it is free. A lit proc outranks the
resource: while the free cast is up, the gold marker stands down, so the button
never shows two marks saying "press me".

**Procs are found from the buff, not the alert API.** Only some procs light
Blizzard's spell alert; plenty are a plain buff and light nothing — Starweaver's
Warp says "your next Starfall costs no Astral Power" and never touches the
overlay API, so the proc state stayed dark.

Which buff belongs to which spell is not something to hardcode: it differs per
class, per talent build, and moves with patches. The game already says it, in
the buff's own description, and Blizzard regenerates that description every
patch — so the buffs the Cooldown Manager tracks are searched for ones that name
the spell. **All** matches count, not one: Starweaver's Warp frees the next
Starfall, Starweaver's Haze frees the next Starsurge, and Touch the Cosmos frees
whichever of the two you press, so one spell can have several buffs behind it
and each state watches the lot.

Rescanning tops existing states up rather than only filling empty ones, so a
talent that adds a proc is picked up, and a buff that no longer exists is
dropped instead of leaving the state quietly dark. The **free while:** row lists
every tracked player buff with checkboxes, marks the ones whose description
names the selected spell, and warns when none of the chosen ones do — two buffs
a word apart can free two different spells. A proc pointed at a buff also gets a
real countdown on the icon.

Run `/cg preset` again to pick up proc states for your spenders, or click the
fourth pip on any spell in the options window.

**Two markers on one state.** Shift-click (or right-click) a marker in the
gallery to layer a second one on top of the first — a pixel outline plus a proc
glow reads as one distinct mark. Click it again to remove it.

**The resource threshold is set with buttons again.** The slider made it fiddly
to land on an exact number; it is `-` and `+` now, one per click and ten with
shift held. The old minus rendered as an empty box — it used a typographic
minus the game font does not carry.

## 1.0.0

First release.

**Marks action bar buttons in three states per spell**

- **up** — your aura is on the unit, with the time left on the icon
- **gone** — the aura is missing
- **ready / proc** — the resource threshold is met, the spell procced, or a
  major cooldown came up

Works with combo points, holy power, chi, soul shards, arcane charges, essence
and the rest.

**Reminder strip** above the class resource bar: what needs pressing appears
next to the resource you are already watching.

**Sets itself up.** On the first login of a specialization it scans your bars:
anything that spends the class resource, anything the Cooldown Manager tracks
as an aura, and anything in its Essential list becomes a rule. No hardcoded
spell ids, nothing to configure to get started.

**Built for 12.1's closed aura API.** No index or slot aura scans — those hard
error under Midnight's restrictions. Debuff state comes from the Cooldown
Manager's own tracking, resolved engine-side, so it keeps working where reads
do not.

Options window on `/cg` with live previews of every marker.

Tested with EllesmereUI on a Feral druid and a Holy paladin, ruRU client. Other
action bar addons are supported in code but untried — reports welcome.
