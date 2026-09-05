--[[---------------------------------------------------------------------------
    ComboGlow - Config.lua
    Slash command interface: /comboglow, /cglow, /cg
-----------------------------------------------------------------------------]]

local ADDON, ns = ...
local CG = ns.CG

local RU = GetLocale() == "ruRU"
local function L(en, ru) return (RU and ru) or en end
ns.L = L

local PREFIX = "|cff0cd29fComboGlow|r: "

--[[-------------------------------------------------------------------------
    Slash command token

    Two addons claiming the same token is a coin flip: the chat system builds
    its lookup by iterating SlashCmdList, so whichever happens to come last in
    that traversal wins. /cg is already taken by CityGuide, so it is only
    claimed when nothing else has. Whatever token we end up with is what every
    message advertises -- the texts below all write "/cg" and Say rewrites it.
---------------------------------------------------------------------------]]
local function TokenFree(token)
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "string"
           and k:sub(1, 6) == "SLASH_" and v:lower() == token then
            return false
        end
    end
    return true
end

ns.SLASH = "/comboglow"
for _, token in ipairs({ "/cg", "/cgl", "/cglow" }) do
    if TokenFree(token) then
        ns.SLASH = token
        break
    end
end

local function Localize(msg)
    if ns.SLASH == "/cg" then return msg end
    -- %f[%W] is the frontier pattern: "/cg" only when the next character is
    -- not a letter, so "/cglow" and "/comboglow" are left alone.
    return (msg:gsub("/cg%f[%W]", ns.SLASH))
end

local function Say(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. Localize(msg))
end
ns.Say = Say

-- Same, without the token rewrite: for the one message that has to name the
-- token it could NOT get.
function ns.SayRaw(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- CG.lastCast is filled by Core's UNIT_SPELLCAST_SUCCEEDED handler.

--[[-------------------------------------------------------------------------
    Helpers
---------------------------------------------------------------------------]]

-- "5" / "5+" -> 5, nil        "3-4" -> 3, 4        "=5" -> 5, 5
-- "max" -> at the current maximum of the resource
local function ParseRange(token)
    if not token then return nil end
    token = token:lower()
    if token == "max" or token == "макс" then
        return nil, nil, true
    end
    local a, b = token:match("^(%d+)%s*%-%s*(%d+)$")
    if a then return tonumber(a), tonumber(b), false end
    local eq = token:match("^=(%d+)$")
    if eq then return tonumber(eq), tonumber(eq), false end
    local n = token:match("^(%d+)%+?$")
    if n then return tonumber(n), nil, false end
    return nil
end

-- Pools that refill by themselves. "You have enough" is true most of the time
-- for these, so it is not a moment worth marking -- the same reason mana,
-- energy and rage are not auto-detected as resources at all. Runes are, because
-- their cost still answers "is this cast free right now".
local CONTINUOUS_POWER = {}
if Enum and Enum.PowerType and Enum.PowerType.Runes then
    CONTINUOUS_POWER[Enum.PowerType.Runes] = true
end

local function RangeText(rule)
    if rule.kind == "cd" then
        return L("burst ready", "бурст готов")
    end
    if rule.kind == "aura" then
        local what = rule.helpful and L("buff", "бафф") or L("debuff", "дебафф")
        local where = rule.unit or "target"
        if rule.missing then
            return ("%s %s: %s"):format(what, where, L("MISSING", "НЕТ"))
        end
        return ("%s %s"):format(what, where)
    end
    if rule.atMax then return L("at max", "на максимуме") end
    if rule.max then
        if rule.max == rule.min then return "= " .. rule.min end
        return rule.min .. "-" .. rule.max
    end
    return rule.min .. "+"
end

local function PowerText(rule)
    if rule.kind == "aura" then
        if rule.warn and rule.warn > 0 then
            return ("%s %ds"):format(L("warn", "тревога"), rule.warn)
        end
        return "-"
    end
    local pt = rule.power or CG.powerType
    if pt == nil then return "?" end
    for name, value in pairs(ns.POWER_ALIASES) do
        if value == pt and #name > 2 then return name end
    end
    return tostring(pt)
end

local function GetRule(index)
    local rules = CG:GetRules()
    local n = tonumber(index)
    local rule = n and rules[n]
    if not rule then
        Say(L("no rule #%s (see /cg list)", "нет правила №%s (смотри /cg list)"), tostring(index))
        return nil
    end
    return rule, n
end

-- Index may be a number or "all". Returns how many rules were touched, so the
-- callers can report it and a typo cannot silently edit the wrong rule.
local function EachRule(index, fn)
    local rules = CG:GetRules()
    if index == "all" or index == "*" or index == "все" then
        local n = 0
        for i, r in ipairs(rules) do
            fn(r, i)
            n = n + 1
        end
        if n == 0 then
            Say(L("no rules on this spec", "на этой специализации нет правил"))
        end
        return n
    end
    local rule, i = GetRule(index)
    if not rule then return 0 end
    fn(rule, i)
    return 1
end

local function AddRule(rangeToken, spellToken)
    local minV, maxV, atMax = ParseRange(rangeToken)
    if minV == nil and not atMax then
        Say(L("bad count: %s (use 5, 3-4, =5 or max)",
              "неверное количество: %s (примеры: 5, 3-4, =5, max)"), tostring(rangeToken))
        return
    end

    local spellID
    if type(spellToken) == "number" then
        spellID = spellToken
    else
        local info = ns.SpellInfo(tonumber(spellToken) or spellToken)
        spellID = info and info.spellID
    end
    if not spellID then
        Say(L("unknown spell: %s", "не найдено заклинание: %s"), tostring(spellToken))
        return
    end

    local rule = {
        spell   = spellID,
        min     = minV or 1,
        max     = maxV,
        atMax   = atMax or nil,
        style   = "modern",
        r = 1, g = 0.85, b = 0.1,
        center  = false,
        enabled = true,
    }
    local rules = CG:GetRules()
    rules[#rules + 1] = rule
    CG:Rebuild()
    Say(L("added #%d: %s at %s", "добавлено №%d: %s при %s"),
        #rules, ns.SpellName(spellID), RangeText(rule))
end

-- The states an AURA rule can be in. The resource threshold is a rule of its
-- own kind, not an aura state, so it is not here; the options window's four
-- slots are the user-facing view (see ns.FindSlotRule).
ns.STATES = { "active", "missing", "proc" }

function ns.RuleState(rule)
    if rule.proc then return "proc" end
    if rule.missing then return "missing" end
    return "active"
end

function ns.StateLabel(state)
    if state == "proc" then return L("proc", "прок") end
    if state == "missing" then return L("gone", "нет") end
    return L("up", "висит")
end

-- A proc and a full resource bar are not the same news -- one cast is free,
-- the other is paid for -- so they do not share a look. Gold means "you have
-- the resource"; cyan means "this one is free".
local STATE_DEFAULTS = {
    active  = { style = "pixel",  r = 0, g = 1, b = 0      },
    missing = { style = "fill",   r = 1, g = 0, b = 0      },
    -- Drawn by us, so the colour is ours. Deliberately not "modern": that is
    -- Blizzard's proc artwork, a gold animation that ignores the colour it is
    -- handed -- and gold is what "ready" already means. A proc looking like a
    -- full resource bar defeats the entire point of splitting them.
    -- A cyan wash over the icon, and nothing else. It reads at a glance
    -- without a border to find, and no other state uses this colour.
    proc    = { style = "fill", thick = 3, r = 0.2, g = 0.9, b = 1 },
    -- "ready" is the slot name the options window uses for the resource
    -- threshold (or, for a burst, its cooldown being up).
    ready   = { style = "modern", r = 1, g = 0.85, b = 0.1 },
}

-- Each marker carries the opacity that suits it -- a wash at a frame's full
-- opacity would hide the icon it marks.
local function StyleAlpha(styleKey)
    local entry = ns.StyleByKey(styleKey)
    return entry and entry.defAlpha or 1
end
ns.StyleAlpha = StyleAlpha
ns.STATE_DEFAULTS = STATE_DEFAULTS

function ns.ApplyState(rule, state)
    rule.proc    = (state == "proc") or nil
    rule.missing = (state == "missing") or nil
    local d = STATE_DEFAULTS[state] or STATE_DEFAULTS.active
    rule.style = d.style
    rule.r, rule.g, rule.b = d.r, d.g, d.b
end

-- Aura rule: glow while your buff/debuff from this spell is up (or missing).
local function AddAuraRule(spellToken, helpful, state)
    local spellID
    if type(spellToken) == "number" then
        spellID = spellToken
    else
        local info = ns.SpellInfo(tonumber(spellToken) or spellToken)
        spellID = info and info.spellID
    end
    if not spellID then
        Say(L("unknown spell: %s", "не найдено заклинание: %s"), tostring(spellToken))
        return
    end

    state = state or "active"
    for i, r in ipairs(CG:GetRules()) do
        if r.kind == "aura" and r.spell == spellID and ns.RuleState(r) == state then
            Say(L("rule #%d already covers %s (%s) - /cg del %d to replace it",
                  "правило №%d уже покрывает %s (%s) — /cg del %d чтобы заменить"),
                i, ns.SpellName(spellID), ns.StateLabel(state), i)
            return r, i
        end
    end

    local rule = {
        kind     = "aura",
        spell    = spellID,
        helpful  = helpful or nil,
        unit     = helpful and "player" or "target",
        missing  = false,
        timer    = true,
        -- An aura that is up is a steady state, not a proc, so it gets the
        -- marching border and the animated proc glow stays meaningful.
        style    = STATE_DEFAULTS.active.style,
        swipe    = false,
        alpha    = StyleAlpha(STATE_DEFAULTS.active.style),
        thick    = 3,
        warn     = 4,
        r = 0, g = 1, b = 0,
        wr = 1, wg = 0, wb = 0,
        center  = false,
        enabled = true,
    }
    local rules = CG:GetRules()
    rules[#rules + 1] = rule
    CG:Rebuild()
    Say(L("added #%d: %s (%s)", "добавлено №%d: %s (%s)"),
        #rules, ns.SpellName(spellID), RangeText(rule))
end

-- Used by the options window's "add last cast" button.
function ns.AddAuraRuleFor(spellID, helpful)
    AddAuraRule(spellID, helpful)
end

--[[-------------------------------------------------------------------------
    The four slots of one spell

    "up" and "gone" are aura rules. "ready" is the resource threshold -- or,
    for a burst, its cooldown being up. "proc" is the free cast: the spell lit
    up on its own, no resource spent.

    Ready and proc used to be one slot, which answered "can I press this?" but
    not "what does it cost me?" -- and that is the question worth answering,
    because a procced finisher and a full resource bar ask for different
    decisions. Each slot is a separate rule, so a spell can carry all four with
    a different marker for each, and a slot nobody configures simply does not
    exist and draws nothing.
---------------------------------------------------------------------------]]
function ns.FindSlotRule(spellID, slot)
    for i, r in ipairs(CG:GetRules()) do
        if r.spell == spellID then
            if slot == "ready" then
                if r.kind ~= "aura" then return r, i end
            elseif slot == "proc" then
                if r.kind == "aura" and r.proc then return r, i end
            elseif r.kind == "aura" and not r.proc and ns.RuleState(r) == slot then
                return r, i
            end
        end
    end
end

-- Spells that carry their own "proc" slot. The resource rule for such a spell
-- must stop lighting on procs, or both markers fire at once and the split says
-- nothing. Filled by Rebuild; read by the update loop.
ns.procOwned = {}

-- Does this spell spend the class resource? Decides whether "ready" means a
-- count threshold or just a proc.
local function SpendsResource(spellID)
    local pt = CG.powerType
    if not (pt and C_Spell and C_Spell.GetSpellPowerCost) then return nil end
    local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
    if not ok or type(costs) ~= "table" then return nil end
    for _, c in ipairs(costs) do
        if c.type == pt then return tonumber(c.cost) or 0 end
    end
    return nil
end

--[[-------------------------------------------------------------------------
    "This spell applies that spell's debuff"

    Primal Wrath puts Rip on everything, so its button has no aura of its own
    and had to be pointed at Rip by hand -- which means knowing that in the
    first place. The game already says so: the spell description names the
    other spell. So for a spell the Cooldown Manager does not track as an aura,
    its description is searched for the name of one that IS tracked.

    Exactly one match is taken; two or more is ambiguous and left alone rather
    than guessed at. Matching is on the client's own localised names, so it
    works in any language without a table.
---------------------------------------------------------------------------]]
function ns.GuessAuraSpell(spellID)
    if not (C_Spell and C_Spell.GetSpellDescription) then return nil end
    if ns.cdmAuraFrames and ns.cdmAuraFrames[spellID] then return nil end

    local ok, desc = pcall(C_Spell.GetSpellDescription, spellID)
    if not ok or type(desc) ~= "string" or desc == "" then return nil end

    -- Candidates: what the Cooldown Manager tracks as auras, plus anything
    -- this spec already has an aura rule for.
    local candidates = {}
    for id in pairs(ns.cdmAuraSpells or {}) do candidates[id] = true end
    for _, r in ipairs(CG:GetRules()) do
        if r.kind == "aura" and r.spell then candidates[r.spell] = true end
    end

    local found
    for id in pairs(candidates) do
        if id ~= spellID then
            local name = ns.SpellName(id)
            -- Short names would match half the tooltip by accident.
            if name and #name >= 5 and desc:find(name, 1, true) then
                if found and found ~= id then return nil end
                found = id
            end
        end
    end
    return found
end

--[[-------------------------------------------------------------------------
    "Which buff makes this spell free?"

    The search above, run backwards. Some procs are announced by the game's own
    spell alert, which is plain and reliable -- but plenty are just a buff and
    light nothing. Starweaver's Warp says "your next Starfall costs no Astral
    Power" and never touches the overlay API, so nothing fires and the proc
    state stays dark.

    Which buff belongs to which spell is not something to hardcode: it differs
    per class, per talent build, and changes with patches. The game already
    says it -- the buff's description names the spell -- and that description
    is regenerated by Blizzard every patch, so the answer follows along without
    a table to maintain.

    ALL matches are taken, not one. A spell can have several buffs behind it:
    Starweaver's Warp frees the next Starfall, Starweaver's Haze frees the next
    Starsurge, and Touch the Cosmos frees whichever of the two you press. Two
    matches is not ambiguity, it is the answer.

    Harmful auras are skipped -- a debuff naming the spell is not a proc -- and
    so are short names, which match half a tooltip by chance. Buffs are deduped
    by name: one is registered under its own id, its override and every linked
    id, all naming the same thing.
---------------------------------------------------------------------------]]
function ns.GuessProcAuras(spellID)
    if not (C_Spell and C_Spell.GetSpellDescription) then return nil end
    local name = ns.SpellName(spellID)
    if not name or name:find("^spell:") or #name < 5 then return nil end
    name = name:lower()

    local found, seenName
    for id in pairs(ns.cdmAuraSpells or {}) do
        local nm = id ~= spellID and ns.SpellName(id) or nil
        if nm and not nm:find("^spell:") and not (seenName and seenName[nm]) then
            local harmful = false
            if C_Spell.IsSpellHarmful then
                local okH, v = pcall(C_Spell.IsSpellHarmful, id)
                if okH and v then harmful = true end
            end
            if not harmful then
                local ok, desc = pcall(C_Spell.GetSpellDescription, id)
                if ok and type(desc) == "string" and desc ~= ""
                   and desc:lower():find(name, 1, true) then
                    found = found or {}
                    seenName = seenName or {}
                    seenName[nm] = true
                    found[#found + 1] = id
                end
            end
        end
    end
    -- Sorted so the same set produces the same rule signature every rebuild.
    if found then table.sort(found) end
    return found
end

-- The auras a state watches, as one readable line. auraID is the single-id
-- form rules were created with before the list existed; it still resolves.
function ns.ProcAuraText(rule)
    if not rule then return nil end
    local parts = {}
    if type(rule.auraIDs) == "table" then
        for _, id in ipairs(rule.auraIDs) do parts[#parts + 1] = ns.SpellName(id) end
    end
    if rule.auraID then parts[#parts + 1] = ns.SpellName(rule.auraID) end
    if #parts == 0 then return nil end
    return table.concat(parts, " / ")
end

-- Does any buff this proc state watches name the spell it is on? A state
-- pointed at the wrong one of two near-identical names says nothing, and the
-- window has to be able to tell the user so.
function ns.ProcAurasFit(rule)
    local ids = rule and rule.auraIDs
    if type(ids) ~= "table" or #ids == 0 then return true end
    for _, id in ipairs(ids) do
        if ns.AuraMentions(id, rule.spell) then return true end
    end
    return false
end

-- Does this aura's description name that spell? The picker marks the buff that
-- belongs to the spell being edited: "Starweaver's Warp" and "Starweaver's
-- Haze" are one word apart and make DIFFERENT spells free, so a list of bare
-- names is a coin flip.
function ns.AuraMentions(auraID, spellID)
    if not (C_Spell and C_Spell.GetSpellDescription) then return false end
    local name = ns.SpellName(spellID)
    if not name or name:find("^spell:") or #name < 5 then return false end
    local ok, desc = pcall(C_Spell.GetSpellDescription, auraID)
    if not ok or type(desc) ~= "string" or desc == "" then return false end
    return desc:lower():find(name:lower(), 1, true) ~= nil
end

-- "ready" needs something to be ready FOR. A spell that costs no resource and
-- has no cooldown is always ready, which is not worth a marker -- the options
-- window says so rather than leaving a click that quietly does nothing.
function ns.CanAddSlot(spellID, slot)
    if slot ~= "ready" then return true end
    if SpendsResource(spellID) then return true end
    return (ns.HasRealCooldown and ns.HasRealCooldown(spellID)) and true or false
end

function ns.AddSlotRule(spellID, slot)
    local existing = ns.FindSlotRule(spellID, slot)
    if existing then return existing end

    local rules = CG:GetRules()
    local rule
    local dReady, dProc = ns.STATE_DEFAULTS.ready, ns.STATE_DEFAULTS.proc
    if slot == "proc" then
        -- A spender is answered by its cost: the state lights when the game
        -- says this cast is currently free. Anything else falls back to the
        -- buffs whose description names it, and then to the spell alert.
        local spend = SpendsResource(spellID)
        local costDriven = (spend or 0) > 0
        local buffs = (not costDriven) and ns.GuessProcAuras(spellID) or nil
        rule = {
            kind = "aura", spell = spellID, proc = true,
            baseCost = costDriven and spend or nil,
            auraIDs = buffs,
            unit = "player", helpful = true,
            timer = buffs and true or false,
            style = dProc.style,
            style2 = dProc.style2,
            alpha = StyleAlpha(dProc.style),
            thick = dProc.thick or 3, warn = 4,
            r = dProc.r, g = dProc.g, b = dProc.b,
            wr = 1, wg = 0, wb = 0,
            center = false, enabled = true,
        }
    elseif slot == "ready" then
        local cost = SpendsResource(spellID)
        if cost then
            rule = {
                spell  = spellID,
                min    = (cost >= 2) and cost or 1,
                atMax  = (cost < 2) or nil,
                orProc = true,
                style  = dReady.style,
                alpha  = StyleAlpha(dReady.style),
                r = dReady.r, g = dReady.g, b = dReady.b,
                center = false, enabled = true,
            }
        elseif ns.HasRealCooldown and ns.HasRealCooldown(spellID) then
            -- A burst: "ready" means its cooldown is done.
            rule = {
                kind = "cd", spell = spellID,
                combat = true, orProc = true,
                style = dReady.style,
                alpha = StyleAlpha(dReady.style),
                r = dReady.r, g = dReady.g, b = dReady.b,
                center = false, enabled = true,
            }
        else
            -- Nothing to be ready for: the spell costs no resource and has no
            -- cooldown worth waiting on. "proc" is the slot that fits it.
            return nil
        end
    else
        local d = ns.STATE_DEFAULTS[slot] or ns.STATE_DEFAULTS.active
        rule = {
            kind    = "aura",
            spell   = spellID,
            unit    = "target",
            missing = (slot == "missing") or nil,
            timer   = true,
            style   = d.style,
            swipe   = false,
            auraID  = ns.GuessAuraSpell(spellID),
            alpha   = StyleAlpha(d.style), thick = 3, warn = 4,
            r = d.r, g = d.g, b = d.b,
            wr = 1, wg = 0, wb = 0,
            center = false, enabled = true,
        }
    end
    rules[#rules + 1] = rule
    CG:Rebuild()
    if rule.proc and ns.ProcAuraText(rule) then
        Say(L("%s is free while %s is up (change it in /cg)",
              "«%s» бесплатен, пока висит «%s» (изменить можно в /cg)"),
            ns.SpellName(spellID), ns.ProcAuraText(rule))
    elseif rule.auraID then
        Say(L("%s has no aura of its own - watching %s (change it in /cg)",
              "у «%s» нет своей ауры — слежу за «%s» (изменить можно в /cg)"),
            ns.SpellName(spellID), ns.SpellName(rule.auraID))
    end
    return rule, #rules
end

--[[-------------------------------------------------------------------------
    Preset

    Nothing is hardcoded per class or per patch: the bars are scanned and every
    spell that SPENDS the class resource becomes a rule. A fixed cost (holy
    power, chi, soul shards) becomes "at least that much"; a variable one
    (combo point finishers report a minimum of 1) becomes "at maximum".
---------------------------------------------------------------------------]]
-- quiet: say nothing when the bars turn up empty (the automatic first run
-- retries instead of complaining). intro: printed only once something is
-- actually about to be added. Returns how many rules were created.
local function BuildPreset(quiet, intro)
    -- Read the Cooldown Manager fresh: this runs right after a spec change,
    -- when the viewers have just been rebuilt for the new spec, and the whole
    -- scan depends on that list.
    if ns.RebuildCDMMap then ns.RebuildCDMMap() end
    CG:RefreshSpec()

    -- Rules are filed per specialization; with the id still unknown they would
    -- go somewhere nothing reads back.
    if (CG.specID or 0) == 0 then
        if not quiet then
            Say(L("specialization not known yet - try again in a moment",
                  "специализация ещё не определилась — попробуй через секунду"))
        end
        return 0
    end

    local pt = CG.powerType
    local rules = CG:GetRules()

    -- Tracked per STATE, not per spell: re-scanning should top up a state
    -- that is missing rather than skip a spell that already has one.
    local havePower, haveUp, haveGone, haveBurst, haveProc = {}, {}, {}, {}, {}
    -- What a spell costs when nothing is helping, remembered from the count
    -- rule an earlier scan made. GetSpellPowerCost reports the cost RIGHT NOW,
    -- so scanning while a proc is up reads zero and the spell stops looking
    -- like a spender at all -- which, at a training dummy with procs landing
    -- constantly, is most of the time.
    local knownCost = {}
    for _, r in ipairs(rules) do
        if r.kind == "cd" then
            haveBurst[r.spell] = true
        elseif r.kind ~= "aura" then
            havePower[r.spell] = true
            if (r.min or 0) > 0 and not r.atMax then knownCost[r.spell] = r.min end
        elseif r.proc then
            haveProc[r.spell] = true
        elseif r.missing then
            haveGone[r.spell] = true
        else
            haveUp[r.spell] = true
        end
    end

    local canCost = C_Spell and C_Spell.GetSpellPowerCost

    -- Collect first, so nothing is printed for an empty scan.
    local seen, spenders, procs, auras, bursts = {}, {}, {}, {}, {}
    ns.ForEachActionButton(function(_, spellID)
        if not spellID or seen[spellID] then return end
        seen[spellID] = true
        -- Matched by id and by name: a viewer may track the aura while the bar
        -- holds the spell that applies it.
        local lname = (ns.SpellName(spellID) or ""):lower()

        -- Spends the class resource -> a count rule, and a proc state for the
        -- times it costs nothing. The two are collected separately: a spell
        -- that already has its count rule from an earlier scan still needs its
        -- proc state, and gating both on havePower would skip it forever.
        if pt and canCost and not (havePower[spellID] and haveProc[spellID]) then
            local ok, costs = pcall(canCost, spellID)
            if ok and type(costs) == "table" then
                for _, c in ipairs(costs) do
                    if c.type == pt then
                        -- Zero here usually means a proc is up right now, not
                        -- that the spell is free: prefer what an earlier scan
                        -- recorded when it was not.
                        local cost = tonumber(c.cost) or 0
                        if cost == 0 and (knownCost[spellID] or 0) > 0 then
                            cost = knownCost[spellID]
                        end
                        -- Not for a pool that refills by itself. Runes come
                        -- back on their own, continuously, so "you have two
                        -- runes" is true most of the time -- a Frost death
                        -- knight lit up nearly every button on the bar. Their
                        -- cost is still read for the proc state below, where
                        -- zero means a genuinely free cast (Rime, Killing
                        -- Machine) and that IS a moment.
                        if not havePower[spellID] and not CONTINUOUS_POWER[pt] then
                            spenders[#spenders + 1] = { spell = spellID, cost = cost }
                        end
                        if not haveProc[spellID] then
                            procs[#procs + 1] = { spell = spellID, cost = cost }
                        end
                        break
                    end
                end
            end
        end

        -- In the Essential viewer and does not spend the resource -> a burst,
        -- marked when its cooldown is done. Blizzard's own list of what
        -- matters for the spec, so there is nothing hardcoded here.
        if (ns.cdmEssentialSpells[spellID] or ns.cdmEssentialNames[lname])
           and not havePower[spellID] and not haveBurst[spellID]
           and ns.HasRealCooldown(spellID) then
            local spends = false
            if pt and canCost then
                local ok, costs = pcall(canCost, spellID)
                if ok and type(costs) == "table" then
                    for _, c in ipairs(costs) do
                        if c.type == pt then spends = true break end
                    end
                end
            end
            if not spends then
                bursts[#bursts + 1] = spellID
            end
        end

        -- Tracked as an aura by the Cooldown Manager -> a dot/buff rule.
        if ns.cdmAuraSpells[spellID] or ns.cdmAuraNames[lname] then
            local harmful = true
            if C_Spell and C_Spell.IsSpellHarmful then
                local ok, v = pcall(C_Spell.IsSpellHarmful, spellID)
                if ok and v ~= nil then harmful = v and true or false end
            end
            if not haveUp[spellID] then
                auras[#auras + 1] = { spell = spellID, harmful = harmful, slot = "active" }
            end
            -- Everything tracked gets a "gone" state, buffs included. It used
            -- to be debuffs only, on the grounds that a personal cooldown is
            -- missing most of the time and nagging about it is noise -- but
            -- that is an argument about the reminder STRIP, not about the
            -- button, and it was costing people the state entirely. The strip
            -- still takes only the harmful ones by itself (see ns.AutoStrip);
            -- a buff joins it if you tick the box.
            if not haveGone[spellID] then
                auras[#auras + 1] = { spell = spellID, harmful = harmful, slot = "missing" }
            end
        end
    end)

    -- Proc states that already exist are re-checked. Planned here, applied
    -- below, so a scan that finds nothing else still counts this as work.
    local heals = {}
    for _, r in ipairs(rules) do
      if r.kind == "aura" and r.proc and r.spell then
        -- A spender is answered by its cost, exactly and in any language: the
        -- state lights when the game says this cast is currently free. Buffs
        -- are not consulted at all, and any that an earlier scan guessed are
        -- dropped -- a description says which spells a buff is ABOUT, not
        -- which it makes free, and half the Balance tree names Starsurge.
        local spend = SpendsResource(r.spell)
        if not (spend and spend > 0) then spend = knownCost[r.spell] end
        if not (spend and spend > 0) then spend = r.baseCost end
        -- A proc drawn with Blizzard's gold artwork is the same mark as
        -- "ready", whatever colour is stored. Fixed here as well as in the
        -- database migration, so a scan repairs it whenever it is noticed.
        local st = ns.StyleByKey(r.style)
        local goldStyle = st and st.fixedColor and true or false
        if spend and spend > 0 then
            if (r.baseCost or 0) < spend or r.auraIDs or goldStyle then
                heals[#heals + 1] = { rule = r, cost = spend, restyle = goldStyle }
            end
        else
            -- What the descriptions say right now, plus anything picked by
            -- hand that is still tracked. Ids nothing tracks any more are
            -- dropped. Talents move this list around within a single patch --
            -- Touch the Cosmos frees both Starsurge and Starfall and simply
            -- was not there before it was taken -- so a rescan tops the state
            -- up rather than only filling an empty one.
            local want, seen = {}, {}
            local fresh = ns.GuessProcAuras(r.spell)
            if fresh then
                for _, id in ipairs(fresh) do
                    if not seen[id] then
                        seen[id] = true
                        want[#want + 1] = id
                    end
                end
            end
            if type(r.auraIDs) == "table" then
                for _, id in ipairs(r.auraIDs) do
                    if ns.cdmAuraSpells[id] and not seen[id] then
                        seen[id] = true
                        want[#want + 1] = id
                    end
                end
            end
            table.sort(want)
            -- Compared by name: one buff is registered under several ids, and
            -- swapping which of them is stored is not a change worth reporting.
            local before = ns.ProcAuraText(r) or ""
            local after  = ns.ProcAuraText({ auraIDs = want }) or ""
            if before ~= after then
                heals[#heals + 1] = { rule = r, ids = (#want > 0) and want or false }
            end
        end
      end
    end

    local total = #spenders + #procs + #auras + #bursts + #heals
    if total == 0 then
        if not quiet then
            Say(L("nothing to set up from your bars - use /cg add or /cg dot",
                  "по панелям нечего настроить — используй /cg add или /cg dot"))
            -- Say what there was to work with. "Nothing found" and "nothing to
            -- look at" are different problems and read the same.
            local nAura = 0
            for _ in pairs(ns.cdmAuraSpells or {}) do nAura = nAura + 1 end
            Say(L("(%d buttons scanned, %d auras tracked in the Cooldown Manager)",
                  "(кнопок просканировано: %d, аур в Cooldown Manager: %d)"),
                ns.scannedButtons or 0, nAura)
        end
        return 0
    end

    if intro then Say(intro) end

    for _, entry in ipairs(spenders) do
        local d = STATE_DEFAULTS.ready
        local rule = {
            spell   = entry.spell,
            min     = (entry.cost >= 2) and entry.cost or 1,
            atMax   = (entry.cost < 2) or nil,
            style   = d.style,
            r = d.r, g = d.g, b = d.b,
            center  = false,
            enabled = true,
        }
        rules[#rules + 1] = rule
        Say(L("+ %s at %s", "+ %s при %s"), ns.SpellName(entry.spell), RangeText(rule))
    end

    -- The same spells, free. A spender that procs costs nothing this once, and
    -- that is a different decision from having saved up for it: its own rule,
    -- its own marker. Its own pass too, so a spell whose count rule already
    -- exists from an earlier scan still gets this state. A spender that never
    -- procs simply keeps a state that never lights.
    for _, entry in ipairs(procs) do
        local p = STATE_DEFAULTS.proc
        -- baseCost is the whole mechanism for a spender: the state lights when
        -- the game says this cast currently costs nothing. No buff to name, so
        -- no buff is attached -- descriptions say which spells a buff is ABOUT,
        -- not which it makes free, and half the Balance tree mentions Starsurge.
        rules[#rules + 1] = {
            kind     = "aura",
            spell    = entry.spell,
            proc     = true,
            baseCost = entry.cost,
            unit     = "player",
            helpful  = true,
            timer    = false,
            style    = p.style,
            style2   = p.style2,
            alpha    = StyleAlpha(p.style),
            thick    = p.thick or 3, warn = 4,
            r = p.r, g = p.g, b = p.b,
            wr = 1, wg = 0, wb = 0,
            center   = false,
            enabled  = true,
        }
        Say(L("+ %s when it costs nothing", "+ «%s», когда бесплатен"),
            ns.SpellName(entry.spell))
    end

    -- The re-check planned above, applied.
    for _, h in ipairs(heals) do
        if h.cost then
            h.rule.baseCost = h.cost
            h.rule.auraIDs, h.rule.timer = nil, false
            if h.restyle then
                local p = STATE_DEFAULTS.proc
                h.rule.style = p.style
                h.rule.style2 = p.style2
                h.rule.thick = p.thick or 3
                h.rule.alpha = StyleAlpha(p.style)
                h.rule.r, h.rule.g, h.rule.b = p.r, p.g, p.b
                Say(L("~ %s: proc marker was gold, same as ready - recoloured",
                      "~ «%s»: отметка прока была золотой, как «готово» — перекрасил"),
                    ns.SpellName(h.rule.spell))
            end
            Say(L("~ %s now lights when it costs nothing",
                  "~ «%s» теперь горит, когда бесплатен"),
                ns.SpellName(h.rule.spell))
        elseif h.ids then
            h.rule.auraIDs, h.rule.timer = h.ids, true
            Say(L("~ %s is free while %s is up",
                  "~ «%s» бесплатен, пока висит «%s»"),
                ns.SpellName(h.rule.spell), ns.ProcAuraText(h.rule))
        else
            h.rule.auraIDs, h.rule.timer = nil, false
            Say(L("~ %s: its proc buff is gone - back to the spell alert",
                  "~ «%s»: бафф прока пропал — возврат к штатной подсветке"),
                ns.SpellName(h.rule.spell))
        end
    end

    for _, entry in ipairs(auras) do
        local d = STATE_DEFAULTS[entry.slot] or STATE_DEFAULTS.active
        local rule = {
            kind     = "aura",
            spell    = entry.spell,
            helpful  = (not entry.harmful) or nil,
            unit     = entry.harmful and "target" or "player",
            missing  = (entry.slot == "missing") or false,
            timer    = true,
            style    = d.style,
            swipe    = false,
            alpha    = StyleAlpha(d.style),
            thick    = 3,
            warn     = 4,
            r = d.r, g = d.g, b = d.b,
            wr = 1, wg = 0, wb = 0,
            center  = false,
            enabled = true,
        }
        rules[#rules + 1] = rule
        Say(L("+ %s (%s)", "+ %s (%s)"), ns.SpellName(entry.spell), RangeText(rule))
    end

    for _, spellID in ipairs(bursts) do
        local rule = {
            kind    = "cd",
            spell   = spellID,
            combat  = true,
            orProc  = true,
            style   = "modern",
            r = 1, g = 0.85, b = 0.1,
            center  = false,
            enabled = true,
        }
        rules[#rules + 1] = rule
        Say(L("+ %s (%s)", "+ %s (%s)"),
            ns.SpellName(spellID), L("burst ready", "бурст готов"))
    end

    CG:Rebuild()
    local added = #spenders + #procs + #auras + #bursts + #heals
    Say(L("%d rules added. /cg list to review, /cg del <#> to drop one.",
          "добавлено правил: %d. /cg list — посмотреть, /cg del <№> — удалить."), added)
    return added
end
ns.BuildPreset = BuildPreset

--[[-------------------------------------------------------------------------
    Commands
---------------------------------------------------------------------------]]
local function PrintHelp()
    Say(L("commands:", "команды:"))
    local lines = {
        { "/cg preset",                L("scan your bars and add a rule for every resource spender", "просканировать панели и создать правило на каждый расходник ресурса") },
        { "/cg clear",                 L("remove every rule of this spec", "удалить все правила этой специализации") },
        { "/cg list",                  L("list the rules of the current spec", "список правил текущей специализации") },
        { "/cg add <n> <spell>",       L("add: n = 5 | 3-4 | =5 | max", "добавить: n = 5 | 3-4 | =5 | max") },
        { "/cg last <n>",              L("add a rule for the spell you cast last", "добавить правило для последнего применённого заклинания") },
        { "/cg dot [spell]",           L("glow while YOUR debuff from that spell is on the target (+timer)", "светиться пока ТВОЙ дебафф от этого заклинания висит на цели (+таймер)") },
        { "/cg buff [spell]",          L("same for your own buff on yourself", "то же для своего баффа на себе") },
        { "/cg missing <#>",           L("flip it: glow while the aura is GONE", "перевернуть: светиться когда ауры НЕТ") },
        { "/cg unit <#> <unit>",       L("player | target | focus | mouseover | pet", "player | target | focus | mouseover | pet") },
        { "/cg aura <#> <name|id>",    L("look for a different aura than the spell itself", "искать другую ауру, а не само заклинание") },
        { "/cg count <#|all> <n>",     L("resource level a count rule lights at", "уровень ресурса, при котором загорается правило") },
        { "/cg warn <#> <sec>",        L("turn red this many seconds before it runs out (0 = never)", "краснеть за столько секунд до конца (0 = никогда)") },
        { "/cg alpha <#> <0-100>",     L("brightness of the marker", "яркость метки") },
        { "/cg thick <#> <1-10>",      L("frame thickness in pixels", "толщина рамки в пикселях") },
        { "/cg timer <#> on|off",      L("time left on the icon", "остаток времени на иконке") },
        { "/cg swipe <#> on|off",      L("also draw a cooldown sweep for the remaining time", "рисовать ещё и развёртку кулдауна по остатку времени") },
        { "/cg poll <ms>",             L("how often aura state is re-read (0 = events only)", "как часто перечитывать ауры (0 = только по событиям)") },
        { "/cg mirror on|off",         L("fallback: take aura state from the Cooldown Manager", "запасной путь: брать состояние ауры у Cooldown Manager") },
        { "/cg blizzglow on|off",      L("the game's own gold proc glow (off by default)", "штатное золотое свечение прока (по умолчанию выключено)") },
        { "/cg procstrip on|off",      L("show procs in the reminder strip (on by default)", "показывать проки в полосе напоминаний (по умолчанию вкл)") },
        { "/cg hidecdm on|off",        L("hide the Cooldown Manager without stopping it", "скрыть Cooldown Manager, не выключая его") },
        { "/cg minimap on|off",        L("the minimap button", "кнопка у миникарты") },
        { "/cg pack on|off",           L("close gaps in the reminder strip", "закрывать дырки в полосе напоминаний") },
        { "/cg rows on|off",           L("one strip row per kind, procs on top", "полоса строками по типу, проки сверху") },
        { "/cg soon <#> <sec|off>",    L("warn on the strip with this long left on that state", "предупреждать на полосе за столько секунд, для состояния") },
        { "/cg stackpos <where>",      L("where the stack count sits on the marker", "где на отметке стоит счётчик стаков") },
        { "/cg stacksize <50-200>",    L("stack count size, in percent", "размер счётчика стаков, в процентах") },
        { "/cg auracheck",             L("report what the aura API answers here, with measured lag", "показать ответ aura API и замеренную задержку") },
        { "/cg procs",                 L("what each proc state watches, and whether it is lit", "за чем следит каждое прок-состояние и горит ли оно") },
        { "/cg why",                   L("what OURS is lit right now, and which rule did it", "что горит именно у нас прямо сейчас и от какого правила") },
        { "/cg del <#>",               L("remove rule", "удалить правило") },
        { "/cg toggle <#>",            L("enable / disable rule", "включить / выключить правило") },
        { "/cg style <#> <name>",      L("glow style (see /cg styles)", "стиль подсветки (список: /cg styles)") },
        { "/cg color <#> r g b",       L("colour, 0-255", "цвет, 0-255") },
        { "/cg center <#>",            L("also show it in the middle of the screen", "показывать иконку в центре экрана") },
        { "/cg power <#> <name>",      L("resource: auto, combo, holy, chi, shards, arcane, essence, ...", "ресурс: auto, combo, holy, chi, shards, arcane, essence, ...") },
        { "/cg move",                  L("unlock / lock the centre anchor", "разблокировать / заблокировать якорь в центре") },
        { "/cg size <px>",             L("size of the reminder icons", "размер иконок в полосе напоминаний") },
        { "/cg test",                  L("show everything for 6 seconds", "показать всё на 6 секунд") },
        { "/cg on | off",              L("enable / disable the addon", "включить / выключить аддон") },
        { "/cg combat on|off",         L("only glow while in combat", "подсвечивать только в бою") },
        { "/cg cdm on|off",            L("also glow Cooldown Manager icons", "подсвечивать также иконки Cooldown Manager") },
        { "/cg secret on|off",         L("keep working in restricted instances", "работать в инстансах с закрытыми значениями") },
    }
    for _, l in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%s|r  %s"):format(Localize(l[1]), l[2]))
    end
end

local function PrintStyles()
    local haveEUI = ns.EUIGlows() ~= nil
    Say(L("styles:", "стили:") .. (haveEUI and "" or L(" (EllesmereUI not loaded - only 2 looks available)",
                                                        " (EllesmereUI не загружен — доступно 2 вида)")))
    for _, s in ipairs(ns.STYLES) do
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%s|r  %s"):format(s.key, s.label))
    end
end

local function PrintList()
    local rules = CG:GetRules()

    -- What the scan had to work with, printed BEFORE the "no rules" exit. An
    -- empty Cooldown Manager is the usual reason a spec comes up with nothing,
    -- and this used to be reported only when there was already something to
    -- report -- silent in the one case it was written for.
    local nAura, nEss = 0, 0
    for _ in pairs(ns.cdmAuraSpells or {}) do nAura = nAura + 1 end
    for _ in pairs(ns.cdmEssentialSpells or {}) do nEss = nEss + 1 end
    Say(L("rules (spec %d, %d buttons scanned):", "правила (спек %d, кнопок просканировано: %d):"),
        CG.specID or 0, ns.scannedButtons or 0)
    Say(L("  Cooldown Manager: %d tracked auras, %d essential cooldowns",
          "  Cooldown Manager: аур отслеживается %d, бурстов %d"), nAura, nEss)
    if nAura == 0 then
        Say(L("  |cffff4040no tracked auras for this spec|r - nothing can see a dot here",
              "  |cffff4040отслеживаемых аур нет|r — доты здесь увидеть нечем"))
        Say(L("  add them under Options - Cooldown Manager, then /cg preset",
              "  добавь их в Настройки — Cooldown Manager, потом /cg preset"))
    end

    if #rules == 0 then
        Say(L("no rules for this spec yet. Example: /cg add max Eviscerate",
              "для этой специализации правил нет. Пример: /cg add max Потрошение"))
        return
    end
    for i, rule in ipairs(rules) do
        local flags = {}
        if rule.enabled == false then flags[#flags + 1] = L("off", "выкл") end
        if rule.center then flags[#flags + 1] = L("centre", "центр") end
        if rule.kind == "aura" then
            local mf, isAuraEntry = ns.FindMirror(rule)
            if ns.ReadsWork(rule) then
                flags[#flags + 1] = L("api", "api")
            elseif mf and isAuraEntry then
                flags[#flags + 1] = "|cff0cd29f" .. L("cdm", "cdm") .. "|r"
            else
                flags[#flags + 1] = "|cffff4040" .. L("NO SOURCE", "НЕТ ИСТОЧНИКА") .. "|r"
            end
        end
        local n = ns.buttonCount[rule] or 0
        if n == 0 then
            flags[#flags + 1] = "|cffff4040" .. L("NO BUTTON", "КНОПКА НЕ НАЙДЕНА") .. "|r"
        else
            flags[#flags + 1] = L("%d btn", "кнопок: %d"):format(n)
        end
        local tail = #flags > 0 and (" |cff888888[" .. table.concat(flags, ", ") .. "]|r") or ""
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%d.|r %s  |cff0cd29f%s|r  %s  %s%s"):format(
            i, ns.SpellName(rule.spell), RangeText(rule), PowerText(rule),
            rule.style or "modern", tail))
    end
end

local function OnOff(word, current)
    if word == "on" or word == "1" or word == "вкл" then return true end
    if word == "off" or word == "0" or word == "выкл" then return false end
    return not current
end

local function Handler(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if not CG.initialized then
        Say(L("still loading, try again in a second", "ещё загружается, попробуй через секунду"))
        return
    end

    if cmd == "" or cmd == "config" or cmd == "options" then
        if ns.ToggleOptions then
            ns.ToggleOptions()
        else
            PrintHelp()
        end

    elseif cmd == "help" then
        PrintHelp()

    elseif cmd == "list" then
        PrintList()

    elseif cmd == "styles" then
        PrintStyles()

    elseif cmd == "preset" then
        BuildPreset()

    elseif cmd == "clear" then
        local rules = CG:GetRules()
        local n = #rules
        for i = n, 1, -1 do rules[i] = nil end
        CG:Rebuild()
        Say(L("%d rules removed from this spec", "удалено правил на этой специализации: %d"), n)

    elseif cmd == "add" then
        local range, spell = rest:match("^(%S+)%s+(.+)$")
        if not range then
            Say(L("usage: /cg add <n> <spell name or id>", "формат: /cg add <кол-во> <название или ID>"))
        else
            AddRule(range, spell)
        end

    elseif cmd == "last" then
        if not CG.lastCast then
            Say(L("cast something first, then run /cg last <n>",
                  "сначала примени способность, потом введи /cg last <кол-во>"))
        else
            AddRule(rest ~= "" and rest or "max", CG.lastCast)
        end

    elseif cmd == "dot" or cmd == "debuff" then
        if rest == "" then
            if CG.lastCast then AddAuraRule(CG.lastCast, false)
            else Say(L("usage: /cg dot <spell>  (or cast it first)",
                       "формат: /cg dot <заклинание>  (или сначала примени его)")) end
        else
            AddAuraRule(rest, false)
        end

    elseif cmd == "buff" then
        if rest == "" then
            if CG.lastCast then AddAuraRule(CG.lastCast, true)
            else Say(L("usage: /cg buff <spell>  (or cast it first)",
                       "формат: /cg buff <заклинание>  (или сначала примени его)")) end
        else
            AddAuraRule(rest, true)
        end

    elseif cmd == "aura" then
        local idx, token = rest:match("^(%S+)%s+(.+)$")
        local rule = idx and GetRule(idx)
        if rule then
            local n = tonumber(token)
            if n then
                rule.auraID, rule.auraName = n, nil
            else
                rule.auraID, rule.auraName = nil, token
            end
            CG:Rebuild()
            Say(L("aura to look for: %s", "отслеживаемая аура: %s"), tostring(rule.auraID or rule.auraName))
        elseif not idx then
            Say(L("usage: /cg aura <#> <aura name or spellID>", "формат: /cg aura <№> <имя ауры или spellID>"))
        end

    elseif cmd == "unit" then
        local idx, token = rest:match("^(%S+)%s+(%S+)$")
        local rule = idx and GetRule(idx)
        if rule then
            token = token:lower()
            if not ns.AURA_UNITS[token] then
                Say(L("unit must be one of: player, target, focus, mouseover, pet",
                      "юнит: player, target, focus, mouseover, pet"))
            else
                rule.unit = token
                CG:UpdateAuras()
                Say("unit: %s", token)
            end
        elseif not idx then
            Say(L("usage: /cg unit <#> <player|target|focus|mouseover|pet>",
                  "формат: /cg unit <№> <player|target|focus|mouseover|pet>"))
        end

    elseif cmd == "swipe" then
        local idx, word = rest:match("^(%S+)%s*(%S*)$")
        local rule = idx and GetRule(idx)
        if rule then
            rule.swipe = OnOff(word:lower(), rule.swipe)
            CG:UpdateAuras()
            Say(L("cooldown sweep: %s", "развёртка кулдауна: %s"),
                rule.swipe and L("on", "вкл") or L("off", "выкл"))
        elseif not idx then
            Say(L("usage: /cg swipe <#> on|off", "формат: /cg swipe <№> on|off"))
        end

    elseif cmd == "missing" then
        local rule = GetRule(rest)
        if rule then
            rule.missing = not rule.missing
            -- Follow the convention the look comes from: green means "yours is
            -- up", red means "it is gone". Only swaps the two defaults, so a
            -- colour picked by hand is left alone.
            if rule.missing and rule.r == 0 and rule.g == 1 and rule.b == 0 then
                rule.r, rule.g, rule.b = 1, 0, 0
            elseif not rule.missing and rule.r == 1 and rule.g == 0 and rule.b == 0 then
                rule.r, rule.g, rule.b = 0, 1, 0
            end
            CG:Rebuild()
            Say(L("glow when missing: %s", "светиться когда НЕТ ауры: %s"),
                rule.missing and L("on", "вкл") or L("off", "выкл"))
        end

    elseif cmd == "warn" or cmd == "pandemic" then
        local idx, sec = rest:match("^(%S+)%s+(%d+)$")
        local rule = idx and GetRule(idx)
        if rule then
            rule.warn = tonumber(sec)
            CG:Rebuild()
            Say(L("turns red with %ds left (0 = never)", "краснеет за %d сек до конца (0 = никогда)"),
                rule.warn)
        elseif not idx then
            Say(L("usage: /cg warn <#> <seconds>", "формат: /cg warn <№> <секунд>"))
        end

    elseif cmd == "count" or cmd == "at" then
        local idx, value = rest:match("^(%S+)%s+(%S+)$")
        if not idx then
            Say(L("usage: /cg count <#|all> <n | n-n | =n | max>",
                  "формат: /cg count <№|all> <n | n-n | =n | max>"))
        else
            local minV, maxV, atMax = ParseRange(value)
            if minV == nil and not atMax then
                Say(L("bad count: %s", "неверное количество: %s"), value)
            else
                local n = EachRule(idx, function(r)
                    if r.kind == "aura" or r.kind == "cd" then return end
                    r.min, r.max, r.atMax = minV or 1, maxV, atMax or nil
                end)
                if n > 0 then
                    CG:Rebuild()
                    Say(L("threshold set on %d rules", "порог задан для правил: %d"), n)
                end
            end
        end

    elseif cmd == "alpha" then
        local idx, pct = rest:match("^(%S+)%s+(%d+)$")
        if not idx then
            Say(L("usage: /cg alpha <#|all> <0-100>", "формат: /cg alpha <№|all> <0-100>"))
        else
            local v = math.min(100, tonumber(pct)) / 100
            local n = EachRule(idx, function(r) r.alpha = v end)
            if n > 0 then
                CG:Rebuild()
                Say(L("brightness %d%% on %d rules", "яркость %d%% для правил: %d"), tonumber(pct), n)
            end
        end

    elseif cmd == "thick" then
        local idx, px = rest:match("^(%S+)%s+(%d+)$")
        if not idx then
            Say(L("usage: /cg thick <#|all> <1-10>", "формат: /cg thick <№|all> <1-10>"))
        else
            local v = math.max(1, math.min(10, tonumber(px)))
            local n = EachRule(idx, function(r) r.thick = v end)
            if n > 0 then
                CG:Rebuild()
                Say(L("thickness %d px on %d rules", "толщина %d px для правил: %d"), v, n)
            end
        end

    elseif cmd == "timer" then
        local idx, word = rest:match("^(%S+)%s*(%S*)$")
        local rule = idx and GetRule(idx)
        if rule then
            rule.timer = OnOff(word:lower(), rule.timer ~= false)
            CG:UpdateAuras()
            Say(L("timer: %s", "таймер: %s"), rule.timer and L("on", "вкл") or L("off", "выкл"))
        end

    elseif cmd == "auracheck" then
        ns.AuraCheck(CG:GetRules(), Say)

    elseif cmd == "soontest" then
        -- Run OUT OF COMBAT: it checks the duration object against a
        -- remaining time that can still be read.
        ns.RebuildCDMMap()
        ns.SoonTest(CG:GetRules(), Say)

    elseif cmd == "mkdur" then
        -- What the duration factory wants, asked rather than guessed. The
        -- plain-number control separates a wrong signature from a rejected
        -- secret; they look identical from a distance.
        ns.RebuildCDMMap()
        local target
        for _, r in ipairs(CG:GetRules()) do
            if r.kind == "aura" and not r.proc then
                local mf, isAura = ns.FindMirror(r)
                if mf and isAura and ns.CaughtArgs(mf) then target = mf break end
            end
        end
        ns.DurationFactory(Say, target)

    elseif cmd == "cdapi" then
        -- The whole Cooldown widget API. If an engine-side answer about a
        -- secret remaining time exists, its name is in this list.
        ns.CooldownAPI(Say)

    elseif cmd == "probe" then
        -- The early-gone question, and only that. It has to be asked IN
        -- COMBAT, where the full report scrolls off before it can be read.
        ns.SoonProbe(CG:GetRules(), Say)

    elseif cmd == "stacks" then
        -- Where a stack count could come from, per aura rule: what our own
        -- read answers, and what the Cooldown Manager's frame actually holds.
        ns.RebuildCDMMap()
        for i, r in ipairs(CG:GetRules()) do
            if r.kind == "aura" and not r.missing and not r.proc then
                local _, _, _, _, apps = ns.QueryAura(r)
                local mf, isAuraEntry = ns.FindMirror(r)
                Say("#%d %s | applications=%s | mirror=%s", i, ns.SpellName(r.spell),
                    tostring(apps),
                    mf and (isAuraEntry and L("aura entry", "запись ауры")
                                        or L("cooldown entry", "запись кулдауна"))
                       or L("none", "нет"))
                if mf then ns.DumpFontStrings(mf, Say, "     ") end
                -- And what OUR side makes of it: the three links that have to
                -- hold for a number to appear.
                for _, f in ipairs(CG.auraFrames or {}) do
                    if f.rule == r then
                        Say("     our frame: StackText=%s shown=%s | picked=%s | stacks=%s",
                            tostring(f.StackText ~= nil),
                            f.StackText and tostring(f.StackText:IsShown()) or "-",
                            tostring(mf ~= nil and ns.FindStackFS(mf) ~= nil),
                            tostring(r.stacks))
                        break
                    end
                end
            end
        end

    elseif cmd == "secretapi" then
        -- Which widget methods take a secret value. SetAlphaFromBoolean is the
        -- one this addon already leans on; if there is a shown- or size-from-
        -- boolean beside it, the reminder strip can close its gaps instead of
        -- reserving a slot for a state only the engine can see.
        local probe = CreateFrame("Frame", nil, UIParent)
        local function Scan(obj, label)
            local mt = getmetatable(obj)
            local idx = mt and mt.__index
            if type(idx) ~= "table" then
                Say("%s: %s", label, L("no method table", "таблицы методов нет"))
                return
            end
            local names = {}
            for k, v in pairs(idx) do
                if type(v) == "function"
                   and (k:find("Boolean") or k:find("Secret")) then
                    names[#names + 1] = k
                end
            end
            table.sort(names)
            Say("%s: %d", label, #names)
            for _, k in ipairs(names) do Say("  " .. k) end
        end
        Scan(probe, "Frame")
        Scan(probe:CreateTexture(nil, "ARTWORK"), "Texture")
        Scan(probe:CreateFontString(nil, "OVERLAY"), "FontString")

    elseif cmd == "cdmdump" then
        -- Every category the Cooldown Manager knows and what is in it. We read
        -- four viewer frames; if a spell is tracked in a category none of them
        -- shows, that is a gap on our side rather than a missing setting -- and
        -- this is the only way to tell the two apart.
        if type(C_CooldownViewer) ~= "table"
           or not C_CooldownViewer.GetCooldownViewerCategorySet then
            Say(L("no category API on this client", "API категорий на этом клиенте нет"))
        else
            local cats = Enum and Enum.CooldownViewerCategory
            if type(cats) ~= "table" then
                Say(L("Enum.CooldownViewerCategory is missing",
                      "Enum.CooldownViewerCategory отсутствует"))
            else
                for name, value in pairs(cats) do
                    local ok, set = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, value)
                    local n = (ok and type(set) == "table") and #set or -1
                    Say("%s (%s): %s", tostring(name), tostring(value),
                        n < 0 and L("error", "ошибка") or tostring(n))
                    if ok and type(set) == "table" then
                        for _, cdID in ipairs(set) do
                            local ok2, info =
                                pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                            if ok2 and type(info) == "table" and info.spellID then
                                Say("    %s", ns.SpellName(info.spellID))
                            end
                        end
                    end
                end
            end
        end

    elseif cmd == "cdmapi" then
        -- Everything the client exposes on C_CooldownViewer, so "can the addon
        -- add spells to the Cooldown Manager itself" is answered by looking
        -- rather than by guessing. A setter would show up here; if only
        -- getters exist, that list is Blizzard's to edit and ours to read.
        if type(C_CooldownViewer) ~= "table" then
            Say(L("C_CooldownViewer is not present on this client",
                  "C_CooldownViewer на этом клиенте нет"))
        else
            local names = {}
            for k, v in pairs(C_CooldownViewer) do
                if type(v) == "function" then names[#names + 1] = k end
            end
            table.sort(names)
            Say(L("C_CooldownViewer: %d functions", "C_CooldownViewer: функций %d"), #names)
            for _, k in ipairs(names) do Say("  " .. k) end
        end

    elseif cmd == "why" then
        -- Everything of OURS that is lit this instant, and which rule is
        -- doing it. A gold button with nothing listed here is somebody
        -- else's glow -- the game's, or the action bar's own.
        local idx = {}
        for i, r in ipairs(CG:GetRules()) do idx[r] = i end
        local function StateWord(r)
            if r.kind == "cd" then return L("burst ready", "бурст готов") end
            if r.kind ~= "aura" then
                return L("resource", "ресурс") .. " " .. RangeText(r)
            end
            if r.proc then return L("proc", "прок") end
            if r.missing then return L("gone", "нет") end
            return L("up", "висит")
        end
        -- Printed FIRST: it is the line that separates "the state never goes
        -- true" from "the rule was never given a slot", and those need
        -- completely different fixes.
        local strip = {}
        for ic in CG.centerPool:EnumerateActive() do
            local r = ic.rule
            if r then
                strip[#strip + 1] = ("%s (%s)"):format(ns.SpellName(r.spell), StateWord(r))
            end
        end
        if #strip > 0 then
            Say(L("strip slots: %s", "места на полосе: %s"), table.concat(strip, ", "))
        else
            Say(L("strip: no slots at all", "полоса: мест нет вообще"))
        end

        local n = 0
        local function report(frame)
            local r = frame.rule
            if not r or not frame:IsShown() then return end
            n = n + 1
            local what = StateWord(r)
            Say("%s #%s %s | %s | %s | rgb %.1f %.1f %.1f",
                frame.isStrip and L("strip", "полоска") or L("bar", "панель"),
                tostring(idx[r] or "?"), ns.SpellName(r.spell), what,
                tostring(r.style) .. (r.style2 and ("+" .. r.style2) or ""),
                r.r or 1, r.g or 1, r.b or 1)
        end
        for _, f in ipairs(CG.powerFrames or {}) do report(f) end
        for _, f in ipairs(CG.auraFrames or {}) do report(f) end
        if n == 0 then
            Say(L("nothing of ours is lit - any glow you see is not this addon",
                  "у нас сейчас не горит ничего — то, что видно, рисует не этот аддон"))
        end

    elseif cmd == "procs" then
        -- What each proc state is actually watching, and whether it reads.
        -- "spell alert" means no buff was matched, so it depends on
        -- IsSpellOverlayed -- which plenty of procs never touch.
        ns.RebuildCDMMap()
        local n = 0
        for i, r in ipairs(CG:GetRules()) do
            if r.kind == "aura" and r.proc then
                n = n + 1
                local src
                if (r.baseCost or 0) > 0 and not r.auraIDs then
                    src = ("%s (%s %d)"):format(
                        L("costs nothing", "ничего не стоит"),
                        L("normally", "обычно"), r.baseCost)
                else
                    src = ns.ProcAuraText(r) or L("spell alert", "штатная подсветка")
                end
                local lit = ns.procActive[r.spell] and L("YES", "ДА")
                                                   or L("no / unknown", "нет / неизвестно")
                Say("#%d %s -> %s | %s: %s", i, ns.SpellName(r.spell), src,
                    L("lit now", "горит сейчас"), lit)
                -- The raw fields, not my reading of them. Guessing from a
                -- formatted line is how two of these bugs stayed hidden.
                local live = "?"
                if ns.CostsNothing then
                    local v = ns.CostsNothing(r)
                    live = (v == nil) and "?" or (v and L("free", "бесплатен")
                                                    or L("costs", "стоит"))
                end
                Say("   style=%s  baseCost=%s  auraIDs=%d  timer=%s  cost=%s",
                    tostring(r.style), tostring(r.baseCost),
                    type(r.auraIDs) == "table" and #r.auraIDs or 0,
                    tostring(r.timer), live)
                -- Advice only where there is a choice to get wrong. A cost-
                -- driven state has none: the game answers it outright.
                if not ((r.baseCost or 0) > 0 and not r.auraIDs) then
                    if not ns.ProcAurasFit(r) then
                        Say(L("   WARNING: none of those buffs names this spell",
                              "   ВНИМАНИЕ: ни один из этих баффов не называет это заклинание"))
                    end
                    local fresh = ns.GuessProcAuras(r.spell)
                    if fresh then
                        local now = ns.ProcAuraText(r)
                        local want = ns.ProcAuraText({ auraIDs = fresh })
                        if now ~= want then
                            Say(L("   naming it: %s (a mention is not a promise)",
                                  "   упоминают его: %s (упоминание — ещё не обещание)"), want)
                        end
                    else
                        Say(L("   no tracked buff names this spell",
                              "   ни один отслеживаемый бафф не называет это заклинание"))
                    end
                end
            end
        end
        if n == 0 then
            Say(L("no proc states configured - /cg preset adds them",
                  "прок-состояний нет — /cg preset их создаст"))
        end

    elseif cmd == "cdtest" then
        -- Decides in one look whether the sweep problem is the widget or the
        -- data: a bare Cooldown in the middle of the screen, fed plain numbers.
        if not ns.cdTest then
            local f = CreateFrame("Frame", nil, UIParent)
            f:SetSize(64, 64)
            f:SetPoint("CENTER", 0, 120)
            f:SetFrameStrata("FULLSCREEN_DIALOG")
            local icon = f:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(f)
            icon:SetTexture(ns.SpellIcon(CG.lastCast or 1))
            local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
            cd:SetAllPoints(f)
            if cd.SetDrawSwipe then cd:SetDrawSwipe(true) end
            cd:SetDrawEdge(true)
            cd:SetHideCountdownNumbers(false)
            f.cd = cd
            ns.cdTest = f
        end
        ns.cdTest:Show()
        ns.cdTest.cd:SetCooldown(GetTime(), 10)
        Say(L("a 10s cooldown is drawn in the middle of the screen - do you see the sweep?",
              "в центре экрана нарисован кулдаун на 10 секунд — развёртка видна?"))
        C_Timer.After(11, function() if ns.cdTest then ns.cdTest:Hide() end end)

    elseif cmd == "mirror" then
        CG.db.mirror = OnOff(rest:lower(), CG.db.mirror ~= false)
        ns.mirrorEnabled = CG.db.mirror
        CG:UpdateAuras()
        Say(L("Cooldown Manager fallback: %s", "запасной путь через Cooldown Manager: %s"),
            CG.db.mirror and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "soon" then
        local idx, secs = rest:match("^(%S+)%s+(%S+)$")
        local rule = idx and GetRule(idx)
        if rule then
            local n = (secs:lower() == "off") and 0 or tonumber(secs)
            if not n then
                Say(L("usage: /cg soon <#> <seconds|off>", "формат: /cg soon <№> <секунды|off>"))
            else
                rule.soon = math.max(0, math.min(60, n))
                CG.lastSig = nil
                CG:Rebuild()
                Say(L("warn above the resource: %ds left", "предупреждать над ресурсом: за %d с"),
                    rule.soon)
            end
        elseif not idx then
            Say(L("usage: /cg soon <#> <seconds|off>", "формат: /cg soon <№> <секунды|off>"))
        end

    elseif cmd == "rows" then
        CG.db.center.rows = OnOff(rest:lower(), CG.db.center.rows)
        CG.lastSig = nil
        CG:Rebuild()
        Say(L("strip in rows by kind: %s", "полоса строками по типу: %s"),
            CG.db.center.rows and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "pack" then
        CG.db.center.pack = OnOff(rest:lower(), CG.db.center.pack ~= false)
        CG.lastSig = nil
        CG:Rebuild()
        Say(L("close gaps in the strip: %s", "закрывать дырки в полосе: %s"),
            CG.db.center.pack and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "minimap" then
        -- The command talks about showing it; the flag stores the opposite.
        local show = OnOff(rest:lower(), not CG.db.minimap.hide)
        CG.db.minimap.hide = not show
        if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
        Say(L("minimap button: %s", "кнопка у миникарты: %s"),
            CG.db.minimap.hide and L("off", "выкл") or L("on", "вкл"))

    elseif cmd == "hidecdm" then
        CG.db.hideCDM = OnOff(rest:lower(), not CG.db.hideCDM)
        ns.ApplyCDMVisibility()
        Say(L("Cooldown Manager hidden: %s", "Cooldown Manager скрыт: %s"),
            CG.db.hideCDM and L("yes", "да") or L("no", "нет"))
        if CG.db.hideCDM then
            Say(L("it keeps running - the aura states read it",
                  "он продолжает работать — состояния по аурам читают его"))
        end

    elseif cmd == "stackpos" then
        local where = rest:lower()
        local valid = {
            topleft = true, topright = true, center = true,
            bottomleft = true, bottomright = true,
        }
        if not valid[where] then
            Say(L("usage: /cg stackpos topleft|topright|center|bottomleft|bottomright",
                  "формат: /cg stackpos topleft|topright|center|bottomleft|bottomright"))
        else
            CG.db.stackPos = where
            -- The position is applied when a frame is attached, so the layout
            -- has to be rebuilt rather than merely refreshed.
            CG.lastSig = nil
            CG:Rebuild()
            Say(L("stack count: %s", "счётчик стаков: %s"), where)
        end

    elseif cmd == "stacksize" then
        local n = tonumber(rest)
        if not n then
            Say(L("usage: /cg stacksize <50-200>", "формат: /cg stacksize <50-200>"))
        else
            CG.db.stackScale = math.max(50, math.min(200, n))
            CG.lastSig = nil
            CG:Rebuild()
            Say(L("stack count size: %d%%", "размер счётчика: %d%%"), CG.db.stackScale)
        end

    elseif cmd == "procstrip" then
        CG.db.center.autoProc = OnOff(rest:lower(), CG.db.center.autoProc ~= false)
        CG:Rebuild()
        Say(L("procs in the reminder strip: %s", "проки в полосе напоминаний: %s"),
            CG.db.center.autoProc and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "blizzglow" then
        CG.db.blizzGlow = OnOff(rest:lower(), CG.db.blizzGlow ~= false)
        CG:HideBlizzGlow()
        Say(L("Blizzard's own proc glow: %s", "штатное свечение прока: %s"),
            CG.db.blizzGlow and L("on", "вкл") or L("off", "выкл"))
        if CG.db.blizzGlow then
            Say(L("it comes back on the next proc", "вернётся со следующим проком"))
        end

    elseif cmd == "poll" then
        local ms = tonumber(rest)
        if ms and ms >= 0 and ms <= 2000 then
            CG.db.auraPoll = ms / 1000
            ns.pollInterval = CG.db.auraPoll
            Say(ms == 0 and L("polling off (events only)", "опрос выключен (только события)")
                         or L("aura polling: every %d ms", "опрос аур: каждые %d мс"), ms)
        else
            Say(L("usage: /cg poll <0-2000 ms>  (current: %d)", "формат: /cg poll <0-2000 мс>  (сейчас: %d)"),
                math.floor((CG.db.auraPoll or 0) * 1000 + 0.5))
        end

    elseif cmd == "del" or cmd == "remove" then
        local rule, n = GetRule(rest)
        if rule then
            local name = ns.SpellName(rule.spell)
            table.remove(CG:GetRules(), n)
            CG:Rebuild()
            Say(L("removed: %s", "удалено: %s"), name)
        end

    elseif cmd == "toggle" then
        local rule = GetRule(rest)
        if rule then
            rule.enabled = not (rule.enabled ~= false)
            CG:Rebuild()
            Say("%s: %s", ns.SpellName(rule.spell),
                rule.enabled and L("on", "вкл") or L("off", "выкл"))
        end

    elseif cmd == "style" then
        local idx, key = rest:match("^(%S+)%s+(%S+)$")
        local rule = idx and GetRule(idx)
        if rule then
            local wanted = key:lower()
            local entry
            for _, s in ipairs(ns.STYLES) do
                if s.key == wanted then entry = s end
            end
            if not entry then
                Say(L("unknown style: %s", "неизвестный стиль: %s"), key)
                PrintStyles()
            else
                rule.style = entry.key
                rule.styleLocked = true
                CG:Rebuild()
                Say(L("style: %s", "стиль: %s"), entry.label)
            end
        elseif not idx then
            Say(L("usage: /cg style <#> <name>", "формат: /cg style <№> <стиль>"))
        end

    elseif cmd == "color" or cmd == "colour" then
        local idx, r, g, b = rest:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)$")
        local rule = idx and GetRule(idx)
        if rule then
            rule.r, rule.g, rule.b = tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255
            -- Chosen by hand: the rebuild stops managing this rule's look.
            rule.styleLocked = true
            CG:Rebuild()
            Say(L("colour set", "цвет установлен"))
        elseif not idx then
            Say(L("usage: /cg color <#> <0-255> <0-255> <0-255>", "формат: /cg color <№> <0-255> <0-255> <0-255>"))
        end

    elseif cmd == "center" or cmd == "centre" then
        local rule = GetRule(rest)
        if rule then
            -- Toggles what the strip actually does with this rule, automatic
            -- entries included, so it agrees with the options window.
            if ns.OnStrip(rule) then
                rule.center, rule.stripOff = nil, true
            else
                rule.center, rule.stripOff = true, nil
            end
            CG:Rebuild()
            Say(L("in the reminder strip: %s", "в полосе напоминаний: %s"),
                ns.OnStrip(rule) and L("on", "вкл") or L("off", "выкл"))
        end

    elseif cmd == "power" then
        local idx, token = rest:match("^(%S+)%s+(%S+)$")
        local rule = idx and GetRule(idx)
        if rule then
            local pt, ok = ns.ResolvePowerToken(token)
            if not ok then
                Say(L("unknown resource: %s", "неизвестный ресурс: %s"), token)
            else
                rule.power = pt
                CG:Rebuild()
                Say(L("resource: %s", "ресурс: %s"), PowerText(rule))
            end
        elseif not idx then
            Say(L("usage: /cg power <#> <auto|combo|holy|chi|...>", "формат: /cg power <№> <auto|combo|holy|chi|...>"))
        end

    elseif cmd == "move" or cmd == "unlock" then
        local locked = CG.db.center.locked ~= false
        CG:SetAnchorLocked(not locked)
        Say(locked and L("anchor unlocked - drag it, then /cg move again",
                         "якорь разблокирован — перетащи его и снова введи /cg move")
                    or L("anchor locked", "якорь заблокирован"))

    elseif cmd == "size" then
        local n = tonumber(rest)
        if n and n >= 16 and n <= 200 then
            CG.db.center.size = n
            CG:Rebuild()
            Say(L("reminder icon size: %d", "размер иконок в полосе: %d"), n)
        else
            Say(L("usage: /cg size <16-200>", "формат: /cg size <16-200>"))
        end

    elseif cmd == "test" then
        CG:Test(6)
        Say(L("test: 6 seconds", "тест: 6 секунд"))

    elseif cmd == "on" or cmd == "off" then
        CG.db.enabled = (cmd == "on")
        CG:Rebuild()
        if not CG.db.enabled then CG:HideAll() end
        Say(L("addon: %s", "аддон: %s"), CG.db.enabled and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "combat" then
        CG.db.combatOnly = OnOff(rest:lower(), CG.db.combatOnly)
        CG:UpdateNow()
        Say(L("combat only: %s", "только в бою: %s"),
            CG.db.combatOnly and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "cdm" then
        CG.db.cdm = OnOff(rest:lower(), CG.db.cdm)
        CG:Rebuild()
        Say(L("Cooldown Manager icons: %s", "иконки Cooldown Manager: %s"),
            CG.db.cdm and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "secret" then
        CG.db.secretMode = OnOff(rest:lower(), CG.db.secretMode)
        CG:UpdateNow()
        Say(L("restricted-content mode: %s", "режим закрытых значений: %s"),
            CG.db.secretMode and L("on", "вкл") or L("off", "выкл"))

    elseif cmd == "centeron" then
        CG.db.center.enabled = true
        CG:Rebuild()
        Say(L("centre display on", "центр экрана: вкл"))

    elseif cmd == "centeroff" then
        CG.db.center.enabled = false
        CG:Rebuild()
        Say(L("centre display off", "центр экрана: выкл"))

    else
        PrintHelp()
    end
end

SLASH_COMBOGLOW1 = "/comboglow"
if ns.SLASH ~= "/comboglow" then
    SLASH_COMBOGLOW2 = ns.SLASH
end
SlashCmdList["COMBOGLOW"] = Handler
