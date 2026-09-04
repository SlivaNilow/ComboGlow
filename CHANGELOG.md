# Changelog

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
