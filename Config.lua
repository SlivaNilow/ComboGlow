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

-- The three states a spell can be marked in. Each is its own rule, so a spell
-- can carry all three at once with a different marker for each.
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

local STATE_DEFAULTS = {
    active  = { style = "pixel",  r = 0, g = 1, b = 0      },
    missing = { style = "fill",   r = 1, g = 0, b = 0      },
    proc    = { style = "modern", r = 1, g = 0.85, b = 0.1 },
    -- "ready" is the slot name the options window uses for the resource /
    -- proc state; same look as a proc.
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
    The three slots of one spell

    "up" and "gone" are aura rules; "ready" is the resource threshold, which
    also lights on a proc -- a finisher that procced is ready whatever the bar
    says. Each slot is a separate rule, so a spell can carry all three with a
    different marker for each, and a slot nobody configures simply does not
    exist and draws nothing.
---------------------------------------------------------------------------]]
function ns.FindSlotRule(spellID, slot)
    for i, r in ipairs(CG:GetRules()) do
        if r.spell == spellID then
            if slot == "ready" then
                if r.kind ~= "aura" or r.proc then return r, i end
            elseif r.kind == "aura" and not r.proc and ns.RuleState(r) == slot then
                return r, i
            end
        end
    end
end

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

function ns.AddSlotRule(spellID, slot)
    local existing = ns.FindSlotRule(spellID, slot)
    if existing then return existing end

    local rules = CG:GetRules()
    local rule
    if slot == "ready" then
        local cost = SpendsResource(spellID)
        if cost then
            rule = {
                spell  = spellID,
                min    = (cost >= 2) and cost or 1,
                atMax  = (cost < 2) or nil,
                orProc = true,
                style  = "modern",
                r = 1, g = 0.85, b = 0.1,
                center = false, enabled = true,
            }
        elseif ns.cdmEssentialSpells and ns.cdmEssentialSpells[spellID] then
            -- A burst: "ready" means its cooldown is done.
            rule = {
                kind = "cd", spell = spellID,
                combat = true, orProc = true,
                style = "modern",
                r = 1, g = 0.85, b = 0.1,
                center = false, enabled = true,
            }
        else
            rule = {
                kind = "aura", spell = spellID, proc = true,
                timer = false, style = "modern",
                r = 1, g = 0.85, b = 0.1,
                center = false, enabled = true,
            }
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
    if rule.auraID then
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
    local pt = CG.powerType
    local rules = CG:GetRules()

    -- Tracked per STATE, not per spell: re-scanning should top up a state
    -- that is missing rather than skip a spell that already has one.
    local havePower, haveUp, haveGone, haveBurst = {}, {}, {}, {}
    for _, r in ipairs(rules) do
        if r.kind == "cd" then
            haveBurst[r.spell] = true
        elseif r.kind ~= "aura" then
            havePower[r.spell] = true
        elseif r.missing then
            haveGone[r.spell] = true
        elseif not r.proc then
            haveUp[r.spell] = true
        end
    end

    local canCost = C_Spell and C_Spell.GetSpellPowerCost

    -- Collect first, so nothing is printed for an empty scan.
    local seen, spenders, auras, bursts = {}, {}, {}, {}
    ns.ForEachActionButton(function(_, spellID)
        if not spellID or seen[spellID] then return end
        seen[spellID] = true

        -- Spends the class resource -> a count rule.
        if pt and canCost and not havePower[spellID] then
            local ok, costs = pcall(canCost, spellID)
            if ok and type(costs) == "table" then
                for _, c in ipairs(costs) do
                    if c.type == pt then
                        spenders[#spenders + 1] = { spell = spellID, cost = tonumber(c.cost) or 0 }
                        break
                    end
                end
            end
        end

        -- In the Essential viewer and does not spend the resource -> a burst,
        -- marked when its cooldown is done. Blizzard's own list of what
        -- matters for the spec, so there is nothing hardcoded here.
        if ns.cdmEssentialSpells[spellID] and not havePower[spellID]
           and not haveBurst[spellID] then
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
        if ns.cdmAuraSpells[spellID] then
            local harmful = true
            if C_Spell and C_Spell.IsSpellHarmful then
                local ok, v = pcall(C_Spell.IsSpellHarmful, spellID)
                if ok and v ~= nil then harmful = v and true or false end
            end
            if not haveUp[spellID] then
                auras[#auras + 1] = { spell = spellID, harmful = harmful, slot = "active" }
            end
            -- Harmful ones also get the "gone" state, which is what fills the
            -- reminder strip. Not for your own buffs: a personal cooldown is
            -- missing most of the time and nagging about it is noise.
            if harmful and not haveGone[spellID] then
                auras[#auras + 1] = { spell = spellID, harmful = harmful, slot = "missing" }
            end
        end
    end)

    local total = #spenders + #auras + #bursts
    if total == 0 then
        if not quiet then
            Say(L("nothing to set up from your bars - use /cg add or /cg dot",
                  "по панелям нечего настроить — используй /cg add или /cg dot"))
        end
        return 0
    end

    if intro then Say(intro) end

    for _, entry in ipairs(spenders) do
        local rule = {
            spell   = entry.spell,
            min     = (entry.cost >= 2) and entry.cost or 1,
            atMax   = (entry.cost < 2) or nil,
            style   = "modern",
            r = 1, g = 0.85, b = 0.1,
            center  = false,
            enabled = true,
        }
        rules[#rules + 1] = rule
        Say(L("+ %s at %s", "+ %s при %s"), ns.SpellName(entry.spell), RangeText(rule))
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
    Say(L("%d rules added. /cg list to review, /cg del <#> to drop one.",
          "добавлено правил: %d. /cg list — посмотреть, /cg del <№> — удалить."), total)
    return total
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
        { "/cg warn <#> <sec>",        L("turn red this many seconds before it runs out (0 = never)", "краснеть за столько секунд до конца (0 = никогда)") },
        { "/cg alpha <#> <0-100>",     L("brightness of the marker", "яркость метки") },
        { "/cg thick <#> <1-10>",      L("frame thickness in pixels", "толщина рамки в пикселях") },
        { "/cg timer <#> on|off",      L("time left on the icon", "остаток времени на иконке") },
        { "/cg swipe <#> on|off",      L("also draw a cooldown sweep for the remaining time", "рисовать ещё и развёртку кулдауна по остатку времени") },
        { "/cg poll <ms>",             L("how often aura state is re-read (0 = events only)", "как часто перечитывать ауры (0 = только по событиям)") },
        { "/cg mirror on|off",         L("fallback: take aura state from the Cooldown Manager", "запасной путь: брать состояние ауры у Cooldown Manager") },
        { "/cg auracheck",             L("report what the aura API answers here, with measured lag", "показать ответ aura API и замеренную задержку") },
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
    if #rules == 0 then
        Say(L("no rules for this spec yet. Example: /cg add max Eviscerate",
              "для этой специализации правил нет. Пример: /cg add max Потрошение"))
        return
    end
    Say(L("rules (spec %d, %d buttons scanned):", "правила (спек %d, кнопок просканировано: %d):"),
        CG.specID or 0, ns.scannedButtons or 0)
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
            CG:Rebuild()
            Say(L("colour set", "цвет установлен"))
        elseif not idx then
            Say(L("usage: /cg color <#> <0-255> <0-255> <0-255>", "формат: /cg color <№> <0-255> <0-255> <0-255>"))
        end

    elseif cmd == "center" or cmd == "centre" then
        local rule = GetRule(rest)
        if rule then
            rule.center = not rule.center
            CG:Rebuild()
            Say(L("in the reminder strip: %s", "в полосе напоминаний: %s"),
                rule.center and L("on", "вкл") or L("off", "выкл"))
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
