--[[---------------------------------------------------------------------------
    ComboGlow - Auras.lua

    Aura rules: glow a button while your buff/debuff from that spell is up on a
    unit (or while it is MISSING), with the remaining time on the icon.

    12.1 notes -- why it is written this way:

      * Index / slot scans (GetAuraDataByIndex, GetAuraSlots, GetDebuffDataBy-
        Index) HARD ERROR under aura restrictions (M+ and raids, even out of
        combat). That is what breaks AdiButtonAuras on this patch. Nothing here
        ever enumerates auras: every lookup is a direct per-spell query.

      * Aura fields can be SECRET. Nothing is compared or used in arithmetic
        before type() + issecretvalue() say it is a plain number.

      * The remaining time is taken from C_UnitAuras.GetAuraDuration(), which
        returns a DURATION OBJECT. Fed to Cooldown:SetCooldownFromDurationObject()
        it renders engine-side and keeps working when the number itself is
        secret. Plain readings additionally get our own text.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...

local IsSecret = ns.IsSecret
local GetTime = GetTime

local UA = C_UnitAuras

ns.AURA_UNITS = { player = true, target = true, focus = true, mouseover = true, pet = true }

--[[-------------------------------------------------------------------------
    Query
---------------------------------------------------------------------------]]

-- Are aura reads restricted right now? Cheap probe, cached for one frame.
local restrictedStamp
function ns.AurasRestricted()
    local now = GetTime()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        restrictedStamp = now
        return true
    end
    return restrictedStamp == now
end

local function PlainNumber(v)
    if type(v) ~= "number" then return nil end
    if IsSecret(v) then return nil end
    return v
end

local function FilterFor(rule)
    if rule.helpful then return "HELPFUL|PLAYER" end
    return "HARMFUL|PLAYER"
end

-- The auras a rule may be satisfied by, in order. Usually one. A proc can have
-- several buffs behind it -- Touch the Cosmos frees whichever of Starsurge and
-- Starfall you press, while each also has a buff of its own -- so the first one
-- that is up wins. Reused between calls; QueryAura is never re-entrant.
local idBuf = {}
local function AuraCandidates(rule)
    wipe(idBuf)
    local seen
    if type(rule.auraIDs) == "table" then
        for _, id in ipairs(rule.auraIDs) do
            if type(id) == "number" then
                seen = seen or {}
                if not seen[id] then
                    seen[id] = true
                    idBuf[#idBuf + 1] = id
                end
            end
        end
    end
    if rule.auraID and not (seen and seen[rule.auraID]) then
        idBuf[#idBuf + 1] = rule.auraID
    end
    if #idBuf == 0 and rule.spell then idBuf[#idBuf + 1] = rule.spell end
    return idBuf
end

-- True when the rule names its aura(s) explicitly, rather than falling back to
-- the spell's own. The name-based lookup below only makes sense in the latter.
local function HasExplicitAura(rule)
    return rule.auraID ~= nil
        or (type(rule.auraIDs) == "table" and #rule.auraIDs > 0)
end
ns.HasExplicitAura = HasExplicitAura

-- Returns: found (true / false / nil = could not tell), remaining, total, durObj
function ns.QueryAura(rule)
    local unit = rule.unit or "target"
    if not UnitExists(unit) then return false end
    if not UA then return nil end

    local aura, ok
    local ids = AuraCandidates(rule)

    local function Lookup(id)
        -- Your own buff on yourself is the one case Blizzard kept readable for
        -- a set of whitelisted spells, and it has its own entry point.
        if unit == "player" and UA.GetPlayerAuraBySpellID then
            local okP, res = pcall(UA.GetPlayerAuraBySpellID, id)
            if okP and type(res) == "table" then return res end
        end
        -- By id: survives a debuff whose NAME differs from the spell casting it.
        if UA.GetUnitAuraBySpellID then
            local ok2, res = pcall(UA.GetUnitAuraBySpellID, unit, id)
            if ok2 and type(res) == "table" then return res end
        end
        return nil
    end

    -- With more than one aura behind a rule the two kinds of state want
    -- opposite answers. A proc is free if ANY of its buffs is up: Touch the
    -- Cosmos and Starweaver's Warp do the same job and either will do. An
    -- ordinary state watches what one spell APPLIES, and a spell that lands
    -- two debuffs needs both -- either one missing is a reason to recast, so
    -- "up" has to mean all of them.
    --
    -- The countdown comes from the first, not the soonest to expire: auras
    -- applied by the same cast share a duration, and picking the minimum would
    -- mean reading every one of them for a difference that is not there.
    if rule.proc or #ids < 2 then
        for _, id in ipairs(ids) do
            aura = Lookup(id)
            if aura then break end
        end
    else
        for _, id in ipairs(ids) do
            local a = Lookup(id)
            if not a then return false end
            aura = aura or a
        end
    end

    -- By name with the PLAYER filter: catches cast id ~= aura id, same name.
    if not aura and not HasExplicitAura(rule) and UA.GetAuraDataBySpellName then
        local name = rule.auraName
        if not name then
            local info = ns.SpellInfo(rule.spell)
            name = info and info.name
            rule.auraName = name
        end
        if name then
            ok, aura = pcall(UA.GetAuraDataBySpellName, unit, name, FilterFor(rule))
            if not ok then return nil end      -- API refused: unknown, not absent
        end
    end

    if type(aura) ~= "table" then return false end

    -- Present. Now try, in order of reliability, to learn how long is left.
    local durObj
    local iid = aura.auraInstanceID
    if iid ~= nil and not IsSecret(iid) and UA.GetAuraDuration then
        local ok2, d = pcall(UA.GetAuraDuration, unit, iid)
        if ok2 and type(d) == "table" then durObj = d end
    end

    local remaining, total
    if durObj and durObj.GetRemainingDuration then
        local ok3, r = pcall(durObj.GetRemainingDuration, durObj)
        if ok3 then remaining = PlainNumber(r) end
    end

    local dur = PlainNumber(aura.duration)
    local exp = PlainNumber(aura.expirationTime)
    if dur and dur > 0 then total = dur end
    if not remaining and exp then remaining = exp - GetTime() end

    return true, remaining, total, durObj, PlainNumber(aura.applications)
end

--[[-------------------------------------------------------------------------
    Display
---------------------------------------------------------------------------]]
local function FormatTime(t)
    if t >= 60 then return ("%d:%02d"):format(t / 60, t % 60) end
    if t >= 10 then return ("%d"):format(t) end
    if t > 0 then return ("%.1f"):format(t) end
    return ""
end
ns.FormatAuraTime = FormatTime

local ArmTicker   -- defined with the ticker below

-- Re-arming a Cooldown with the same numbers is a no-op, but our recomputed
-- start drifts a little every poll, and any change restarts the animation --
-- which reads as the sweep resetting whenever anything else happens. So the
-- widget is only touched when the value genuinely moved.
local function ArmCooldown(frame, start, dur)
    if frame._cdStart and math.abs(start - frame._cdStart) < 0.35
       and frame._cdDur == dur then
        return
    end
    frame._cdStart, frame._cdDur = start, dur
    frame.CD:SetCooldown(start, dur)
end

local function ClearTimer(frame)
    frame.expiresAt = nil
    frame.totalDur = nil
    frame._cdStart, frame._cdDur, frame._cdGen = nil, nil, nil
    if frame.CD:IsShown() then
        frame.CD:Clear()
        frame.CD:Hide()
    end
    if frame.TimerText:IsShown() then
        frame.TimerText:SetText("")
        frame.TimerText:Hide()
    end
end
ns.ClearTimer = ClearTimer

--[[-------------------------------------------------------------------------
    Stack count

    Read straight off the aura when it is readable, mirrored as TEXT from the
    Cooldown Manager when it is not -- SetText accepts a secret string, so the
    number reaches the screen without ever being looked at in Lua. Same trick
    as the countdown.

    Shown from two upwards: "1" on a stacking aura is the same as no number,
    and a 1 on every icon is noise.
---------------------------------------------------------------------------]]
local function ClearStacks(frame)
    if not frame.StackText then return end
    if frame.StackText:IsShown() then
        frame.StackText:SetText("")
        frame.StackText:Hide()
    end
end
ns.ClearStacks = ClearStacks

local function ShowStacks(frame, rule, n)
    if not frame.StackText then return end
    -- Two frames on one button when a rule has a second marker; only the
    -- first writes, or the number is drawn twice on top of itself.
    if rule.stacks == false or frame.secondary then return ClearStacks(frame) end
    if type(n) ~= "number" or IsSecret(n) or n < 2 then return ClearStacks(frame) end
    frame.StackText:SetText(tostring(n))
    frame.StackText:Show()
end

-- Forward declaration: the stack lookup below needs the timer lookup, which is
-- defined further down with the rest of the mirror.
local FindTimerFS

-- The Cooldown Manager's own count, copied verbatim. It writes the field only
-- when there is more than one, so no threshold is needed here.
--[[-------------------------------------------------------------------------
    Where the count lives on an item frame

    Not on the frame: /cg stacks reported "no font strings directly on the
    frame" for every entry. They belong to its children, which is also why the
    countdown lookup goes through itemFrame.Cooldown.

    So the children are searched, minus the cooldown (its font string is the
    timer) and minus whatever the timer lookup already claimed. Among what is
    left, a count looks like one of two things: text that is SECRET, which is
    what a stack count is under 12.1's restrictions, or a short run of digits.
    Anything longer and readable is the spell name -- those frames carry one --
    and drawing that as a stack count would be worse than drawing nothing.

    Only a positive match is cached. An empty string is a count with nothing to
    show yet, and caching that would freeze the answer at "no stacks".
---------------------------------------------------------------------------]]
local stackFS = setmetatable({}, { __mode = "k" })
local function LooksLikeCount(rgn)
    local ok, txt = pcall(rgn.GetText, rgn)
    if not ok then return nil end
    -- IsSecret first: a secret must not meet a comparison, "== nil" included.
    if IsSecret(txt) then return true end
    if type(txt) ~= "string" then return nil end       -- nil: empty for now
    if #txt > 0 and #txt <= 3 and txt:match("^%d+$") then return true end
    return false                                        -- readable text: a name
end

local function FindStackFS(itemFrame)
    local cached = stackFS[itemFrame]
    if cached then return cached end

    for _, key in ipairs({ "Applications", "Count", "ChargeCount", "Stacks" }) do
        local sub = itemFrame[key]
        if type(sub) == "table" then
            local fs
            if sub.GetObjectType and sub:GetObjectType() == "FontString" then
                fs = sub
            elseif type(sub.Text) == "table" and sub.Text.GetObjectType
                   and sub.Text:GetObjectType() == "FontString" then
                fs = sub.Text
            end
            if fs then
                stackFS[itemFrame] = fs
                return fs
            end
        end
    end

    if not itemFrame.GetChildren then return nil end
    local cd = itemFrame.Cooldown or itemFrame.cooldown
    local timer = FindTimerFS(itemFrame)
    local empty
    for _, child in pairs({ itemFrame:GetChildren() }) do
        if child and child ~= cd and child.GetRegions then
            for _, rgn in pairs({ child:GetRegions() }) do
                if rgn and rgn ~= timer and rgn.GetObjectType
                   and rgn:GetObjectType() == "FontString" then
                    local verdict = LooksLikeCount(rgn)
                    if verdict == true then
                        stackFS[itemFrame] = rgn
                        return rgn
                    elseif verdict == nil and not empty then
                        empty = rgn
                    end
                end
            end
        end
    end
    if empty then stackFS[itemFrame] = empty end
    return empty
end

ns.FindStackFS = FindStackFS

-- Diagnostic: every font string on a Cooldown Manager item frame and what it
-- says. Picking the right one has been guesswork twice now; this makes it a
-- lookup. Text may be secret, so it is never formatted -- only reported as
-- present.
function ns.DumpFontStrings(frame, say, prefix)
    prefix = prefix or "  "
    local function Text(rgn)
        local ok, txt = pcall(rgn.GetText, rgn)
        if not ok then return "<err>" end
        if txt == nil then return "<nil>" end
        if IsSecret(txt) then return "<secret>" end
        if type(txt) ~= "string" then return "<" .. type(txt) .. ">" end
        return '"' .. txt .. '"'
    end

    local n = 0
    if frame.GetRegions then
        for _, rgn in pairs({ frame:GetRegions() }) do
            if rgn and rgn.GetObjectType and rgn:GetObjectType() == "FontString" then
                n = n + 1
                say("%sfs#%d shown=%s %s", prefix, n, tostring(rgn:IsShown()), Text(rgn))
            end
        end
    end
    if n == 0 then say("%sno font strings directly on the frame", prefix) end

    if frame.GetChildren then
        for _, child in pairs({ frame:GetChildren() }) do
            if child and child.GetRegions then
                local m = 0
                for _, rgn in pairs({ child:GetRegions() }) do
                    if rgn and rgn.GetObjectType and rgn:GetObjectType() == "FontString" then
                        m = m + 1
                        say("%schild fs#%d shown=%s %s", prefix, m,
                            tostring(rgn:IsShown()), Text(rgn))
                    end
                end
            end
        end
    end
end

local function MirrorStackText(frame, rule, itemFrame)
    if rule.stacks == false or rule.missing or frame.secondary then return false end
    if not frame.StackText then return false end
    local fs = FindStackFS(itemFrame)
    if not fs then return false end
    local ok, txt = pcall(fs.GetText, fs)
    if not ok or type(txt) == "nil" then return false end
    -- A readable empty string is a count with nothing to show. Secret text is
    -- passed straight through: SetText takes it, and it is never looked at.
    if not IsSecret(txt) and type(txt) == "string" and #txt == 0 then return false end
    if not pcall(frame.StackText.SetText, frame.StackText, txt) then return false end
    frame.StackText:Show()
    return true
end

local function ShowTimer(frame, rule, remaining, total, durObj)
    -- A rule with two markers has two frames on the one button; only the first
    -- writes the countdown, or the same number is drawn twice on top of itself.
    if rule.timer == false or frame.secondary then
        -- Widgets off, but the timing is still tracked so the warning colour
        -- keeps working.
        ClearTimer(frame)
        frame.sweepFailed = nil
        frame.totalDur = total
        if remaining then
            frame.expiresAt = GetTime() + remaining
            ArmTicker()
        end
        return
    end

    frame.totalDur = total

    -- Time-shaped marker (or the sweep toggle): the duration object drives the
    -- widget, and the readable path can use it too.
    local wantsSweep = ns.WantsSweep(rule)
    local swept = false
    if wantsSweep then
        if durObj and frame.CD.SetCooldownFromDurationObject then
            frame.CD:SetDrawEdge(rule.style == "ring")
            swept = pcall(frame.CD.SetCooldownFromDurationObject, frame.CD, durObj)
            if swept then frame.CD:Show() end
        end
        if not swept and remaining and total and total > 0 then
            -- Plain reading: build the sweep from the numbers we already have.
            frame.CD:SetDrawEdge(rule.style == "ring")
            ArmCooldown(frame, GetTime() - (total - remaining), total)
            frame.CD:Show()
            swept = true
        end
    end
    if not swept and frame.CD:IsShown() then
        frame.CD:Clear()
        frame.CD:Hide()
    end
    frame.sweepFailed = (wantsSweep and not swept) or nil

    if remaining then
        -- Plain reading: tick it down locally, no further API calls.
        frame.expiresAt = GetTime() + remaining
        ArmTicker()
        frame.TimerText:Show()
        frame.TimerText:SetText(FormatTime(remaining))
    elseif durObj and frame.CD.SetCooldownFromDurationObject then
        -- Secret duration: hand the object to the engine and let it draw.
        frame.expiresAt = nil
        frame.TimerText:Hide()
        frame.CD:Show()
        pcall(frame.CD.SetCooldownFromDurationObject, frame.CD, durObj)
    else
        ClearTimer(frame)
    end
end

-- The last N seconds of the aura: time to refresh it. Used on the readable
-- path; the mirror path bakes the same threshold into a colour curve instead.
local function InPandemic(rule, frame)
    local warn = rule.warn
    if not warn or warn <= 0 then return false end
    if not frame.expiresAt then return false end
    return (frame.expiresAt - GetTime()) <= warn
end

--[[-------------------------------------------------------------------------
    Instant feedback on cast

    The aura only becomes readable once the server confirms it, and the event
    that announces it can arrive noticeably late. So a successful cast of a
    tracked spell flips the display immediately and the real reading corrects
    it as soon as it lands. The gap between the two is measured and reported
    by /cg auracheck, which is how "is the DATA late or just the display?"
    gets answered with a number instead of a guess.
---------------------------------------------------------------------------]]
local WINDOW = 2.0   -- how long an unconfirmed cast keeps the display flipped

local lastTotals = setmetatable({}, { __mode = "k" })

-- Learned aura lengths, per spell.
--
-- Counting down needs something to count from, and the only place a length can
-- be had is a successful read -- which in combat never happens for a target
-- debuff. So it is remembered on the rule, where it survives a reload, and
-- shared across that spell's states: they are all timing the same aura.
local totalOfSpell = {}

local function LearnTotal(rule, total)
    if not (total and total > 0 and rule.spell) then return end
    totalOfSpell[rule.spell] = total
    rule.lastTotal = total
end

local function KnownTotal(rule)
    if not rule.spell then return nil end
    local t = totalOfSpell[rule.spell]
    if t then return t end
    t = tonumber(rule.lastTotal)
    if t and t > 0 then
        totalOfSpell[rule.spell] = t
        return t
    end
end

-- When the player's own cast says this aura should run out, per spell.
local estExpiry = {}

-- True when the estimate puts this aura inside its last `soon` seconds.
--
-- An estimate, and called one. In combat nothing will tell us the time: the
-- aura is secret, the widget's numbers are secret, its countdown text is
-- secret. What is not secret is that WE cast the spell and how long it lasted
-- the last time anyone could read it. So the clock runs from the cast.
--
-- It is only believed INSIDE the window it can be right about. Once it runs
-- out it is ignored entirely -- a dot refreshed by something we did not see
-- would otherwise stay marked as nearly gone for the rest of the fight, and
-- the real "it is gone" signal arrives on its own anyway.
function ns.EstimatedNearlyGone(rule, soon)
    local est = rule.spell and estExpiry[rule.spell]
    if not est then return false end
    local now = GetTime()
    if now >= est then return false end
    return (est - now) <= soon
end
local optimistic = setmetatable({}, { __mode = "k" })
local castAt     = setmetatable({}, { __mode = "k" })
local readsWork  = setmetatable({}, { __mode = "k" })
local misses     = setmetatable({}, { __mode = "k" })
local reported   = setmetatable({}, { __mode = "k" })

-- Said once per rule per session: casts land but the aura never comes back
-- from the API, which is the signature of an environment where aura reads are
-- simply not available. Better to say it than to silently look broken.
local function ReportUnreadable(rule)
    if reported[rule] or not ns.Say then return end
    reported[rule] = true
    ns.Say(ns.L(
        "'%s': the cast lands but the aura never reads back here - /cg auracheck for details",
        "«%s»: каст проходит, но аура через API не читается в этих условиях — подробности в /cg auracheck"),
        ns.SpellName(rule.spell))
end

function ns.ReadsWork(rule) return readsWork[rule] and true or false end

--[[-------------------------------------------------------------------------
    Cooldown Manager mirror (fallback)

    When the aura cannot be read directly, the engine still knows: a Cooldown
    Manager item frame tracks aura presence itself. Its IsActive()/IsShown()
    answer is a SECRET BOOLEAN in restricted content -- it must never be
    tested in Lua, only handed to SetAlphaFromBoolean, which resolves it
    engine-side. So the overlay stays shown and its ALPHA carries the state.

    Fallback only: it requires the spell to be tracked in the Cooldown
    Manager, which the direct path does not.
---------------------------------------------------------------------------]]
function ns.FindMirror(rule)
    -- With several auras behind one rule the mirror can only follow one of
    -- them; the first is the one the scan picked.
    local id = rule.auraID
    if not id and type(rule.auraIDs) == "table" then id = rule.auraIDs[1] end
    id = id or rule.spell
    -- Buff viewers first: only there does IsActive() mean "the aura is up".
    local aura = ns.cdmAuraFrames
    if aura then
        local f = aura[id] or aura[rule.spell]
        -- By name as well: the viewer often tracks the aura's id while the rule
        -- carries the id that casts it.
        if not f and ns.cdmAuraNames then
            local n = (ns.SpellName(id) or ""):lower()
            f = ns.cdmAuraNames[n]
            if not f and id ~= rule.spell then
                f = ns.cdmAuraNames[(ns.SpellName(rule.spell) or ""):lower()]
            end
        end
        if f then return f, true end
    end
    local map = ns.cdmFrames
    if not map then return nil end
    local f = map[id] or map[rule.spell]
    return f, false
end

-- Mirror mode drives the frame's ALPHA, so anything that reuses the frame has
-- to put that back or the next owner inherits an invisible overlay.
function ns.ResetMirror(frame)
    frame._mirroring = nil
    frame:SetAlpha(1)
end

-- IsActive() is the real aura state. IsShown() is NOT a substitute: a Cooldown
-- Manager item stays shown while inactive unless the player turned on
-- Blizzard's "Hide When Inactive" edit-mode option, which is off by default --
-- mirroring it lights the button up 100% of the time. So if IsActive is
-- missing, the mirror declines rather than lying.
-- Never applies a boolean operator to the answer: a secret would blow up.
local function MirrorFlag(itemFrame)
    if not itemFrame.IsActive then return nil, false end
    local ok, v = pcall(itemFrame.IsActive, itemFrame)
    if not ok then return nil, false end
    return v, true
end

-- The remaining time cannot be formatted in Lua when it is secret, but the
-- engine already wrote it into a FontString on its own item frame -- and
-- SetText accepts a secret string. So the text is passed through verbatim.
-- Icon viewers keep it on the Cooldown widget; bar viewers put the name in
-- the first FontString and the timer in the second.
local timerFS = setmetatable({}, { __mode = "k" })

function FindTimerFS(itemFrame)
    local cached = timerFS[itemFrame]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local found
    local cd = itemFrame.Cooldown or itemFrame.cooldown
    if cd and cd.GetRegions then
        for _, rgn in pairs({ cd:GetRegions() }) do
            if rgn and rgn.GetObjectType and rgn:GetObjectType() == "FontString" then
                found = rgn
                break
            end
        end
    end
    if not found and itemFrame.GetRegions then
        local idx = 0
        for _, rgn in pairs({ itemFrame:GetRegions() }) do
            if rgn and rgn.GetObjectType and rgn:GetObjectType() == "FontString" then
                idx = idx + 1
                if idx == 2 then found = rgn break end
            end
        end
    end

    timerFS[itemFrame] = found or false
    return found
end

-- The real thing: a Cooldown Manager item frame carries the aura instance it
-- is bound to, and GetAuraDuration turns that into a duration object the
-- Cooldown widget can render itself. Both the unit and the instance id may be
-- SECRET -- they are only ever passed on to C, never inspected, and type() is
-- used instead of a nil compare.
-- Returns durObj, why ("ok" / a short reason for /cg auracheck)
local function MirrorDuration(itemFrame, rule)
    if not (UA and UA.GetAuraDuration) then return nil, "no GetAuraDuration" end
    local iid = itemFrame.auraInstanceID
    if type(iid) == "nil" then return nil, "no auraInstanceID" end

    -- The frame's own unit token first; it can be absent or itself secret, so
    -- the rule's unit is tried as well.
    local tried = false
    local unit = itemFrame.auraDataUnit
    if type(unit) ~= "nil" then
        tried = true
        local ok, durObj = pcall(UA.GetAuraDuration, unit, iid)
        if ok and type(durObj) == "table" then return durObj, "ok" end
    end

    local fallbackUnit = rule and rule.unit or "target"
    local ok, durObj = pcall(UA.GetAuraDuration, fallbackUnit, iid)
    if ok and type(durObj) == "table" then return durObj, "ok (rule unit)" end

    -- Caught on its way into the widget. In combat this is the only one there
    -- is, and it is the very object drawing the countdown on screen.
    local caught = ns.CaughtDuration(itemFrame)
    if caught then return caught, "ok (caught)" end

    -- Nothing passed an object, but something passed numbers. Build one.
    local made, form = ns.MadeDuration(itemFrame)
    if made then return made, "ok (made: " .. tostring(form) .. ")" end

    return nil, tried and "GetAuraDuration returned nothing" or "no auraDataUnit"
end

--[[-------------------------------------------------------------------------
    Catching the duration object on its way in

    The Cooldown Manager's entries ARE armed with a real duration object --
    that is what keeps their countdown running in combat, when everything else
    about the aura has gone secret. Nothing hands it back, though: both getters
    on the widget answer with a secret NUMBER, which is the one shape that is
    no use here. A number can be drawn and cannot be compared.

    So it is caught on the way past. A post-hook on the Cooldown metatable sees
    every object handed to any cooldown in the game, ours included, and keeps
    the last one per widget. hooksecurefunc is Blizzard's own mechanism: it
    appends, it does not wrap or replace, and it spreads no taint -- which
    matters, because these widgets live on frames the secure path touches.

    The idea is tullaCTC's, which hooks the same family of methods to know when
    any cooldown in the game starts.

    Arming a widget from plain numbers instead invalidates what we hold for it:
    the object is then no longer what is being drawn, and a stale duration is
    worse than none -- it answers confidently and wrongly.
---------------------------------------------------------------------------]]
local caughtDuration = setmetatable({}, { __mode = "k" })
local durationHooked

-- Which method last armed each widget, and with what. Nothing depends on it;
-- it is here because "no object was caught" has two readings -- nobody passed
-- one, or we were not listening -- and they need opposite fixes.
local armedBy = setmetatable({}, { __mode = "k" })
local caughtArgs = setmetatable({}, { __mode = "k" })

-- The arguments the game armed this widget with, to be passed straight on to
-- one of ours. Never read, only forwarded.
function ns.CaughtArgs(itemFrame)
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    return cd and caughtArgs[cd] or nil
end

local STALE_ON = { "SetCooldown", "SetCooldownDuration",
                   "SetCooldownFromExpirationTime", "SetCooldownUNIX", "Clear" }

local function HookCooldownDurations()
    if durationHooked ~= nil then return durationHooked end
    local mt = ActionButton1Cooldown and getmetatable(ActionButton1Cooldown)
    local proto = mt and mt.__index
    -- No button yet is "not yet", not "never": leave the answer unrecorded so
    -- the next poll tries again. Only a client that genuinely lacks the method
    -- is a permanent no.
    if type(proto) ~= "table" then return false end
    if not proto.SetCooldownFromDurationObject then
        durationHooked = false
        return false
    end
    hooksecurefunc(proto, "SetCooldownFromDurationObject", function(cd, durObj)
        caughtDuration[cd] = durObj
        armedBy[cd] = "DurationObject"
    end)
    for _, m in ipairs(STALE_ON) do
        if proto[m] then
            hooksecurefunc(proto, m, function(cd, a, b)
                caughtDuration[cd] = nil
                armedBy[cd] = m .. "(" .. type(a)
                    .. (IsSecret(a) and "!" or "") .. ")"
                -- Kept, never inspected. A secret can still be handed to
                -- another setter, which is enough to arm a widget of ours
                -- with exactly what the game armed this one with.
                if m == "Clear" then
                    caughtArgs[cd] = nil
                else
                    caughtArgs[cd] = { m = m, a = a, b = b }
                end
            end)
        end
    end
    durationHooked = true
    return true
end
ns.HookCooldownDurations = HookCooldownDurations

--[[-------------------------------------------------------------------------
    Making a duration object out of what the game armed the widget with

    The entries are armed with SetCooldown(start, duration) and both numbers
    are secret: they can be forwarded, never read. C_DurationUtil.CreateDuration
    takes numbers and hands back an OBJECT -- and an object is the one thing a
    colour curve can be evaluated against.

    So the secret goes in, an answer about it comes out, and the number itself
    is never seen by us at any point. That is the same trade the whole addon
    runs on, just built out of parts rather than found ready-made.

    The call shape is learned by trying, because a wrong arity fails loudly and
    a wrong GUESS would fail quietly -- only a table that can actually evaluate
    a curve is accepted, and the two-argument form is tried first so a
    one-argument fallback cannot quietly mean "starts now".
---------------------------------------------------------------------------]]
local madeDuration = setmetatable({}, { __mode = "k" })

local function UsableDuration(d)
    if type(d) ~= "table" then return false end
    local ok, has = pcall(function() return d.EvaluateRemainingDuration ~= nil end)
    return (ok and has) and true or false
end

local function MakeDuration(cd, args)
    local cached = madeDuration[cd]
    if cached and cached.args == args then return cached.obj, cached.form end
    local CDU = C_DurationUtil
    if not (CDU and CDU.CreateDuration) then return nil, "no factory" end

    local obj, form
    local shapes = { { "start,dur", args.a, args.b },
                     { "dur", args.b },
                     { "start", args.a } }
    for _, shape in ipairs(shapes) do
        local ok, d = pcall(CDU.CreateDuration, shape[2], shape[3])
        if ok and UsableDuration(d) then
            obj, form = d, shape[1]
            break
        end
    end
    madeDuration[cd] = { args = args, obj = obj, form = form or "none worked" }
    return obj, form or "none worked"
end

-- A duration object built from what this entry was armed with, or nil.
function ns.MadeDuration(itemFrame)
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    local args = cd and caughtArgs[cd]
    if not args then return nil, "nothing captured" end
    return MakeDuration(cd, args)
end

-- How this entry's widget was last armed, in whatever words the hook recorded.
function ns.ArmedBy(itemFrame)
    local hooked = HookCooldownDurations()
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    if not hooked then return "|cffff4040hook off|r" end
    return cd and armedBy[cd] or "nothing seen"
end

-- What we caught for this entry, if it is still a usable object.
function ns.CaughtDuration(itemFrame)
    HookCooldownDurations()
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    local d = cd and caughtDuration[cd]
    if type(d) ~= "table" then return nil end
    local ok, has = pcall(function() return d.EvaluateRemainingDuration ~= nil end)
    if ok and has then return d end
    return nil
end

-- The entry's own cooldown widget, asked for a duration OBJECT.
--
-- Kept for the probe only, and NOT on the polling path: on 12.1 both getters
-- answer with a secret NUMBER, which is the one shape that is no use to us.
-- A number can be drawn and cannot be compared; an object could have been
-- compared without ever being read. Left here so the next client that changes
-- this is a one-line change rather than a rediscovery.
--
-- Only a table with EvaluateRemainingDuration counts. A number here would be
-- the wrong kind of right: accepted, then silently useless.
local durationGetters = { "GetCooldownDuration", "GetCooldownDisplayDuration" }
function ns.WidgetDuration(itemFrame)
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    if not cd then return nil end
    for _, m in ipairs(durationGetters) do
        if cd[m] then
            local ok, d = pcall(cd[m], cd)
            if ok and type(d) == "table" then
                local okm, has = pcall(function()
                    return d.EvaluateRemainingDuration ~= nil
                end)
                if okm and has then return d end
            end
        end
    end
    return nil
end

-- Plain seconds left, off the Cooldown Manager's own cooldown widget.
--
-- The duration object is the better answer and is asked first everywhere this
-- is used, because it keeps working when the number is secret. But most target
-- debuffs do not have one: the instance id belongs to a unit we may not read,
-- so GetAuraDuration comes back empty and only the widget knows. It was told
-- the numbers by the game, so where they arrive plain they are exact.
--
-- nil means "no idea", never "none left" -- an expired sweep reads the same as
-- an absent one, and the caller must not treat those alike.
-- Returns left, why -- and the why is the point. "No number" has four
-- different causes here and they need four different answers from us, so a
-- bare nil would only move the guessing somewhere else.
local function MirrorRemaining(itemFrame)
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    if not cd then return nil, "no cooldown child" end
    if not cd.GetCooldownTimes then return nil, "no GetCooldownTimes" end
    local ok, startMS, durMS = pcall(cd.GetCooldownTimes, cd)
    if not ok then return nil, "GetCooldownTimes errored" end
    if type(startMS) ~= "number" or type(durMS) ~= "number" then
        return nil, "not numbers"
    end
    if IsSecret(startMS) or IsSecret(durMS) then return nil, "secret" end
    -- A cooldown armed from a duration object leaves the legacy pair at zero:
    -- the widget draws from the object and never fills these in.
    if durMS <= 0 then return nil, "duration 0 (armed from object?)" end
    local left = (startMS + durMS) / 1000 - GetTime()
    if left <= 0 then return nil, "expired" end
    return left, "ok"
end

-- One line saying where the early-gone threshold could get a time from for
-- this entry, and what stopped it. Shared by /cgl auracheck and /cgl probe:
-- the compact command exists because this question has to be asked IN COMBAT,
-- where the full report is too long to read and half of it is beside the point.
function ns.SoonReport(mf, rule)
    local left, why = MirrorRemaining(mf)
    local cdChild = mf and (mf.Cooldown or mf.cooldown)
    local rawS, rawD = "-", "-"
    if cdChild and cdChild.GetCooldownTimes then
        local okc, x, y = pcall(cdChild.GetCooldownTimes, cdChild)
        if okc then
            rawS = IsSecret(x) and "secret" or tostring(x)
            rawD = IsSecret(y) and "secret" or tostring(y)
        end
    end

    -- Both known sources came up empty, so ask the entry what it is holding.
    -- Blizzard draws a live countdown here in combat, which means the time is
    -- reachable from somewhere; the question is under which name, and whether
    -- it arrives plain.
    local carriers = {}
    if not left and mf then
        local okp = pcall(function()
            for k, v in pairs(mf) do
                if type(v) == "table" then
                    local okm = pcall(function()
                        if v.EvaluateRemainingDuration or v.GetRemainingDuration then
                            carriers[#carriers + 1] = tostring(k)
                        end
                    end)
                    if not okm then carriers[#carriers + 1] = tostring(k) .. "?" end
                end
            end
        end)
        if not okp then carriers[#carriers + 1] = "<pairs blocked>" end
        if mf.cooldownID and C_CooldownViewer
           and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            local oki, info = pcall(
                C_CooldownViewer.GetCooldownViewerCooldownInfo, mf.cooldownID)
            if oki and type(info) == "table" then
                for k, v in pairs(info) do
                    local t = type(v)
                    if t == "number" or t == "table" then
                        carriers[#carriers + 1] = ("info.%s=%s%s"):format(
                            tostring(k), t, IsSecret(v) and "!" or "")
                    end
                end
            end
        end
        if cdChild then
            for _, m in ipairs(durationGetters) do
                if cdChild[m] then
                    local okd, d = pcall(cdChild[m], cdChild)
                    local what = not okd and "err" or type(d)
                    if okd and type(d) == "table" then
                        local okm, has = pcall(function()
                            return d.EvaluateRemainingDuration ~= nil
                        end)
                        what = (okm and has) and "|cff40ff40durObj|r" or "table"
                    elseif okd and IsSecret(d) then
                        what = what .. "!"
                    end
                    carriers[#carriers + 1] = ("CD:%s->%s"):format(m, what)
                end
            end
        end    end

    -- The number the player can already see on the entry. If it arrives plain
    -- it can be parsed and compared like anything else; if it is secret it can
    -- only be handed to SetText, which is exactly what we do with it -- shown,
    -- never read. Worth reporting either way: "we can see it" and "we can read
    -- it" are different questions and they look identical on screen.
    local fs = FindTimerFS(mf)
    local textWhat = "no fontstring"
    if fs then
        local okt, txt = pcall(fs.GetText, fs)
        if not okt then textWhat = "err"
        elseif IsSecret(txt) then textWhat = "|cffff4040secret|r"
        elseif type(txt) == "string" then textWhat = ("|cff40ff40%q|r"):format(txt)
        else textWhat = type(txt) end
    end

    local n = ns.SoonSeconds(rule)
    return ("early-gone: soon=%s caught=%s armed=%s made=%s widgetLeft=%s (%s) raw=%s/%s text=%s%s"):format(
        n and ("%ds"):format(n) or "off",
        ns.CaughtDuration(mf) and "|cff40ff40yes|r" or "|cffff4040no|r",
        ns.ArmedBy(mf),
        (function()
            local d, form = ns.MadeDuration(mf)
            return d and ("|cff40ff40" .. tostring(form) .. "|r") or
                   ("|cffff4040" .. tostring(form) .. "|r")
        end)(),
        left and ("%.1fs"):format(left) or "|cffff4040none|r",
        why or "?", rawS, rawD, textWhat,
        #carriers > 0 and (" | carriers: " .. table.concat(carriers, ", ")) or "")
end

-- Every method a Cooldown widget has, sorted, with the ones that mention time
-- called out first. The engine answers questions about secret values through
-- methods like these -- SetAlphaFromBoolean, SetCountdownFormatter -- so if
-- there is a way to ask "is this nearly over" without ever reading a number,
-- its name is somewhere in this list.
function ns.CooldownAPI(say)
    local mt = ActionButton1Cooldown and getmetatable(ActionButton1Cooldown)
    local proto = mt and mt.__index
    if type(proto) ~= "table" then
        say("no Cooldown metatable")
        return
    end
    local hot, rest = {}, {}
    for k, v in pairs(proto) do
        if type(v) == "function" and type(k) == "string" then
            local t = k:find("Duration") or k:find("Remain") or k:find("Expir")
                or k:find("Countdown") or k:find("Boolean") or k:find("Curve")
                or k:find("Formatter") or k:find("Time")
            if t then hot[#hot + 1] = k else rest[#rest + 1] = k end
        end
    end
    table.sort(hot)
    table.sort(rest)
    say("|cff40ff40Cooldown, time-related (%d):|r %s", #hot, table.concat(hot, ", "))
    say("Cooldown, the rest (%d): %s", #rest, table.concat(rest, ", "))

    -- And the two helpers tullaCTC leans on, which are the shape of answer we
    -- are looking for: a rule the engine evaluates against a secret value.
    say("C_StringUtil.CreateNumericRuleFormatter: %s",
        tostring(C_StringUtil and C_StringUtil.CreateNumericRuleFormatter ~= nil))
    say("canaccessvalue: %s", tostring(_G.canaccessvalue ~= nil))
end

-- Deliberately terse. This is the one report that has to be read off the
-- screen mid-fight, so it prints a line per aura rule and nothing else.
function ns.SoonProbe(rules, say)
    say(ns.L("--- early-gone probe (%s) ---", "--- зонд «нет заранее» (%s) ---"),
        InCombatLockdown and InCombatLockdown()
            and ns.L("in combat", "в бою") or ns.L("out of combat", "вне боя"))
    -- Anything in the API that MAKES a duration object. If the entries turn
    -- out to be armed with secret numbers, a factory taking numbers is the
    -- only way back to something a curve can evaluate -- so it is worth
    -- knowing whether one exists before designing around its absence.
    local factories = {}
    for name, tbl in pairs(_G) do
        if type(name) == "string" and name:sub(1, 2) == "C_" and type(tbl) == "table" then
            local okp = pcall(function()
                for k, v in pairs(tbl) do
                    if type(v) == "function" and type(k) == "string"
                       and k:find("Duration") then
                        factories[#factories + 1] = name .. "." .. k
                    end
                end
            end)
            if not okp then factories[#factories + 1] = name .. ".<blocked>" end
        end
    end
    table.sort(factories)
    say("duration API: %s", #factories > 0 and table.concat(factories, ", ") or "none")

    local n = 0
    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and rule.kind == "aura" and not rule.proc then
            n = n + 1
            local name = (C_Spell.GetSpellInfo(rule.spell) or {}).name or rule.spell
            local mf, isAuraEntry = ns.FindMirror(rule)
            local _, _, _, durObj = ns.QueryAura(rule)
            say("%s [%s] durObj=%s mirror=%s", name,
                rule.missing and ns.L("gone", "нет") or ns.L("up", "висит"),
                tostring(durObj ~= nil),
                mf and (isAuraEntry and "aura" or "cd-entry") or "none")
            if mf then say("   " .. ns.SoonReport(mf, rule)) end
            -- What the marker on the bar is running on THIS instant. The
            -- countdown that ticks and the digit that reddens are the readable
            -- path's own local clock, not a read -- and if that clock is
            -- running here, it can answer "nearly gone" with no duration
            -- object involved at all.
            for _, fr in ipairs((ns.CG and ns.CG.auraFrames) or {}) do
                if fr.rule == rule then
                    say("   frame%s: shown=%s mirroring=%s expiresIn=%s pandemic=%s",
                        fr.isStrip and "(strip)" or "(bar)",
                        tostring(fr:IsShown()),
                        tostring(fr._mirroring and true or false),
                        fr.expiresAt and ("%.1fs"):format(fr.expiresAt - GetTime()) or "-",
                        tostring(fr.pandemicOn and true or false))
                end
            end
        end
    end
    if n == 0 then say(ns.L("no aura rules on this spec", "нет правил-аур на этом спеке")) end
end

-- The sweep is asked for either by the toggle or by picking a time-shaped
-- marker, where the duration IS the marker.
function ns.WantsSweep(rule)
    return rule.swipe or rule.style == "swipe" or rule.style == "ring"
end

local function MirrorCooldown(frame, rule, durObj, itemFrame)
    if rule.missing then return false end
    frame.CD:SetDrawEdge(rule.style == "ring")

    -- Preferred: the duration object renders even when the number is secret.
    -- Armed once per application, not per poll -- see ArmCooldown.
    if durObj and frame.CD.SetCooldownFromDurationObject then
        local gen = ns.CastGen and ns.CastGen(rule) or 0
        if frame._cdGen == gen and frame.CD:IsShown() then return true end
        if pcall(frame.CD.SetCooldownFromDurationObject, frame.CD, durObj) then
            frame._cdGen = gen
            frame.CD:Show()
            return true
        end
    end

    -- Second try: copy the numbers off the Cooldown Manager's own widget. Only
    -- works while they are plain -- a secret cannot go through SetCooldown --
    -- but that covers everything outside the restricted paths.
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    if cd and cd.GetCooldownTimes then
        local ok, startMS, durMS = pcall(cd.GetCooldownTimes, cd)
        if ok and type(startMS) == "number" and type(durMS) == "number"
           and not IsSecret(startMS) and not IsSecret(durMS) and durMS > 0 then
            ArmCooldown(frame, startMS / 1000, durMS / 1000)
            frame.CD:Show()
            return true
        end
    end

    return false
end

--[[-------------------------------------------------------------------------
    "Refresh me" colour

    The remaining time cannot be compared in Lua, so the threshold is baked
    into a STEP COLOUR CURVE and evaluated by the engine against the duration
    object: below the warning point it answers the warning colour, above it the
    normal one. The components that come back may be secret, so they go
    straight into a vertex-colour setter and are never looked at.
---------------------------------------------------------------------------]]
local warnCurves = setmetatable({}, { __mode = "k" })

local function WarnCurve(rule)
    local sig = ("%s|%s|%s|%s|%s|%s|%s"):format(rule.warn or 0,
        rule.r or 0, rule.g or 0, rule.b or 0,
        rule.wr or 1, rule.wg or 0, rule.wb or 0)
    local cached = warnCurves[rule]
    if cached and cached.sig == sig then return cached.curve end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    if curve.SetType and Enum and Enum.LuaCurveType then
        curve:SetType(Enum.LuaCurveType.Step)
    end
    curve:AddPoint(0, CreateColor(rule.wr or 1, rule.wg or 0, rule.wb or 0, 1))
    curve:AddPoint(rule.warn, CreateColor(rule.r or 0, rule.g or 1, rule.b or 0, 1))
    warnCurves[rule] = { sig = sig, curve = curve }
    return curve
end

--[[-------------------------------------------------------------------------
    Counting an aura as gone before it is

    "Gone" is the moment you are already late. This lets a "gone" state fire a
    few seconds early instead: the marker lights while the dot is still up but
    running out, which is when the reminder is worth acting on.

    It belongs to the "gone" state rather than to "up" -- the state whose whole
    job is to say "refresh this" -- so the bar and the strip agree, instead of
    the strip having a rule of its own.

    The remaining time is usually unreadable, and for a target debuff it always
    is, so the threshold is never compared in Lua. It goes to the duration
    object as a curve whose ALPHA is the answer: opaque below the threshold,
    clear above. The two halves compose without ever being combined -- a
    duration object exists only while the aura is up, so when there is none the
    ordinary presence gate already says "gone", and when there is one the curve
    says "nearly gone". Exactly the trick the warning colour uses.
---------------------------------------------------------------------------]]
local soonCurves = setmetatable({}, { __mode = "k" })

-- Per state, and zero is off. One number rather than a number and a switch
-- that can disagree with it: there is no useful reading of "count it gone zero
-- seconds early". Unset is off too -- a state nobody has asked this of should
-- not start doing it.
-- One boundary, two states. "Counted gone at 5s left" and "counted up until
-- 5s left" are the same sentence read from either end, so the number is stored
-- once -- on the "gone" rule, which is what mainly consumes it -- and the "up"
-- rule borrows it from its sibling. Storing a copy on each would let them
-- drift apart, and a pair of states that disagree about where up ends is two
-- markers lit at once saying opposite things.
function ns.SoonSeconds(rule)
    if rule.kind ~= "aura" or rule.proc then return nil end
    local src = rule
    if not rule.missing then
        src = (ns.FindSlotRule and ns.FindSlotRule(rule.spell, "missing")) or rule
    end
    local n = tonumber(src.soon) or 0
    if n <= 0 then return nil end
    return n
end

-- Two curves per threshold, one the mirror image of the other: the "gone"
-- state wants to be visible inside the window and the "up" state wants to be
-- gone from it, and that is the whole difference between them.
local function SoonCurve(n, standDown)
    local key = standDown and (-n) or n
    local cached = soonCurves[key]
    if cached then return cached end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
    local curve = C_CurveUtil.CreateColorCurve()
    if curve.SetType and Enum and Enum.LuaCurveType then
        curve:SetType(Enum.LuaCurveType.Step)
    end
    -- Alpha carries the answer.
    local inside, outside = 1, 0
    if standDown then inside, outside = 0, 1 end
    curve:AddPoint(0, CreateColor(1, 1, 1, inside))
    curve:AddPoint(n, CreateColor(1, 1, 1, outside))
    soonCurves[key] = curve
    return curve
end

-- True when it took over the frame's alpha. False means "nothing to measure
-- against", and the caller carries on as it would have: the marker then lights
-- when the aura is actually gone, which is the old behaviour and a fine thing
-- to fall back to. The readable case is not handled here -- there the remaining
-- time is a plain number and the answer belongs in the glow test, not in alpha.
function ns.ApplySoon(frame, rule, durObj)
    local n = ns.SoonSeconds(rule)
    if not n then return false end

    if not (durObj and durObj.EvaluateRemainingDuration) then return false end
    local curve = SoonCurve(n, not rule.missing)
    if not curve then return false end
    local ok, col = pcall(durObj.EvaluateRemainingDuration, durObj, curve)
    if not ok or type(col) ~= "table" or not col.GetRGBA then return false end
    local ok2, _, _, _, a = pcall(col.GetRGBA, col)
    if not ok2 then return false end
    -- a may be secret. It is only ever handed to a setter, never looked at.
    if not pcall(frame.SetAlpha, frame, a) then return false end
    return true
end

-- Returns applied, why
local function ApplyWarnColor(frame, rule, durObj)
    if not rule.warn or rule.warn <= 0 then return false, "warn off" end
    if not durObj then return false, "no duration object" end
    if not durObj.EvaluateRemainingDuration then return false, "no EvaluateRemainingDuration" end
    local curve = WarnCurve(rule)
    if not curve then return false, "no C_CurveUtil colour curve" end
    local ok, col = pcall(durObj.EvaluateRemainingDuration, durObj, curve)
    if not ok then return false, "evaluate failed" end
    if type(col) ~= "table" or not col.GetRGB then return false, "no colour returned" end
    local ok2, r, g, b = pcall(col.GetRGB, col)
    if not ok2 then return false, "GetRGB failed" end
    frame:SetArtColor(r, g, b)
    return true, "ok"
end
ns.DebugWarnColor = function(frame, rule, itemFrame)
    local durObj, why = MirrorDuration(itemFrame, rule)
    if not durObj then return "duration: " .. why end
    local applied, why2 = ApplyWarnColor(frame, rule, durObj)
    return ("duration: %s | warn colour: %s"):format(why, applied and "ok" or why2)
end

local function MirrorTimerText(frame, rule, itemFrame)
    if rule.timer == false or rule.missing or frame.secondary then return false end
    local fs = FindTimerFS(itemFrame)
    if not fs then return false end
    local ok, txt = pcall(fs.GetText, fs)
    if not ok or type(txt) == "nil" then return false end
    if not pcall(frame.TimerText.SetText, frame.TimerText, txt) then return false end
    frame.TimerText:Show()
    return true
end

local function ApplyMirror(frame, rule, itemFrame)
    local flag, ok = MirrorFlag(itemFrame)
    if not ok or not frame.SetAlphaFromBoolean then return false end

    -- Presence rides the alpha gate below, so the timer text is safe to leave
    -- standing: it is invisible exactly when the aura is gone.
    frame.expiresAt = nil
    frame.totalDur = nil
    local durObj = MirrorDuration(itemFrame, rule)
    -- Optional cooldown sweep, driven by the real aura duration object.
    local wantsSweep = ns.WantsSweep(rule)
    local swept = wantsSweep and MirrorCooldown(frame, rule, durObj, itemFrame)
    if not swept then
        if frame.CD:IsShown() then
            frame.CD:Clear()
            frame.CD:Hide()
        end
    end
    -- A time-shaped marker with no time to draw would leave the button blank,
    -- so it degrades to the plain frame instead of disappearing.
    frame.sweepFailed = (wantsSweep and not swept) or nil
    if not MirrorTimerText(frame, rule, itemFrame) then
        frame.TimerText:SetText("")
        frame.TimerText:Hide()
    end
    if not MirrorStackText(frame, rule, itemFrame) then ClearStacks(frame) end

    if not frame:IsShown() then frame:Show() end
    frame.pandemicOn = nil
    -- NOT the restriction-safe style swap: that exists for glows hosted on the
    -- engine's own aura buttons, whose subtree addon code may not drive. This
    -- overlay is our frame on an action button, so the Lua-driven engines run
    -- normally and the chosen look survives -- which matters because auras are
    -- secret globally in 12.1, so the swap would otherwise be permanent.
    frame.needSafeStyle = false
    frame:StartArt()

    -- Recolour towards the warning colour as the aura runs out.
    if not rule.missing and not ApplyWarnColor(frame, rule, durObj) then
        frame:SetArtColor(rule.r or 0, rule.g or 1, rule.b or 0)
    end

    local shown, hidden = 1, 0
    if rule.missing then shown, hidden = 0, 1 end
    -- Counting it gone early, when there is a duration to measure. Two
    -- sources, and neither is a fallback for the other's answer -- only for
    -- its absence. The curve resolves it engine-side where a duration object
    -- exists; where one does not, which is the ordinary case for a debuff on
    -- the target, the widget's plain numbers are compared here. With neither,
    -- the presence gate below still lights the marker once the aura actually
    -- goes: the old behaviour, and a fine thing to land on.
    local soon = ns.SoonSeconds(rule)
    if ns.ApplySoon(frame, rule, durObj) then
        frame._mirroring = true
        if not frame:IsShown() then frame:Show() end
        frame.needSafeStyle = false
        frame:StartArt()
        return true
    elseif soon then
        -- Measured if anything will measure it; estimated when nothing will.
        local left = MirrorRemaining(itemFrame)
        local near = left and left <= soon
        if not left then near = ns.EstimatedNearlyGone(rule, soon) end
        if near then
            -- Read, not resolved: the strip may pack this one for real.
            frame._mirroring = nil
            frame:SetAlpha(rule.missing and 1 or 0)
            if not frame:IsShown() then frame:Show() end
            frame.needSafeStyle = false
            frame:StartArt()
            return true
        end
    end

    local applied = pcall(frame.SetAlphaFromBoolean, frame, flag, shown, hidden)
    frame._mirroring = applied or nil
    if not applied then
        frame:SetAlpha(1)
        return false
    end
    return true
end

ns.auraLatency = setmetatable({}, { __mode = "k" })
ns.castMap = {}

-- Bumped on every cast of a tracked spell: a re-application is the one moment
-- the sweep genuinely has to restart.
local castGen = setmetatable({}, { __mode = "k" })
function ns.CastGen(rule) return castGen[rule] or 0 end

function ns.OnPlayerCast(spellID)
    local rules = ns.castMap[spellID]
    if not rules then return false end
    local now = GetTime()
    local total
    for _, rule in ipairs(rules) do
        optimistic[rule] = now + WINDOW
        castAt[rule] = now
        castGen[rule] = (castGen[rule] or 0) + 1
        total = total or KnownTotal(rule)
    end
    -- The cast is the one thing about this aura that is never secret.
    if total then estExpiry[spellID] = now + total end
    return true
end

function ns.ResetCastState()
    wipe(optimistic)
    wipe(castAt)
end

--[[-------------------------------------------------------------------------
    Third state: the proc

    Nothing to do with auras. The game announces a proc itself -- it is what
    lights Blizzard's own spell alert -- and that answer is plain, never
    secret. So "this spell is procced right now" is the one state of the three
    that is always reliably available.
---------------------------------------------------------------------------]]
local function IsProcced(spellID)
    local SAO = C_SpellActivationOverlay
    if not (SAO and SAO.IsSpellOverlayed and spellID) then return false end
    local ok, v = pcall(SAO.IsSpellOverlayed, spellID)
    if ok and v then return true end
    -- Overrides put a different id on the bar than the one that procs.
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok2, o = pcall(C_Spell.GetOverrideSpell, spellID)
        if ok2 and type(o) == "number" and o ~= spellID then
            local ok3, v3 = pcall(SAO.IsSpellOverlayed, o)
            if ok3 and v3 then return true end
        end
    end
    return false
end
ns.IsProcced = IsProcced

--[[-------------------------------------------------------------------------
    Is this cast free right now?

    Asked of the game, not of a description. GetSpellPowerCost reports the
    CURRENT cost with every modifier applied, so a proc that removes the cost
    shows up as a zero. Nothing to identify, nothing to parse, nothing to keep
    up with patches -- and it is right for every class at once.

    Reading the buff's description was a dead end: it says which spells the
    buff is ABOUT, not which it makes free. Starlord and Starweaver both name
    Starsurge because Starsurge triggers them, and neither makes it free.

    baseCost is what the spell costs when nothing is helping, learned by
    watching: the highest cost ever seen. Without it a spell that simply has no
    cost would read as permanently free. Returns nil when the answer is not
    available -- no cost data, a secret value, no baseline learned yet.
---------------------------------------------------------------------------]]
local function CostsNothing(rule)
    local pt = rule.power or (ns.CG and ns.CG.powerType)
    if pt == nil then return nil end
    if not (C_Spell and C_Spell.GetSpellPowerCost) then return nil end
    local ok, costs = pcall(C_Spell.GetSpellPowerCost, rule.spell)
    if not ok or type(costs) ~= "table" then return nil end

    for _, c in ipairs(costs) do
        if c.type == pt then
            local v = c.cost
            if type(v) ~= "number" or IsSecret(v) then return nil end
            -- Self-calibrating: talents move base costs around, and the
            -- highest reading is the one with no proc behind it.
            if v > (rule.baseCost or 0) then rule.baseCost = v end
            if not (rule.baseCost and rule.baseCost > 0) then return nil end
            return v == 0
        end
    end
    -- No entry for this resource at all. That is "free" only if the spell is
    -- known to cost something normally; otherwise it never did.
    if rule.baseCost and rule.baseCost > 0 then return true end
    return nil
end
ns.CostsNothing = CostsNothing

-- Which spells currently have their "proc" state lit. Written by the aura
-- pass, read by the power pass so a free cast can outrank a full bar.
--
-- Only PLAIN evidence is ever recorded here. The mirror resolves visibility
-- engine-side and ApplyAuraRule returns true for it whether the aura is up or
-- not; taking that as "the proc is on" would silence the resource marker for
-- the rest of the session. Unknown means "do not suppress" -- both markers is
-- a worse display than one, but a marker that never comes back is a bug.
ns.procActive = {}
ns.procDirty = false

local function SetProcActive(spellID, on)
    if not spellID then return end
    local v = (on and true) or nil
    if ns.procActive[spellID] ~= v then
        ns.procActive[spellID] = v
        ns.procDirty = true
    end
end

-- Applies one aura rule to one overlay/icon. Returns true if it is showing.
function ns.ApplyAuraRule(frame, rule)
    -- A proc pointed at a buff is just an aura rule: "this buff is on me".
    -- Only an unpointed one falls back to the game's own spell alert.
    if rule.proc then
        -- The cost answers it outright when it can. Any buffs the state holds
        -- then only say how long the free window lasts.
        local free = CostsNothing(rule)
        if free == nil and not HasExplicitAura(rule) then
            free = IsProcced(rule.spell)
        end

        if free ~= nil then
            frame.pandemicOn = nil
            ns.ResetMirror(frame)
            SetProcActive(rule.spell, free)
            if not free then
                ClearTimer(frame)
                ClearStacks(frame)
                frame:StopArt()
                frame:Hide()
                return false
            end
            if HasExplicitAura(rule) and rule.timer ~= false then
                local f, rem, tot, d, a = ns.QueryAura(rule)
                if f == true then
                    ShowTimer(frame, rule, rem, tot, d)
                    ShowStacks(frame, rule, a)
                else
                    ClearTimer(frame)
                    ClearStacks(frame)
                end
            else
                ClearTimer(frame)
            end
            if not frame:IsShown() then frame:Show() end
            frame.needSafeStyle = false
            frame:StartArt()
            return true
        end
        -- Cost said nothing and there are buffs to watch: the generic path
        -- below treats them as an ordinary "this aura is on me" rule.
    end

    local found, remaining, total, durObj, apps = ns.QueryAura(rule)
    local now = GetTime()

    -- A confirmed reading always wins over the optimistic guess.
    if found == true then
        if castAt[rule] then
            ns.auraLatency[rule] = now - castAt[rule]
            castAt[rule] = nil
        end
        readsWork[rule] = true
        misses[rule] = nil
        optimistic[rule] = nil
        if total then
            lastTotals[rule] = total
            LearnTotal(rule, total)
        end
    end

    local optUntil = optimistic[rule]
    local optActive = optUntil ~= nil and now < optUntil
    if optUntil and not optActive then
        optimistic[rule] = nil
        if castAt[rule] then
            castAt[rule] = nil
            -- The cast went through but nothing ever read back. One of those
            -- is a miss or an immunity; twice in a row is the API.
            -- Only worth saying when there is no mirror to fall back on:
            -- with one, the rule works and the message would be noise.
            local mf, isAuraEntry = ns.FindMirror(rule)
            if not readsWork[rule] and not (mf and isAuraEntry) then
                misses[rule] = (misses[rule] or 0) + 1
                if misses[rule] >= 2 then ReportUnreadable(rule) end
            end
        end
    end

    -- The read did not find it: hand this pass to the engine's own tracker.
    --
    -- Deliberately NOT gated on "reads have never worked for this rule": a read
    -- that succeeded once says nothing about now. Aura visibility flips with
    -- the situation, so one lucky read used to latch the rule onto the direct
    -- path for the rest of the session and the marker then vanished every time
    -- the read came back empty.
    if found ~= true and ns.mirrorEnabled then
        local itemFrame, isAuraEntry = ns.FindMirror(rule)
        if itemFrame and isAuraEntry and ApplyMirror(frame, rule, itemFrame) then
            -- The engine owns this one now; we cannot say whether it is on.
            if rule.proc then SetProcActive(rule.spell, nil) end
            return true
        end
    end
    if frame._mirroring then
        frame._mirroring = nil
        frame:SetAlpha(1)
    end

    local present = (found == true) or optActive
    -- The readable half of the shared boundary. Where the time comes back as a
    -- plain number the comparison happens here rather than in a curve, and the
    -- "up" state has to stand down in the same window the "gone" state lights
    -- in -- otherwise both are on at once, saying opposite things.
    if present and not rule.missing then
        local soon = ns.SoonSeconds(rule)
        if soon and found == true and type(remaining) == "number"
           and not IsSecret(remaining) and remaining <= soon then
            present = false
        end
    end
    if rule.proc then SetProcActive(rule.spell, found == true) end
    -- The count has its own source. A read can hand back the aura and still
    -- withhold "applications" -- the field is secret often enough -- and the
    -- Cooldown Manager draws the number regardless, so its text is copied when
    -- ours came back empty. Presence and count are answered separately.
    if found ~= true then
        ClearStacks(frame)
    elseif type(apps) == "number" then
        ShowStacks(frame, rule, apps)
    else
        local mf, isAuraEntry = ns.FindMirror(rule)
        if not (mf and isAuraEntry and MirrorStackText(frame, rule, mf)) then
            ClearStacks(frame)
        end
    end

    -- The timer is independent of the glow. While the aura is up you want to
    -- see the time left even in "glow when missing" mode -- there the icon
    -- carries a quiet countdown and only lights up once it runs out.
    if present and rule.timer ~= false then
        if found == true then
            frame._optStamp = nil
            ShowTimer(frame, rule, remaining, total, durObj)
        elseif frame._optStamp ~= optUntil then
            -- Unconfirmed: run the previous known duration for this rule, if
            -- one was ever seen. Set once per cast so polling cannot restart it.
            frame._optStamp = optUntil
            local guess = lastTotals[rule]
            ShowTimer(frame, rule, guess, guess, nil)
        end
    else
        frame._optStamp = nil
        ClearTimer(frame)
    end

    local glow
    if rule.missing then
        -- Only claim "it is missing" on positive evidence. The API mostly
        -- answers "nothing here" rather than erroring when it simply will not
        -- tell us, so `found == false` alone is not proof of absence -- and
        -- for a dot, which can never be read, it was permanently true, leaving
        -- the red mark burning on top of the green one for the whole fight.
        -- Reads must have worked for this rule at least once; otherwise the
        -- mirror above owns this state, or nothing does.
        glow = (found == false) and not optActive and readsWork[rule] == true
        -- Counted gone early: still up, but not for long. Only where the time
        -- can actually be read; where it cannot, the curve above did it.
        local soon = ns.SoonSeconds(rule)
        if not glow and soon and found == true
           and type(remaining) == "number" and not IsSecret(remaining)
           and remaining <= soon then
            glow = true
        end
        if glow and rule.unit ~= "player"
           and not UnitCanAttack("player", rule.unit or "target") then
            glow = false   -- do not nag about something you cannot hit
        end
    else
        glow = present
    end

    -- Shown for the glow OR for a bare countdown.
    if not (glow or frame.expiresAt or frame.CD:IsShown()) then
        frame.pandemicOn = nil
        frame:StopArt()
        frame:Hide()
        return false
    end
    if not frame:IsShown() then frame:Show() end

    if not glow then
        frame.pandemicOn = nil
        frame:StopArt()
        return true
    end

    -- Colour swap for the pandemic window; only restyle on the edge so the
    -- glow animation is not restarted every tick.
    local pand = (not rule.missing) and InPandemic(rule, frame) or false
    if frame.pandemicOn ~= pand then
        frame.pandemicOn = pand
        if pand then
            frame:SetStyle(rule.style, rule.wr or 1, rule.wg or 0, rule.wb or 0, rule.alpha, rule.thick)
        else
            frame:SetStyle(rule.style, rule.r, rule.g, rule.b, rule.alpha, rule.thick)
        end
    end

    frame.needSafeStyle = false
    frame:StartArt()
    return true
end

--[[-------------------------------------------------------------------------
    Text ticker: one shared OnUpdate for every visible aura timer
---------------------------------------------------------------------------]]
local ticker = CreateFrame("Frame")
local textAcc, pollAcc = 0, 0
local tracked = {}
ns.auraTicker = tracked

-- Polling exists because the aura event can arrive late (and, by the user's
-- report, sometimes only when the target is re-selected). Re-reading on a
-- fixed interval makes the display as fast as the DATA allows instead of as
-- fast as the event. Core sets both fields.
ns.pollInterval = 0.2
ns.PollCallback = nil

ticker:Hide()
ticker:SetScript("OnUpdate", function(_, elapsed)
    if ns.PollCallback and ns.pollInterval and ns.pollInterval > 0 then
        pollAcc = pollAcc + elapsed
        if pollAcc >= ns.pollInterval then
            pollAcc = 0
            ns.PollCallback()
        end
    end

    textAcc = textAcc + elapsed
    if textAcc < 0.1 then return end
    textAcc = 0
    local now = GetTime()
    for frame in pairs(tracked) do
        if frame:IsShown() and frame.expiresAt then
            local left = frame.expiresAt - now
            if frame.TimerText:IsShown() then
                frame.TimerText:SetText(left > 0 and FormatTime(left) or "")
            end
            -- A ticking DoT fires no aura event, so the pandemic edge has to
            -- be watched here rather than only on UNIT_AURA.
            local rule = frame.rule
            if rule and not rule.missing then
                local pand = InPandemic(rule, frame)
                if frame.pandemicOn ~= pand then
                    frame.pandemicOn = pand
                    if pand then
                        frame:SetStyle(rule.style, rule.wr or 1, rule.wg or 0, rule.wb or 0, rule.alpha, rule.thick)
                    else
                        frame:SetStyle(rule.style, rule.r, rule.g, rule.b, rule.alpha, rule.thick)
                    end
                end
            end
        end
    end
end)

function ArmTicker()
    ticker:Show()
end

function ns.TrackAuraFrame(frame)
    tracked[frame] = true
    ticker:Show()
end

function ns.UntrackAuraFrames()
    wipe(tracked)
    ticker:Hide()
    wipe(ns.castMap)
    -- Deliberately NOT ResetCastState(): a rebuild (an action bar slot
    -- changing, a form swap) must not throw away an in-flight cast, or the
    -- display drops back to "no aura" the moment you press the next button.
end

--[[-------------------------------------------------------------------------
    Diagnostic: /cg auracheck
    Prints what the API actually answers here, so restricted content can be
    diagnosed from a report instead of guessed at.
---------------------------------------------------------------------------]]
function ns.AuraCheck(rules, say)
    say("--- aura check ---")
    say("C_UnitAuras: %s | GetAuraDataBySpellName: %s | GetAuraDuration: %s",
        tostring(UA ~= nil),
        tostring(UA and UA.GetAuraDataBySpellName ~= nil),
        tostring(UA and UA.GetAuraDuration ~= nil))
    local restricted = "n/a"
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        restricted = tostring(C_Secrets.ShouldAurasBeSecret())
    end
    say("ShouldAurasBeSecret: %s | target: %s", restricted,
        UnitExists("target") and (UnitName("target") or "?") or "none")

    local n, blind = 0, {}
    for i, rule in ipairs(rules) do
        if rule.kind == "aura" then
            n = n + 1
            local name = ns.SpellName(rule.spell)
            local secretForSpell = "n/a"
            if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
                local ok, v = pcall(C_Secrets.ShouldSpellAuraBeSecret, rule.auraID or rule.spell)
                secretForSpell = ok and tostring(v) or "err"
            end
            -- The precise answer, where the client has it: a level rather than
            -- a yes/no, and "NeverSecret" means the direct read can be trusted
            -- instead of being tried and measured.
            if C_Secrets and C_Secrets.GetSpellAuraSecrecy then
                local okS, lvl = pcall(C_Secrets.GetSpellAuraSecrecy,
                                       rule.auraID or rule.spell)
                if okS then
                    local nameOf = tostring(lvl)
                    if type(Enum) == "table" and type(Enum.SecrecyLevel) == "table" then
                        for k, v in pairs(Enum.SecrecyLevel) do
                            if v == lvl then nameOf = k break end
                        end
                    end
                    secretForSpell = secretForSpell .. "/" .. nameOf
                end
            end
            local found, remaining, total, durObj = ns.QueryAura(rule)
            local lat = ns.auraLatency[rule]
            say("%d. %s [%s] -> found=%s remain=%s total=%s durObj=%s spellSecret=%s lag=%s reads=%s",
                i, name, rule.unit or "target",
                tostring(found),
                remaining and ("%.1f"):format(remaining) or "nil",
                total and ("%.1f"):format(total) or "nil",
                tostring(durObj ~= nil), secretForSpell,
                lat and ("%d ms"):format(lat * 1000) or "-",
                ns.ReadsWork(rule) and "ok" or "never")
            local mf, isAuraEntry = ns.FindMirror(rule)
            if mf then
                local _, usable = MirrorFlag(mf)
                say("     cdm mirror: %s | viewer=%s | IsActive=%s | usable=%s",
                    isAuraEntry and "aura entry" or "|cffff4040cooldown entry|r",
                    tostring(ns.cdmViewerOf and ns.cdmViewerOf[mf] or "?"),
                    tostring(mf.IsActive ~= nil),
                    tostring(isAuraEntry and usable or false))
                say("     aura link: auraDataUnit=%s auraInstanceID=%s | %s",
                    tostring(type(mf.auraDataUnit) ~= "nil"),
                    tostring(type(mf.auraInstanceID) ~= "nil"),
                    ns.DebugWarnColor(nil, rule, mf))
                say("     " .. ns.SoonReport(mf, rule))
            else
                blind[#blind + 1] = name
                say("     cdm mirror: |cffff4040none|r%s", ns.L(
                    " - track this spell in the Cooldown Manager to enable the fallback",
                    " — добавь заклинание в Cooldown Manager, чтобы заработал запасной путь"))
            end
        end
    end
    if n == 0 then say("no aura rules on this spec") end

    -- The single most useful line in this report. A target debuff cannot be
    -- read directly in 12.1, so a spell the Cooldown Manager does not track is
    -- one nothing can see -- and its tracked list is configured per
    -- SPECIALIZATION, which is why the same character can work as one spec and
    -- be blind as another.
    if #blind > 0 then
        say(ns.L("|cffff4040%d of %d have no fallback:|r %s",
                 "|cffff4040без запасного пути: %d из %d|r — %s"),
            #blind, n, table.concat(blind, ", "))
        say(ns.L("add them under Options - Cooldown Manager for THIS spec",
                 "добавь их в Настройки — Cooldown Manager для ЭТОЙ специализации"))
    end
end

-- Hooked as early as the client allows; the lazy path retries if this is
-- too early for the action bars to exist yet.
HookCooldownDurations()
