# Changelog

## 1.4.0

**Macros work.** They never have. `GetActionInfo` hands back the SPELL a macro
resolves to rather than a macro index, and that number was being passed to
`GetMacroSpell` as an index all along -- so the game answered honestly about a
macro numbered 1822, which does not exist, and every macro on every bar was
silently skipped. A macro slot now resolves exactly like a spell slot. The
macro body is read as a fallback, so a client where that id really is an index
still finds every spell named in a `/cast`, `/use`, `/castsequence` or
`#showtooltip` line.

**Marks can go in the Cooldown Manager**, on the bars, or both -- two switches
on the new Settings page. The tracker is the one place that draws the empowered
art for a dot, so marking state there and leaving the buttons clean is a
coherent way to run this.

**The Cooldown Manager hides per viewer.** Essential, utility, tracked buffs
and buff bars are four displays answering four questions, and wanting one
without the others is ordinary. By scale rather than `Hide()`, as before: the
aura states read those frames.

**Debuffs are quiet outside combat.** A dot missing from a training dummy, or
from whatever you last targeted in a city, is not news, and the row of red
marks it produced is the kind of noise that teaches you to stop reading the
markers at all. Bursts have been combat-only since the first version; auras on
another unit now follow. `/cg peace <#>` shows one anyway.

**Two checkboxes per aura state:** which unit it is looked for on, and whether
it is a buff or a debuff. A scan still pairs them sensibly; after that they are
yours. A harmful aura you carry and a buff you watch on the target are both
real things.

**A settings page**, because six global buttons stacked in the corner of a
per-spell editor is a corner that has become a second window. The spell list
fills the window and shows that it scrolls.

**"Tracked as a cooldown, not as a buff"** is now said as such. A spell sitting
in the utility row and a spell nowhere in the tracker used to read identically,
and they need completely different actions -- the first is the confusing one,
because the spell is plainly there on screen, just in a list that answers when
the ability comes back rather than whether its buff is on you.

`/cg tidy` removes rules that are switched off, on no button and tracked by
nothing -- sediment from repeated scans, and nothing else.
## 1.3.2

**The countdown colouring is off by default now, and opt-in.** It works by
putting a formatter on Blizzard's own Cooldown Manager entries, which is
insecure code reaching into frames the secure path owns. With it on, the chat
box stopped accepting Enter — the text stayed, nothing happened, no error, and
nothing pointing at this addon. Taint surfaces far from its cause, which is why
everything else here stays off that path.

It is still the only honest way to know a dot is about to fall off during a
fight, so it stays available: `/cg entryfmt on`, remembered between sessions.
If anything odd starts happening, that is the first thing to turn back off.

## 1.3.1

**Every free slash prefix is registered, not just the first one.** `/cg` is the
short one and the documentation is written with it, but CityGuide claims it and
ComboGlow steps aside rather than fight over it — which used to mean the readme
was right for most people, wrong for anyone whose `/cg` was taken, and there was
no way to tell which you were except by typing a command that did nothing.

`/cgl` and `/comboglow` now work on every install whatever happened to `/cg`,
and all of them take the same commands.


## 1.3.0

**The countdown warns you itself.** Set a number of seconds on an aura's **up**
tab and its countdown turns the warning colour and switches to tenths for that
last stretch — on the action bar and on the reminder strip, during combat, and
correctly through anything that extends the aura.

That last part is the whole story. In 12.1 nothing will tell an addon how long
is left on a debuff during a fight: `GetAuraDuration` returns nothing, the
Cooldown Manager entry's own getters answer with a secret number, its countdown
text is secret, and the numbers it was armed with cannot be stored, forwarded,
or rebuilt into anything that runs. Every one of those was tried and each is
written down, so the next attempt starts after them rather than through them.

What works is not reading the time at all. The engine is handed a rule — a
numeric rule formatter with a threshold — and it compares that against its own
secret remaining time and draws the answer. The colour lives inside the format
string; the number never comes out. It is the same mechanism tullaCTC uses to
colour cooldown text, applied to the Cooldown Manager's entries, whose text
this addon already mirrors onto the marker.

An estimate was tried first and removed. A clock started by your own cast is
wrong in a different direction depending on what just happened: too early after
an extension, too late after a refresh, silent once it runs past zero. A
smaller promise kept beats a larger one that fails quietly at the moment it
matters. `/cgl entryfmt off` if it fights with another cooldown-text addon.

**A duration object is userdata, not a table.** Every check in the addon said
"table", so every real one was thrown away at the door, including those the API
had been handing back all along. Out of combat nothing noticed — a plain
remaining time answered instead — but in combat there is no plain anything, so
the whole mirrored path went dark and read as a missing API. Sweeps and warning
colours on mirrored dots should behave rather better now.


## 1.2.1

**Changing specialization stopped the markers.** The Cooldown Manager rebuilds
its viewers for the new spec, so every mirror the addon held pointed at the old
item frames — and the map is only re-read when the addon rebuilds, which
happened first, before the new viewers existed. A second `/reload` fixed it
because by then they did. The viewer's own `Layout` fires at exactly that
moment, so it now marks the addon dirty as well, with two delayed passes
backing it up: a viewer can lay itself out before its entries have any data.

**Hiding the Cooldown Manager no longer blinks.** It was hidden by alpha, and
Blizzard fades the viewer in when its contents change — a fade drives alpha, so
whatever was set got overwritten a moment later. That is the blink every few
seconds; reapplying sooner only made the fight faster. It is hidden by scale
now, which is not animated: half a pixel across, still laid out, still ticking,
still readable. `Hide()` is what the addons dedicated to this use and is not
open to us — a hidden frame stops updating, and the aura states read the
countdown text off these very frames.

The scale the viewer had before is remembered and restored, and it is never
hidden while Edit Mode is open, which is where it gets configured.

## 1.2.0

**The reminder strip closes its gaps.** It reserved a slot for every state
whether or not it could ever light, because a state resolved engine-side is one
we cannot read — and reading the Cooldown Manager entry's state was filed as
impossible. It is not: `IsActive()` is the secret one, `IsShown()` is plain. It
only means "inactive" when the player has **hide when inactive** on for that
viewer, and there is no way to ask which setting they chose — so it is
inferred. If any tracked entry is hidden right now the setting is on and the
flag can be believed; with it off nothing is ever hidden, nothing is inferred,
and the layout falls back to reserving a slot. Wrong only in the harmless
direction: it never packs away an icon that might be lit.

Turn **hide when inactive** on in the Cooldown Manager and the strip closes up.

The row is also ordered by what an icon means rather than by the order its rule
was created in — a free cast, what is up, what has fallen off, and last the
buttons that are simply ready. `/cg rows on` gives each kind its own row, so a
dot appearing does not shift the bursts. `/cg pack off` keeps the old fixed
slots.

**The Cooldown Manager can be hidden without being switched off.** Everything
the aura states know comes from it, so it has to keep running: this sets alpha
and never calls `Hide()`. Blizzard puts the alpha back when it rebuilds a
viewer, so its `Layout` is hooked and the reapply deferred a frame — otherwise
Layout is still running and undoes it. It is never hidden while Edit Mode is
open, which is where the Cooldown Manager is configured.

**A minimap button**, and a **Cooldown Manager settings** button in the options
window — that is where half the setup happens, and finding it was most of the
chore. The readme now gives the order to do it in: put what you want marked
into the Cooldown Manager first, then scan the bars, because the scan can only
pick up auras it already tracks.

**A state can watch several auras.** One cast can land two debuffs — Vampiric
Touch applies Shadow Word: Pain with the talent — so the **watching:** row is a
checklist, and an ordinary state is "up" only when all of its auras are. A proc
reads its list the other way: any one of its buffs will do. The list offers
everything the Cooldown Manager tracks, not just spells that already have
rules; a state is pointed elsewhere precisely when its own aura is invisible.

**The gallery starts with a "none" tile** that turns a state off without
deleting it, replacing both the "state on" checkbox and the "delete state"
button. Deleting a state you may want back was never the right answer to "do
not light this one".

**Aura stack counts** on the marker, read from the aura where that is possible
and copied as text from the Cooldown Manager where it is not — the count lives
on the entry's children, which is where the countdown comes from too.
`/cg stackpos` and `/cg stacksize` place and size them.

**Runes no longer produce resource rules.** They refill by themselves and
continuously, so "you have two runes" is true most of the time and a Frost
death knight lit up nearly every button. Their cost is still read for the proc
state, where zero means a genuinely free cast.

**The Cooldown Manager dependency is stated up front**, in capitals, at the top
of every language's getting-started section, with the setup steps in the order
they have to happen. The options window names a state whose spell is missing
from it, and says how many auras are tracked for this specialization at all — a
spec where that is zero looks exactly like a broken addon otherwise.

`/cg auracheck` reports the aura's secrecy level per spell rather than a
blanket yes/no, `/cg why` lists what of ours is lit and what the strip is
holding, and `/cg procs`, `/cg stacks`, `/cg cdmdump` and `/cg secretapi` answer
the questions that came up while building this, so the next one does not need a
screenshot.

## 1.1.0

**Ready and proc are now separate states.** They used to share one marker,
which answered "can I press this?" but not "what does it cost me?" — and that
is the question worth answering, because a procced finisher and a full resource
bar ask for different decisions. Each spell now has four states:

- **up** — your aura is on the unit
- **gone** — the aura is missing
- **ready** — the resource threshold is met, or a burst came off cooldown
- **proc** — this cast currently costs nothing

Gold means you saved up for it, cyan means it is free. A lit proc outranks the
resource: while the free cast is up, the gold marker stands down, so the button
never shows two marks saying "press me".

**A proc is detected from the cost, not from a buff.** GetSpellPowerCost
reports what a cast costs RIGHT NOW, with every modifier applied, so a proc
that removes the cost shows up as a zero. Nothing to identify, nothing to
parse, nothing to keep up with patches -- and right for every class at once.
The baseline is learned by watching: the highest cost ever seen, so a talent
that changes it is absorbed and a spell that simply never costs anything cannot
read as permanently free.

Reading the buff description was tried first and abandoned. It says which
spells a buff is ABOUT, not which it makes free: Starsurge came back with five
buffs "naming" it, Starlord and Starweaver among them, because Starsurge
TRIGGERS those. A mention is not a promise.

Buffs remain the fallback where cost cannot answer -- a proc that makes a spell
instant rather than free, say. The **free while:** row lists every player buff
the Cooldown Manager tracks, with the game's own tooltip on hover, and a proc
pointed at one takes its countdown from it.

Run `/cg preset` again to pick up proc states for your spenders, or click the
fourth pip on any spell in the options window.

**Blizzard's own proc glow is suppressed.** The whole point of this addon is
that a mark on a button means something specific — which state, in which
colour, chosen per spell. The game's own glow works against that: it is gold,
it cannot be coloured, it is the same gold as **ready**, and all it says is
"something happened". Two glows on one button, one of them unreadable, is worse
than one. `/cg blizzglow on` brings it back.

It is suppressed by hiding the alert in the same frame the game raises it, not
by replacing `ActionButtonSpellAlertManager.ShowAlert`. That function is called
from the secure action-button path, and a Lua closure in the middle of it
spreads taint — which surfaces as blocked actions in combat, long after the
change that caused it.

**Procs join the reminder strip**, alongside missing dots and bursts coming off
cooldown. All three are things that happen to you rather than because you
pressed something, which is what the strip is for. `/cg procstrip off` drops
just the procs.

The strip also gives a slot per **state** now, not per spell. It used to allow
one per spell, and the second was dropped without a word — a spell's proc could
be enabled, reported as enabled, and never appear, purely because its resource
state came first in the list.

**The strip checkbox tells the truth.** It read only the manual flag, so a dot
the strip had picked up on its own showed an empty box next to an icon that was
plainly there. It reads the actual state now, and it is named after the state
being edited: *on the strip while up / while gone / while ready / on a proc* —
"show above the resource" left out the half that matters.

**Buffs get a "gone" state too.** Only debuffs did, so for a buff the state did
not exist until you clicked the tab, which looked like a display bug rather than
an absent rule. The strip still takes only the debuffs by itself; a buff joins
it if you tick the box.

**Two diagnostics**, because guessing whose glow is whose from a screenshot is
not a debugging method. `/cg why` lists every marker of ours that is lit right
now with its rule, state, style and colour — a glowing button missing from that
list is somebody else's glow. `/cg procs` shows what each proc state is keyed
to and what the cost API answers for it this instant.

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
