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

-- A duration object is USERDATA on 12.1, not a table.
--
-- Every check in here used to say "table" and therefore threw away every real
-- one. Out of combat nothing noticed: a plain remaining time answered instead,
-- and the object was never needed. In combat there is no plain anything, so
-- the entire mirrored path went dark and looked like a missing API.
local function IsObject(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end
ns.IsObject = IsObject

-- Indexing userdata goes through a metatable and can throw, so it is asked
-- for rather than looked up.
local function HasMethod(v, name)
    if not IsObject(v) then return false end
    local ok, m = pcall(function() return v[name] end)
    return ok and m ~= nil
end
ns.HasMethod = HasMethod

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
        if ok2 and IsObject(d) then durObj = d end
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


-- When the player's own cast says this aura should run out, per spell.


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
        if ok and IsObject(durObj) then return durObj, "ok" end
    end

    local fallbackUnit = rule and rule.unit or "target"
    local ok, durObj = pcall(UA.GetAuraDuration, fallbackUnit, iid)
    if ok and IsObject(durObj) then return durObj, "ok (rule unit)" end

    -- Caught on its way into the widget. In combat this is the only one there
    -- is, and it is the very object drawing the countdown on screen.
    local caught = ns.CaughtDuration(itemFrame)
    if caught then return caught, "ok (caught)" end

    -- A duration object built by C_DurationUtil.CreateDuration used to be
    -- tried here. It is not any more: whatever that factory returns, it is a
    -- LENGTH and not a running clock -- every argument order and every unit
    -- answers "nothing left" at any threshold, which is what made every dot
    -- light permanently. /cgl mkdur still shows the whole table.

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


--[[-------------------------------------------------------------------------
    Pass-through arming

    A secret survives being handed from one API to another and does not
    survive being kept. Stored in a table it comes back as something
    SetCooldown will not take -- "bad argument #2" -- so the copy we were
    holding was never going to work, whatever we did with it afterwards.

    So nothing is held. A widget of ours registers as a mirror of one of the
    game's, and when the game arms that one the same arguments are passed
    straight on, inside the hook, while they are still live arguments and not
    yet anybody's variable.

    From then on our widget is running the real duration -- and a formatter on
    it can be asked "is this nearly over" and will draw the answer, which is
    the only way anyone gets to know in combat.
---------------------------------------------------------------------------]]

-- Counters, because "the box did not move" has three causes that look the
-- same: nobody subscribed, nobody armed, or the forwarded call threw and the
-- pcall ate it.

-- How many times the game has armed each widget. Re-arming is when other
-- cooldown-text addons re-apply their own formatter, so it is also when ours
-- has to be put back.
local armCount = setmetatable({}, { __mode = "k" })


--[[-------------------------------------------------------------------------
    Asking the engine to mark the last seconds, on its own widget

    We may not arm a cooldown of ours with a secret time -- that is refused
    outright. But nothing stops us formatting a cooldown the engine armed
    ITSELF, and a numeric rule formatter is a set of thresholds the engine
    evaluates against its own secret remaining time, drawing whichever format
    string matches. The colour lives inside the string.

    So the answer arrives as text, on the Cooldown Manager's own entry -- and
    that text is already copied onto our marker every poll. The digits go the
    warning colour for the last N seconds, exactly on time, in combat, and
    through any extension, because the engine is reading the real clock and we
    never see a number at any point.

    This is tullaCTC's trick used on somebody else's widget, which is also
    where tullaCTC uses it. Both of us setting a formatter on the same cooldown
    means last writer wins, so ours goes back after every re-arming -- and only
    on entries we actually track.
---------------------------------------------------------------------------]]
local entryFmtStamp = setmetatable({}, { __mode = "k" })

local function Hex(r, g, b)
    return ("|cff%02x%02x%02x"):format(
        math.floor((r or 1) * 255 + 0.5),
        math.floor((g or 0) * 255 + 0.5),
        math.floor((b or 0) * 255 + 0.5))
end

-- Formatters are built once per look and kept. Rebuilding one per poll, per
-- entry, was most of a frame's work on its own.
local formatterCache = {}
local entryFmtAt = setmetatable({}, { __mode = "k" })

local function GetFormatter(n, colour)
    local key = n .. colour
    local cached = formatterCache[key]
    if cached ~= nil then return cached or nil end
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
            and Enum and Enum.NumericRuleFormatRounding) then
        formatterCache[key] = false
        return nil
    end
    local rounding = Enum.NumericRuleFormatRounding.Nearest
    local formatter = C_StringUtil.CreateNumericRuleFormatter()
    local ok = pcall(formatter.SetBreakpoints, formatter, {
        -- Below the threshold: the warning colour, and tenths.
        --
        -- The size cannot follow the threshold -- size belongs to the font
        -- string and the engine hands us an answer as text, where colour and
        -- format fit and a point size does not. A number that starts moving
        -- ten times a second reads as urgent in the same way, and it is the
        -- engine deciding when, off the real clock.
        { threshold = 0, format = colour .. "%.1f|r", step = 0.1, rounding = rounding },
        { threshold = n, format = "%d", step = 1, rounding = rounding },
        { threshold = 60, format = "%dm", step = 1, rounding = rounding,
          components = { { div = 60, rounding = rounding, step = 1 } } },
    })
    if not ok then
        formatterCache[key] = false
        return nil
    end
    formatterCache[key] = formatter
    return formatter
end

-- Only the "gone" rule installs it. Both states of a spell share one entry, so
-- doing it from either is enough -- and the "gone" rule holds the threshold
-- itself, which spares the sibling lookup on every poll of every frame.
function ns.ApplyEntryFormatter(itemFrame, rule)
    -- OFF unless asked for.
    --
    -- This sets a formatter on Blizzard's own Cooldown Manager entries, and
    -- the hook it needs sits on the shared Cooldown metatable -- both are
    -- insecure code touching frames the secure path owns. With them on, chat
    -- stopped accepting Enter: the edit box kept the text and nothing
    -- happened, with no error and nothing pointing here. Taint surfaces far
    -- from its cause, which is exactly why the rest of this addon stays off
    -- that path.
    --
    -- It is worth keeping as an opt-in, because it is the only way to get an
    -- honest "about to fall off" during a fight. It is not worth being on by
    -- default at that price.
    if not ns.entryFormat or not rule.missing then return false end
    if not ns.HookCooldownDurations() then return false end
    local n = tonumber(rule.soon) or 0
    if n <= 0 then return false end
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    if not (cd and cd.SetCountdownFormatter) then return false end

    -- Re-applied when the look changes or the entry was re-armed, since that
    -- is when another cooldown-text addon puts its own back. Never more than
    -- twice a second: re-arming can happen many times in one.
    local colour = Hex(rule.wr or 1, rule.wg or 0.2, rule.wb or 0.2)
    local stamp = ("%s|%s|%s"):format(n, armCount[cd] or 0, colour)
    if entryFmtStamp[cd] == stamp then return true end
    local now = GetTime()
    if (entryFmtAt[cd] or 0) + 0.5 > now then return true end

    local formatter = GetFormatter(n, colour)
    if not formatter then return false end
    if not pcall(cd.SetCountdownFormatter, cd, formatter) then return false end
    entryFmtStamp[cd] = stamp
    entryFmtAt[cd] = now
    return true
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
    end)
    for _, m in ipairs(STALE_ON) do
        if proto[m] then
            hooksecurefunc(proto, m, function(cd)
                caughtDuration[cd] = nil
                -- Re-arming is when other cooldown-text addons put their own
                -- formatter back, so it is when ours has to go back too.
                if m == "SetCooldown" then
                    armCount[cd] = (armCount[cd] or 0) + 1
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

local function UsableDuration(d)
    return HasMethod(d, "EvaluateRemainingDuration")
end


function ns.CaughtDuration(itemFrame)
    HookCooldownDurations()
    local cd = itemFrame and (itemFrame.Cooldown or itemFrame.cooldown)
    local d = cd and caughtDuration[cd]
    if UsableDuration(d) then return d end
    return nil
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
    local x = rule.warn or 0
    local sig = ("%s|%s|%s|%s|%s|%s|%s"):format(x,
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
    curve:AddPoint(x, CreateColor(rule.r or 0, rule.g or 1, rule.b or 0, 1))    warnCurves[rule] = { sig = sig, curve = curve }
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


-- Returns applied, why
local function ApplyWarnColor(frame, rule, durObj)
    if not rule.warn or rule.warn <= 0 then return false, "warn off" end
    if not durObj then return false, "no duration object" end
    if not durObj.EvaluateRemainingDuration then return false, "no EvaluateRemainingDuration" end
    local curve = WarnCurve(rule)
    if not curve then return false, "no C_CurveUtil colour curve" end
    local ok, col = pcall(durObj.EvaluateRemainingDuration, durObj, curve)
    if not ok then return false, "evaluate failed" end
    if not HasMethod(col, "GetRGB") then return false, "no colour returned" end
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

-- allowMissing: a "gone" icon normally carries no countdown, because there is
-- nothing to count. In the early window there is -- the aura is still up, we
-- have simply decided to stop calling it that -- and the number is the reason
-- to look. The frame says "refresh this", the digits say how long you have.
-- Once the aura really goes the entry's own text goes with it, so this needs
-- no unwinding: it empties itself.
local function MirrorTimerText(frame, rule, itemFrame, allowMissing)
    if rule.timer == false or frame.secondary then return false end
    if rule.missing and not allowMissing then return false end
    local fs = FindTimerFS(itemFrame)
    if not fs then return false end
    local ok, txt = pcall(fs.GetText, fs)
    if not ok or type(txt) == "nil" then return false end
    if not pcall(frame.TimerText.SetText, frame.TimerText, txt) then return false end
    frame.TimerText:Show()
    return true
end

--[[-------------------------------------------------------------------------
    A stronger version of the same aura

    Feral empowers Rake and Rip while Tiger's Fury is up, and the empowerment
    lasts the dot's whole duration -- but the button reverts the moment the
    buff does. So a stronger dot gets overwritten with a weaker one and nothing
    on screen says a word about it.

    What is on the target cannot be read. The Cooldown Manager keeps tracking
    the empowered version though, and it draws the empowered ICON while doing
    it -- and a texture id is an ordinary number, not a secret. So the question
    "is the thing up the strong one" is answered by comparing what the entry
    draws against the spell's own icon.

    Nothing here is Feral-specific: any aura whose empowered form carries its
    own art answers the same way, and one whose form does not simply never
    reports empowered.
---------------------------------------------------------------------------]]
local baseIcon = {}

-- The entry's icon texture, found once and kept.
--
-- It is not always under .Icon, and the entry carries border and highlight
-- textures too. The icon is the one drawing a file ID: art set by number
-- rather than by path or atlas, which is how a spell icon is set and how the
-- others are not.
local iconOf = setmetatable({}, { __mode = "k" })

local function EntryIcon(itemFrame)
    local cached = iconOf[itemFrame]
    if cached ~= nil then return cached or nil end
    local found = false

    -- The numeric one first, and only then the named field. A file ID is how
    -- a spell icon is set; borders and highlights are set by path or atlas,
    -- and one of those can perfectly well be sitting under .Icon.
    pcall(function()
        for _, r in ipairs({ itemFrame:GetRegions() }) do
            if r.GetTexture and r.GetObjectType and r:GetObjectType() == "Texture" then
                local ok, tex = pcall(r.GetTexture, r)
                if ok and type(tex) == "number" then
                    found = r
                    return
                end
            end
        end
    end)
    if not found then
        for _, key in ipairs({ "Icon", "icon" }) do
            local t = itemFrame[key]
            if t and t.GetTexture then
                found = t
                break
            end
        end
    end

    iconOf[itemFrame] = found
    return found or nil
end

-- Was the last cast of this spell an empowered one?
--
-- On a target debuff the entry's icon comes back SECRET, so the reading above
-- answers nothing there -- which is the whole 12.1 story again: anything
-- derived from an aura on someone else is closed.
--
-- What is not closed is the override. While Tiger's Fury is up, Rake and Rip
-- are overridden by their empowered forms -- that is why the button art
-- changes -- and GetOverrideSpell is an ordinary call. So the question moves
-- from "what is on the target" to "what did I cast", which is answerable, and
-- is the same answer for as long as nobody recasts.
--
-- It says the last application was empowered, not that it is still up. Those
-- differ only when the dot has expired unnoticed, and the "gone" marker is
-- lit by then anyway.
local empoweredCast = {}

-- For the report: what a cast recorded, if anything.
function ns.CastEmpowerment(spellID)
    return empoweredCast[spellID]
end

--[[-------------------------------------------------------------------------
    Reading the empowerment off the spell's own icon

    GetOverrideSpell says nothing about these -- it answers "same" with Tiger's
    Fury up -- but GetSpellInfo quietly follows the override anyway: Rake reads
    as icon 7195159 while the buff is up and 132122 while it is not. Plain
    numbers, no aura involved, so this is a fact we are allowed to have.

    It describes the CAST, not the target, which is the right question anyway:
    what is on the target cannot be known, but what we sent at it can, and it
    stays true until we send something weaker.

    The base icon has to be learned when nothing is empowering it, so it is
    only ever recorded OUT OF COMBAT. Learning it lazily was the bug that made
    this look dead: first asked mid-fight with the buff up, the empowered icon
    became the baseline and nothing ever differed from it again.
---------------------------------------------------------------------------]]
local function CurrentIcon(spellID)
    if not (C_Spell and C_Spell.GetSpellInfo and spellID) then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if not ok or type(info) ~= "table" then return nil end
    local icon = info.iconID
    if type(icon) ~= "number" or IsSecret(icon) then return nil end
    return icon
end

function ns.LearnBaseIcons(rules)
    if InCombatLockdown and InCombatLockdown() then return end
    for _, rule in ipairs(rules or {}) do
        if rule.spell then
            local icon = CurrentIcon(rule.spell)
            if icon then baseIcon[rule.spell] = icon end
        end
    end
end

function ns.NoteCastEmpowerment(spellID)
    if not spellID then return end
    local icon = CurrentIcon(spellID)
    local base = baseIcon[spellID]
    if icon and base then
        empoweredCast[spellID] = (icon ~= base) or nil
    end
end

local function EntryEmpowered(itemFrame, rule)
    if not (rule and rule.spell) or rule.empowered == false then return false end

    -- Read it off the entry where the entry will say. Player auras do.
    local want = baseIcon[rule.spell]
    if want == nil then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(rule.spell)
        want = (info and info.iconID) or false
        baseIcon[rule.spell] = want
    end
    local t = want and itemFrame and EntryIcon(itemFrame)
    if t then
        local ok, tex = pcall(t.GetTexture, t)
        if ok and type(tex) == "number" and not IsSecret(tex) then
            return tex ~= want
        end
    end

    -- Otherwise go by what we cast.
    return empoweredCast[rule.spell] == true
end
ns.EntryEmpowered = EntryEmpowered
local function ApplyMirror(frame, rule, itemFrame)
    local flag, ok = MirrorFlag(itemFrame)
    if not ok or not frame.SetAlphaFromBoolean then return false end

    -- Presence rides the alpha gate below, so the timer text is safe to leave
    -- standing: it is invisible exactly when the aura is gone.
    frame.expiresAt = nil
    frame.totalDur = nil
    -- Everywhere, not just the strip. Confining it to the strip was a fix for
    -- the wrong problem: what was lost on the button was the countdown, not
    -- the state, and the countdown is back now.
    -- Read straight off the rule: SoonSeconds walks the rule list to find a
    -- sibling, which is far too much for something asked five times a second
    -- for every frame.
    local soon = rule.missing and (tonumber(rule.soon) or 0) > 0 or nil
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
    -- Ask the engine to mark the last seconds in the text we are about to copy.
    ns.ApplyEntryFormatter(itemFrame, rule)
    if not MirrorTimerText(frame, rule, itemFrame, soon ~= nil) then
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
    -- Recolour towards the warning colour as the aura runs out; and if what is
    -- up is the empowered version, say so instead. That one outranks the
    -- countdown: "do not overwrite this" matters more than "it is running out",
    -- and the timer is on the icon anyway.
    if not rule.missing then
        if EntryEmpowered(itemFrame, rule) then
            frame:SetArtColor(rule.er or 0.7, rule.eg or 0.4, rule.eb or 1)
        elseif not ApplyWarnColor(frame, rule, durObj) then
            frame:SetArtColor(rule.r or 0, rule.g or 1, rule.b or 0)
        end
    end

    local shown, hidden = 1, 0
    if rule.missing then shown, hidden = 0, 1 end

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
    -- Noted BEFORE the early return below. When a spell is cast in its
    -- empowered form the event arrives under the OVERRIDE's id, which no
    -- rule is keyed to -- so the one cast that mattered was the one cast
    -- this function skipped.
    ns.NoteCastEmpowerment(spellID)

    local rules = ns.castMap[spellID]
    if not rules then return false end
    local now = GetTime()
    for _, rule in ipairs(rules) do
        optimistic[rule] = now + WINDOW
        castAt[rule] = now
        castGen[rule] = (castGen[rule] or 0) + 1
    end
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
        if total then lastTotals[rule] = total end
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
-- What icon each tracked entry is showing right now.
--
-- Feral's Tiger's Fury empowers a dot for its whole duration, and the button
-- forgets the moment the buff ends -- but if the empowered aura carries its own
-- icon, the Cooldown Manager entry keeps showing it for as long as the dot is
-- up. A texture id is an ordinary value, so that would be an answer about the
-- target we are otherwise not allowed to have.
--
-- This only finds out whether the icon changes. Nothing is built on it yet.
function ns.IconProbe(rules, say)
    say(ns.L("--- entry icons (%d rules) ---", "--- иконки записей (правил: %d) ---"),
        #rules)
    local seen = {}
    for _, rule in ipairs(rules) do
        if rule.kind == "aura" and not rule.proc and rule.spell and not seen[rule.spell] then
            seen[rule.spell] = true
            local name = ns.SpellName and ns.SpellName(rule.spell) or rule.spell
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(rule.spell)
            local base = info and info.iconID or "?"

            local override = "-"
            if C_Spell and C_Spell.GetOverrideSpell then
                local ok, o = pcall(C_Spell.GetOverrideSpell, rule.spell)
                if ok and type(o) == "number" and o ~= rule.spell then
                    local oi = C_Spell.GetSpellInfo(o)
                    override = ("%d icon %s"):format(o, oi and oi.iconID or "?")
                end
            end

            -- Whatever textures the entry is drawing, by file id.
            local shown = {}
            local mf, isAura = ns.FindMirror(rule)
            if mf and isAura then
                for _, key in ipairs({ "Icon", "icon", "Texture", "texture" }) do
                    local t = mf[key]
                    if t and t.GetTexture then
                        local ok, tex = pcall(t.GetTexture, t)
                        if ok and tex ~= nil then
                            shown[#shown + 1] = ("%s=%s"):format(key,
                                IsSecret(tex) and "secret" or tostring(tex))
                        end
                    end
                end
                if #shown == 0 then
                    local ok = pcall(function()
                        for _, r in ipairs({ mf:GetRegions() }) do
                            if r.GetTexture and r.GetObjectType and r:GetObjectType() == "Texture" then
                                local ok2, tex = pcall(r.GetTexture, r)
                                if ok2 and tex ~= nil then
                                    shown[#shown + 1] = IsSecret(tex) and "secret"
                                        or tostring(tex)
                                end
                            end
                        end
                    end)
                    if not ok then shown[#shown + 1] = "<regions blocked>" end
                end
            end

            local ok = pcall(say, "%s: spell icon %s | override %s | entry %s",
                name, tostring(base), override,
                #shown > 0 and table.concat(shown, ", ") or "no mirror")
            if not ok then say("%s: report failed", tostring(name)) end
    end
end
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
                -- What the entry is drawing, and whether that makes it the
                -- empowered version of the aura.
                local t = EntryIcon(mf)
                local drawn = "no texture found"
                if t then
                    local okt, tex = pcall(t.GetTexture, t)
                    drawn = (not okt) and "err"
                        or (tex == nil and "nil"
                            or (IsSecret(tex) and "secret" or tostring(tex)))
                end
                local info = C_Spell and C_Spell.GetSpellInfo
                    and C_Spell.GetSpellInfo(rule.spell)
                -- What the override answers right now, and what a cast of this
                -- spell last recorded. Between them: whether the empowered
                -- form is visible to us at all, and whether we ever saw it go.
                local ovr = "-"
                if C_Spell and C_Spell.GetOverrideSpell then
                    local oko, o = pcall(C_Spell.GetOverrideSpell, rule.spell)
                    if oko and type(o) == "number" then
                        ovr = (o == rule.spell) and "same" or tostring(o)
                    elseif oko then
                        ovr = type(o)
                    else
                        ovr = "err"
                    end
                end
                say("     icon: spell %s | entry %s | empowered=%s | override=%s | noted=%s",
                    tostring(info and info.iconID or "?"), drawn,
                    tostring(EntryEmpowered(mf, rule)), ovr,
                    tostring(ns.CastEmpowerment(rule.spell)))
                say("     aura link: auraDataUnit=%s auraInstanceID=%s | %s",
                    tostring(type(mf.auraDataUnit) ~= "nil"),
                    tostring(type(mf.auraInstanceID) ~= "nil"),
                    ns.DebugWarnColor(nil, rule, mf))
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

