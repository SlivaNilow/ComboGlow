# Changelog

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

**Two markers on one state.** Shift-click (or right-click) a marker in the
gallery to layer a second one on top of the first — a pixel outline plus a proc
glow reads as one distinct mark. Click it again to remove it.

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
