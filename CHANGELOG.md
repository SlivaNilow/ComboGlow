# Changelog

## 1.4.1

**Clear dead rules** — a button on the Settings page with the count on it, or
`/cg tidy`. Rules that are switched off, on no button and tracked by nothing:
leftovers from repeated scans that can never do anything. It appears only when
there are some.

## 1.4.0

**Macros work.** A spell on a macro button is marked the same as one on a plain
button. It never was before — macros were skipped entirely, on every bar.

**Marks can go in the Cooldown Manager.** Two switches on the new Settings
page: the action bars, the Cooldown Manager, or both. The tracker draws things
the bars do not — an empowered dot keeps its own icon there — so marking state
next to it and leaving the buttons clean is a reasonable way to play.

**The Cooldown Manager hides in parts.** Essential, utility, tracked buffs and
buff bars have a switch each, instead of one for all four. It keeps running
either way; the aura states need it.

**Debuff markers keep quiet outside combat**, the way burst markers always
have. A dot missing from a target dummy is not news. `/cg peace <#>` brings one
back if you want it.

**Two checkboxes per aura state:** which unit the aura is looked for on, and
whether it is a buff or a debuff. A scan sets them sensibly; after that they
are yours.

**A Settings page.** The spell list fills the window now and shows that it
scrolls.

**"Tracked as a cooldown, not as a buff"** is said as such, instead of "no
source". The spell is in the Cooldown Manager, just in the list that tracks
when it comes back rather than whether it is on you — and an aura state needs
the second one.

## 1.3.2

**The countdown colouring is off by default** and turned on with
`/cg entryfmt on`. It reaches into Blizzard's own Cooldown Manager frames, and
with it on the chat box stopped accepting Enter. Nothing proved it was the
cause, and nothing cleared it either, so it is a choice you make rather than
one you inherit.

## 1.3.1

**`/cgl` always works.** `/cg` is shorter and the documentation uses it, but
another addon can take it first — CityGuide does — and only the first free
prefix used to be registered. Now every free one is, so `/cgl` and
`/comboglow` are there whatever happened to `/cg`.

## 1.3.0

**The countdown warns you itself.** Set a number of seconds on an aura's **up**
tab and its countdown turns the warning colour and switches to tenths for that
last stretch — on the bar, on the strip, in combat, and correctly through
anything that extends the aura.

Nothing in 12.1 will tell an addon how long is left on a debuff during a fight.
Instead the engine is handed a rule and compares it against its own time; the
answer arrives as colour, and the number is never seen. A clock of our own was
tried first and removed: it was wrong in a different direction depending on
what had just happened.

## 1.2.1

**Changing specialization no longer stops the markers.** The Cooldown Manager
rebuilds itself for the new spec and everything pointed at the old frames, so
it took a second `/reload` to recover.

**Hiding the Cooldown Manager no longer blinks.** It was hidden by fading it
out, and the game fades it back in whenever its contents change. It is scaled
down instead: half a pixel across, still running, still readable by the addon.
It is never hidden while Edit Mode is open, which is where you configure it.

## 1.2.0

**The reminder strip closes its gaps.** It used to reserve a slot for every
state whether it could light or not. Turn **hide when inactive** on in the
Cooldown Manager and the row packs up. `/cg rows on` gives each kind its own
row; `/cg pack off` keeps fixed slots.

**The Cooldown Manager can be hidden without being switched off.** Everything
the aura states know comes from it, so it has to keep running.

**A minimap button**, and a **Cooldown Manager settings** button in the options
window — that is where half the setup happens and finding it was most of the
chore. The readme now gives the order to do it in: put what you want marked
into the Cooldown Manager first, then scan the bars.

**A state can watch several auras.** One cast can land two debuffs, so the
**watching:** row is a checklist: an ordinary state is up only when all of them
are, and a proc is free when any one of them is.

**The gallery starts with a "none" tile** that turns a state off without
deleting it. Deleting a state you might want back was never the right answer to
"do not light this one".

**Aura stack counts** on the marker, placed and sized with `/cg stackpos` and
`/cg stacksize`.

**Runes no longer produce resource rules.** They refill on their own, so "you
have two" is true most of the time and a Frost death knight lit up nearly every
button.

**The Cooldown Manager requirement is stated up front**, in capitals, at the
top of every language's getting-started section. The options window names a
state whose spell is missing from it, and says how many auras are tracked for
this specialization at all — a spec where that is zero looks exactly like a
broken addon otherwise.

## 1.1.0

**Ready and proc are now separate states.** They used to share one marker,
which answered "can I press this?" but not "what does it cost me?" — and that
is the question worth answering. Each spell now has four:

- **up** — your aura is on the unit
- **gone** — the aura is missing
- **ready** — the resource threshold is met, or a burst came off cooldown
- **proc** — this cast currently costs nothing

Gold means you saved up for it, cyan means it is free. While the free cast is
up the gold marker stands down, so a button never shows two marks saying
"press me".

**A proc is detected from the cost.** What a cast costs right now, with every
modifier applied, so a proc that removes the cost shows up as a zero — nothing
to identify, nothing to keep up with patches, and right for every class at
once. Buffs remain the fallback for procs that make a spell instant rather than
free.

**Blizzard's own proc glow is suppressed.** It is gold, it cannot be coloured,
it is the same gold as **ready**, and all it says is "something happened". Two
glows on one button, one of them unreadable, is worse than one.
`/cg blizzglow on` brings it back.

**Procs join the reminder strip**, alongside missing dots and bursts coming off
cooldown — all three are things that happen to you rather than because you
pressed something. `/cg procstrip off` drops just the procs.

**The strip gives a slot per state**, not per spell. It used to allow one per
spell and drop the second without a word.

**Buffs get a "gone" state too.** Only debuffs did, so for a buff the state did
not exist until you clicked the tab, which looked like a display bug.

**Diagnostics:** `/cg why` lists every marker of ours that is lit right now, so
a glowing button missing from that list is somebody else's glow. `/cg procs`
shows what each proc state is keyed to.

**The resource threshold is set with buttons again.** The slider made it fiddly
to land on an exact number; it is `-` and `+` now, one per click and ten with
shift held.

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
as an aura, and anything in its Essential list becomes a rule. No spell ids to
enter, nothing to configure to get started.

**Built for 12.1's closed aura API.** Debuff state comes from the Cooldown
Manager's own tracking, resolved by the engine, so it keeps working where
reading does not.

Options window on `/cg` with live previews of every marker.

Tested with EllesmereUI on a Feral druid and a Holy paladin, ruRU client. Other
action bar addons are supported in code but untried — reports welcome.
