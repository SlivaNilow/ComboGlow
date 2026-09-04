--[[---------------------------------------------------------------------------
    ComboGlow - Core.lua

    Watches the player's class resource (combo points, holy power, chi, soul
    shards, arcane charges, essence, ...) and glows the action buttons that
    hold the spells you configured for that count. Optionally mirrors them as
    icons in the middle of the screen.

    Rules are stored per specialization, per character.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...

local IsSecret = ns.IsSecret

local CG = CreateFrame("Frame", "ComboGlowCore", UIParent)
ns.CG = CG
_G.ComboGlow = CG

CG.specID = 0
CG.powerType = nil

--[[-------------------------------------------------------------------------
    Power types
---------------------------------------------------------------------------]]
local PT = Enum.PowerType

-- A hint, not the answer: every one of these is wrong for at least one spec of
-- its own class, which is why the detection below has the last word.
local CLASS_POWER = {
    ROGUE       = PT.ComboPoints,
    DRUID       = PT.ComboPoints,   -- cat form; Balance is astral power
    PALADIN     = PT.HolyPower,
    MONK        = PT.Chi,           -- Windwalker; Brewmaster and Mistweaver have none
    WARLOCK     = PT.SoulShards,
    MAGE        = PT.ArcaneCharges, -- Arcane only
    EVOKER      = PT.Essence,
    DEATHKNIGHT = PT.Runes,
    PRIEST      = PT.Insanity,      -- Shadow only
    SHAMAN      = PT.Maelstrom,     -- Elemental
}

-- Aliases accepted by "/cg power". Built defensively: an Enum key that does
-- not exist on this client is simply skipped.
ns.POWER_ALIASES = {}
do
    local pairsList = {
        { "combo",      PT.ComboPoints   }, { "cp",      PT.ComboPoints   },
        { "kp",         PT.ComboPoints   }, { "holy",    PT.HolyPower     },
        { "holypower",  PT.HolyPower     }, { "chi",     PT.Chi           },
        { "shards",     PT.SoulShards    }, { "soul",    PT.SoulShards    },
        { "arcane",     PT.ArcaneCharges }, { "essence", PT.Essence       },
        { "runes",      PT.Runes         }, { "rage",    PT.Rage          },
        { "energy",     PT.Energy        }, { "fury",    PT.Fury          },
        { "focus",      PT.Focus         }, { "mana",    PT.Mana          },
        { "maelstrom",  PT.Maelstrom     }, { "insanity",PT.Insanity      },
        { "runic",      PT.RunicPower    }, { "astral",  PT.LunarPower    },
    }
    for _, e in ipairs(pairsList) do
        if e[2] ~= nil then ns.POWER_ALIASES[e[1]] = e[2] end
    end
end

function ns.ResolvePowerToken(token)
    if not token or token == "" or token == "auto" then return nil, true end
    local n = tonumber(token)
    if n then return n, true end
    local p = ns.POWER_ALIASES[token:lower()]
    if p ~= nil then return p, true end
    return nil, false
end

-- Specs whose resource is not the one their class is usually associated with.
-- A druid is combo points in cat form and astral power as Balance; a priest has
-- no secondary resource until Shadow.
local SPEC_POWER = {
    [102] = PT.LunarPower,  -- Balance
    [258] = PT.Insanity,    -- Shadow
    [262] = PT.Maelstrom,   -- Elemental
}

-- Resources worth counting, in the order they are preferred when the class and
-- spec hints come up empty. Primary pools (mana, energy, rage) are deliberately
-- absent: they refill constantly, so "you have enough" is not a moment.
local SECONDARY_POWERS = {}
do
    local order = {
        PT.ComboPoints, PT.HolyPower, PT.Chi, PT.SoulShards, PT.ArcaneCharges,
        PT.Essence, PT.Runes, PT.LunarPower, PT.Insanity, PT.Maelstrom,
    }
    for _, p in ipairs(order) do
        if p ~= nil then SECONDARY_POWERS[#SECONDARY_POWERS + 1] = p end
    end
end

local function AutoPowerType(specID)
    local hint = SPEC_POWER[specID or 0]
    if hint == nil then
        local _, class = UnitClass("player")
        hint = CLASS_POWER[class]
    end
    if hint ~= nil then
        local m = UnitPowerMax("player", hint)
        if type(m) == "number" and not IsSecret(m) and m > 0 then return hint end
    end

    -- Neither hint fits this spec: take whichever secondary resource the
    -- character actually has. Cheaper than maintaining a table of every spec
    -- Blizzard ships, and right by construction.
    for _, p in ipairs(SECONDARY_POWERS) do
        local m = UnitPowerMax("player", p)
        if type(m) == "number" and not IsSecret(m) and m > 0 then return p end
    end
    return hint
end
ns.AutoPowerType = AutoPowerType

--[[-------------------------------------------------------------------------
    Saved variables
---------------------------------------------------------------------------]]
local DB_VERSION = 9

local DEFAULTS = {
    version    = DB_VERSION,
    enabled    = true,
    combatOnly = false,
    secretMode = true,   -- keep working in restricted (secret-value) content
    cdm        = false,  -- also glow Cooldown Manager icons
    auraPoll   = 0.2,    -- re-read aura state every N seconds (0 = events only)
    mirror     = true,   -- fall back to Cooldown Manager state when reads fail
    presetDone = {},     -- [specID] = the default rules were offered once
    center = {
        enabled = true,
        size    = 44,
        spacing = 8,
        point   = "auto",  -- sit above the class resource bar
        gap     = 16,
        x       = 0,
        y       = -170,
        locked  = true,
        -- Every "glow while the aura is GONE" state is a reminder by nature,
        -- so it joins the strip without a second toggle.
        autoMissing = true,
    },
    specs = {},
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function CG:GetRules()
    local sid = self.specID or 0
    self.db.specs[sid] = self.db.specs[sid] or {}
    return self.db.specs[sid]
end

--[[-------------------------------------------------------------------------
    Spell helpers
---------------------------------------------------------------------------]]
function ns.SpellInfo(idOrName)
    if not (C_Spell and C_Spell.GetSpellInfo) then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, idOrName)
    if ok and type(info) == "table" and info.spellID then return info end
    return nil
end

function ns.SpellName(spellID)
    local info = ns.SpellInfo(spellID)
    return (info and info.name) or ("spell:" .. tostring(spellID))
end

function ns.SpellIcon(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and tex then return tex end
    end
    local info = ns.SpellInfo(spellID)
    return info and info.iconID or 134400
end

-- Every id a button might report for this spell: the id itself, its base spell
-- and its current override (talents/forms swap the id that lands on the bar).
local function SpellVariants(spellID, out)
    out = out or {}
    out[spellID] = true
    if _G.FindBaseSpellByID then
        local ok, b = pcall(_G.FindBaseSpellByID, spellID)
        if ok and type(b) == "number" then out[b] = true end
    end
    if C_Spell and C_Spell.GetOverrideSpell then
        local ok, o = pcall(C_Spell.GetOverrideSpell, spellID)
        if ok and type(o) == "number" then out[o] = true end
    end
    if C_SpellBook and C_SpellBook.GetOverrideSpell then
        local ok, o = pcall(C_SpellBook.GetOverrideSpell, spellID)
        if ok and type(o) == "number" then out[o] = true end
    end
    return out
end

local function ActionSpellID(slot)
    if not slot then return nil end
    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" then
        return id
    elseif actionType == "macro" then
        local s = _G.GetMacroSpell and GetMacroSpell(id)
        if type(s) == "string" then
            local info = ns.SpellInfo(s)
            return info and info.spellID
        end
        return s
    end
    return nil
end

--[[-------------------------------------------------------------------------
    Action button enumeration
    Blizzard bars + Dominos + anything built on LibActionButton-1.0
    (Bartender4, ElvUI, ...). Same approach ActionBarInterruptHighlight uses.
---------------------------------------------------------------------------]]
local CDM_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local CDM_ALL_VIEWERS = {
    "EssentialCooldownViewer", "UtilityCooldownViewer",
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
}

-- spellID -> Cooldown Manager item frame. The engine tracks aura presence on
-- those frames itself, so when direct aura reads are unavailable their state
-- can be mirrored onto a button without ever reading the aura. Fallback only:
-- it needs the spell to be tracked in the Cooldown Manager, which the direct
-- path does not.
ns.cdmFrames = {}

-- Spells the Cooldown Manager tracks as AURAS (its two buff viewers). That is
-- Blizzard's own list of "this spell leaves something on a unit", so it is
-- what the preset uses to decide which bar spells deserve a dot/buff rule --
-- no per-class table of dot ids to maintain.
ns.cdmAuraSpells = {}
ns.cdmAuraFrames = {}
-- Spells in the Essential viewer: Blizzard's own idea of "the cooldowns that
-- matter for this spec". Used as the burst list so there is no table to keep.
ns.cdmEssentialSpells = {}
ns.cdmViewerOf = setmetatable({}, { __mode = "k" })
local CDM_AURA_VIEWERS = {
    BuffIconCooldownViewer = true,
    BuffBarCooldownViewer  = true,
}

function ns.RebuildCDMMap()
    wipe(ns.cdmFrames)
    wipe(ns.cdmAuraSpells)
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then return end
    wipe(ns.cdmAuraFrames)
    wipe(ns.cdmEssentialSpells)
    wipe(ns.cdmViewerOf)
    local map = ns.cdmFrames
    local auraMap = ns.cdmAuraFrames
    local auraSet = ns.cdmAuraSpells
    local viewerOf = ns.cdmViewerOf
    local isAuraViewer = false
    local currentViewer
    local function add(id, frame)
        if type(id) ~= "number" or id <= 0 then return end
        if not map[id] then map[id] = frame end
        viewerOf[frame] = viewerOf[frame] or currentViewer
        if currentViewer == "EssentialCooldownViewer" then
            ns.cdmEssentialSpells[id] = true
        end
        if isAuraViewer then
            auraSet[id] = true
            -- Aura rules must resolve to a BUFF viewer entry: on a cooldown
            -- viewer entry IsActive() means "the spell is on cooldown", which
            -- has nothing to do with the aura being up.
            if not auraMap[id] then auraMap[id] = frame end
        end
    end
    for _, viewerName in ipairs(CDM_ALL_VIEWERS) do
        isAuraViewer = CDM_AURA_VIEWERS[viewerName] or false
        currentViewer = viewerName
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and type(frames) == "table" then
                for _, itemFrame in ipairs(frames) do
                    if itemFrame and itemFrame.cooldownID then
                        local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, itemFrame.cooldownID)
                        if ok2 and type(info) == "table" then
                            add(info.spellID, itemFrame)
                            add(info.overrideSpellID, itemFrame)
                            if type(info.linkedSpellIDs) == "table" then
                                for _, id in ipairs(info.linkedSpellIDs) do add(id, itemFrame) end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Action slots run 1-120, plus the bonus/stance pages. 180 covers every
-- build with room to spare and costs one global lookup each.
local MAX_ACTION_SLOT = 180

local function ForEachActionButton(fn)
    local seen = {}
    ns.scannedButtons = 0
    local function visit(b, spellID)
        if not b or seen[b] then return end
        seen[b] = true
        ns.scannedButtons = ns.scannedButtons + 1
        fn(b, spellID)
    end

    -- EllesmereUIActionBars builds its OWN buttons (EABButton<slot>) and then
    -- deliberately nils them out of ActionBarButtonEventsFrame.frames, so a
    -- scan of Blizzard's registry alone finds nothing on an EUI setup. Its own
    -- modules address them by name; do the same.
    for slot = 1, MAX_ACTION_SLOT do
        local b = _G["EABButton" .. slot]
        if b then visit(b, ActionSpellID(b.action or slot)) end
    end

    if ActionBarButtonEventsFrame and ActionBarButtonEventsFrame.frames then
        for _, b in pairs(ActionBarButtonEventsFrame.frames) do
            if b and b.action then visit(b, ActionSpellID(b.action)) end
        end
    end

    if _G.Dominos and Dominos.ActionButtons and Dominos.ActionButtons.buttons then
        for b in pairs(Dominos.ActionButtons.buttons) do
            if b and b.action then visit(b, ActionSpellID(b.action)) end
        end
    end

    if _G.LibStub and LibStub.IterateLibraries then
        for name, lib in LibStub:IterateLibraries() do
            if type(name) == "string" and name:match("^LibActionButton%-1%.0") and lib.GetAllButtons then
                local ok, buttons = pcall(lib.GetAllButtons, lib)
                if ok and buttons then
                    for b in pairs(buttons) do
                        local t = b.GetAction and select(1, b:GetAction())
                        if t == "action" and b.action then visit(b, ActionSpellID(b.action)) end
                    end
                end
            end
        end
    end
end

ns.ForEachActionButton = ForEachActionButton
ns.ActionSpellID = ActionSpellID

-- How many buttons each rule actually landed on, and how many buttons were
-- seen at all. A rule that matches nothing is the most common reason for
-- "it says it added it but nothing glows", so /cg list reports both.
ns.buttonCount = setmetatable({}, { __mode = "k" })
ns.scannedButtons = 0

local function ForEachCooldownViewerFrame(fn)
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then return end
    for _, viewerName in ipairs(CDM_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and frames then
                for _, itemFrame in ipairs(frames) do
                    if itemFrame and itemFrame.cooldownID then
                        local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, itemFrame.cooldownID)
                        if ok2 and info and info.spellID then fn(itemFrame, info.spellID) end
                    end
                end
            end
        end
    end
end

--[[-------------------------------------------------------------------------
    Center anchor
---------------------------------------------------------------------------]]
local anchor

local function CreateAnchor()
    if anchor then return anchor end
    anchor = CreateFrame("Frame", "ComboGlowAnchor", UIParent)
    anchor:SetSize(100, 100)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:EnableMouse(false)
    anchor:RegisterForDrag("LeftButton")

    local bg = anchor:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(anchor)
    bg:SetColorTexture(0.05, 0.82, 0.62, 0.25)
    bg:Hide()
    anchor.bg = bg

    local label = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText("ComboGlow")
    label:Hide()
    anchor.label = label

    anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)
    anchor:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Dragging is an explicit choice: it leaves the automatic placement
        -- above the resource bar and pins the strip where it was dropped.
        local point, _, _, x, y = self:GetPoint()
        local c = CG.db.center
        c.point, c.x, c.y = point, math.floor(x + 0.5), math.floor(y + 0.5)
    end)
    return anchor
end

-- Frames the class resource bar might be, best first. Sitting just above it
-- puts the reminders where the eye already is during a rotation; the middle of
-- the screen is where the character model is, which is exactly the wrong place.
local RESOURCE_BAR_FRAMES = {
    "ERB_SecondaryFrame",          -- EllesmereUIResourceBars
    "ClassNameplateBarFrame",
    "ComboPointPlayerFrame",
}

local function FindResourceBar()
    for _, name in ipairs(RESOURCE_BAR_FRAMES) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() and f.GetTop and f:GetTop() then
            return f
        end
    end
end

function CG:PositionAnchor()
    local a = CreateAnchor()
    local c = self.db.center
    a:ClearAllPoints()

    if c.point == "auto" or c.point == nil then
        local bar = FindResourceBar()
        if bar then
            a:SetPoint("BOTTOM", bar, "TOP", 0, c.gap or 10)
            return
        end
        -- No bar found: above the action bars, out of the model's way.
        a:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 320)
        return
    end

    a:SetPoint(c.point, UIParent, c.point, c.x or 0, c.y or -170)
end

function CG:SetAnchorLocked(locked)
    local a = CreateAnchor()
    self.db.center.locked = locked and true or false
    a:EnableMouse(not locked)
    if locked then
        a.bg:Hide()
        a.label:Hide()
    else
        a.bg:Show()
        a.label:Show()
    end
end

--[[-------------------------------------------------------------------------
    Build
---------------------------------------------------------------------------]]
-- Everything that decides what is drawn. Two rebuilds with the same
-- fingerprint would produce identical frames, so the second one is skipped
-- instead of tearing the live ones down.
local function RuleFingerprint(rule)
    return table.concat({
        tostring(rule.kind), tostring(rule.spell), tostring(rule.style),
        tostring(rule.r), tostring(rule.g), tostring(rule.b),
        tostring(rule.alpha), tostring(rule.thick), tostring(rule.warn),
        tostring(rule.wr), tostring(rule.wg), tostring(rule.wb),
        tostring(rule.missing), tostring(rule.proc), tostring(rule.enabled),
        tostring(rule.timer), tostring(rule.center), tostring(rule.unit),
        tostring(rule.min), tostring(rule.max), tostring(rule.atMax),
        tostring(rule.orProc), tostring(rule.swipe), tostring(rule.auraID),
        tostring(rule.combat),
    }, ",")
end

function CG:Teardown()
    self.pool:ReleaseAll()
    self.centerPool:ReleaseAll()
    ns.UntrackAuraFrames()
    wipe(self.powerFrames)
    wipe(self.auraFrames)
    wipe(self.watchedSlots)
    self.wantedSpells = {}
end

function CG:Rebuild()
    if not self.initialized then return end

    local rules = self:GetRules()

    -- spellID -> list of rules. Built BEFORE any teardown so an unchanged
    -- layout can bail out with the live frames untouched.
    local wanted, castMap, any = {}, {}, false
    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and rule.spell then
            local ids = SpellVariants(rule.spell)
            for id in pairs(ids) do
                wanted[id] = wanted[id] or {}
                table.insert(wanted[id], rule)
                any = true
                -- Aura rules also react to the cast itself, so the display
                -- does not have to wait for the aura event.
                if rule.kind == "aura" then
                    castMap[id] = castMap[id] or {}
                    table.insert(castMap[id], rule)
                end
            end
        end
    end

    if not self.db.enabled or #rules == 0 or not any then
        self:Teardown()
        self.lastSig = nil
        return
    end

    ns.RebuildCDMMap()
    ns.mirrorEnabled = self.db.mirror ~= false

    -- Collect what WOULD be built, and fingerprint it.
    local placeButtons, placeRules, sigParts, watched = {}, {}, {}, {}
    local function collect(button, spellID)
        local list = spellID and wanted[spellID]
        if not list then return end
        if button.action then watched[button.action] = true end
        for _, rule in ipairs(list) do
            placeButtons[#placeButtons + 1] = button
            placeRules[#placeRules + 1] = rule
            sigParts[#sigParts + 1] = tostring(button) .. "#" .. RuleFingerprint(rule)
        end
    end
    ForEachActionButton(collect)
    if self.db.cdm then ForEachCooldownViewerFrame(collect) end

    local centerRules = {}
    if self.db.center.enabled then
        local auto = self.db.center.autoMissing ~= false
        local watched = {}
        for _, rule in ipairs(rules) do
            -- Auto-added: "gone" states that watch their OWN aura.
            --
            -- A redirected one is excluded on purpose. Primal Wrath's "gone"
            -- means "Rip is not up", which Rip's own icon already says, and it
            -- is a situational choice rather than something you forgot to
            -- press -- so it would be a second nag for the same fact. The
            -- manual /cg center flag still forces one in.
            -- A burst whose cooldown is up is the same kind of nudge as a dot
            -- that fell off, so it joins the strip too.
            local autoWanted = auto and not watched[rule.spell]
                and ((rule.kind == "aura" and rule.missing and not rule.auraID)
                     or rule.kind == "cd")
            if (rule.center or autoWanted) and rule.enabled ~= false then
                watched[rule.spell] = true
                centerRules[#centerRules + 1] = rule
                sigParts[#sigParts + 1] = "c" .. RuleFingerprint(rule)
            end
        end
        sigParts[#sigParts + 1] = "sz" .. tostring(self.db.center.size)
    end

    local sig = table.concat(sigParts, "|")
    if sig == self.lastSig then
        -- Same buttons, same rules, same look. Rebuilding here is what made a
        -- marker blink off every time an action slot twitched -- which, with
        -- assisted combat on the bars, is every cast.
        self:UpdateNow()
        return
    end
    self.lastSig = sig

    self:Teardown()
    wipe(ns.castMap)
    for id, list in pairs(castMap) do ns.castMap[id] = list end
    self.wantedSpells = wanted
    self.watchedSlots = watched
    wipe(ns.buttonCount)

    local function register(frame, rule)
        frame.rule = rule
        frame.pandemicOn = nil
        frame._optStamp = nil
        ns.ResetMirror(frame)
        ns.ClearTimer(frame)
        frame:Hide()
        if rule.kind == "aura" then
            self.auraFrames[#self.auraFrames + 1] = frame
            ns.TrackAuraFrame(frame)
        else
            self.powerFrames[#self.powerFrames + 1] = frame
        end
    end

    for i = 1, #placeButtons do
        local button, rule = placeButtons[i], placeRules[i]
        local ov = self.pool:Acquire()
        ov:Attach(button)
        ov:SetStyle(rule.style, rule.r, rule.g, rule.b, rule.alpha, rule.thick)
        register(ov, rule)
        ns.buttonCount[rule] = (ns.buttonCount[rule] or 0) + 1
    end

    -- Center icons: one fixed slot per rule that asked for it, laid out as a
    -- centered row. Fixed slots (instead of packing only the active ones) keep
    -- the layout identical in restricted content, where we cannot know which
    -- icon is currently on.
    do
        local n = #centerRules
        if n > 0 then
            local a = CreateAnchor()
            local size = self.db.center.size or 52
            local spacing = self.db.center.spacing or 10
            local totalW = n * size + (n - 1) * spacing
            a:SetSize(totalW, size)
            self:PositionAnchor()
            for i, rule in ipairs(centerRules) do
                local ic = self.centerPool:Acquire()
                ic:SetParent(a)
                ic:Setup(size, ns.SpellIcon(rule.spell))
                -- Always the plain frame here, whatever the button uses. On a
                -- reminder the icon appearing IS the message, and a 30% wash
                -- or a thin dashed line reads as nothing at this size.
                ic:SetStyle("solid", rule.r, rule.g, rule.b, 1, 3)
                ic:ClearAllPoints()
                local x = (i - 1) * (size + spacing) - totalW / 2 + size / 2
                ic:SetPoint("CENTER", a, "CENTER", x, 0)
                register(ic, rule)
            end
        end
    end

    self:UpdateNow()
end

function CG:MarkDirty()
    if self.dirtyPending then return end
    self.dirtyPending = true
    C_Timer.After(0.1, function()
        self.dirtyPending = false
        self:Rebuild()
    end)
end

--[[-------------------------------------------------------------------------
    Update
---------------------------------------------------------------------------]]
-- Cached power reads for one update pass. A secret value is a fine table
-- VALUE (only keys are forbidden), but it must never meet a Lua comparison --
-- including "== nil" -- so presence is tracked in a separate plain table and
-- the type check uses type(), which reports a secret's underlying type.
local powerCache, powerCacheHas = {}, {}

-- Last plain (non-secret) maximum for a power type. UnitPowerMax can go secret
-- in restricted content, so the last readable value is kept as the fallback.
CG.maxCache = {}
function CG:GetMaxPower(pt)
    if pt == nil then return nil end
    local m = UnitPowerMax("player", pt)
    if type(m) == "number" and not IsSecret(m) and m > 0 then
        self.maxCache[pt] = m
        return m
    end
    return self.maxCache[pt]
end

local function Silence(frame)
    frame.pandemicOn = nil
    ns.ResetMirror(frame)
    ns.ClearTimer(frame)
    frame:StopArt()
    frame:Hide()
end

function CG:HideAll()
    for ov in self.pool:EnumerateActive() do Silence(ov) end
    for ic in self.centerPool:EnumerateActive() do Silence(ic) end
end

-- A burst is "ready" when its cooldown is done. The global cooldown does not
-- count as being on cooldown -- everything is on the GCD constantly, and a
-- marker that blinks off every button press is worse than none.
local function CooldownReady(spellID)
    if not (spellID and C_Spell and C_Spell.GetSpellCooldown) then return false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or type(info) ~= "table" then return false end
    if info.isOnGCD then return true end
    return not info.isActive
end
ns.CooldownReady = CooldownReady

function CG:Suppressed()
    if not self.db.enabled then return true end
    if self.db.combatOnly and not InCombatLockdown() then return true end
    return false
end

function CG:UpdatePower()
    if not self.initialized then return end
    if #self.powerFrames == 0 then return end
    if self:Suppressed() then
        for _, f in ipairs(self.powerFrames) do Silence(f) end
        return
    end

    wipe(powerCache)
    wipe(powerCacheHas)
    local gateAllowed = self.db.secretMode and true or false

    -- No goto/continue here: WoW runs Lua 5.1, where neither exists. The two
    -- kinds are separate branches instead.
    for _, frame in ipairs(self.powerFrames) do
        local rule = frame.rule

        if rule and rule.kind == "cd" then
            -- Burst: ready means off cooldown, not a resource count. Kept to
            -- combat by default -- a major cooldown sitting ready in town is
            -- not something anyone needs reminding of.
            local on = CooldownReady(rule.spell)
            if on and rule.combat ~= false and not InCombatLockdown() then
                on = false
            end
            if not on and rule.orProc ~= false
               and ns.IsProcced and ns.IsProcced(rule.spell) then
                on = true
            end
            frame.needSafeStyle = false
            if on then
                if not frame:IsShown() then frame:Show() end
                frame:StartArt()
            else
                Silence(frame)
            end

        else
            local pt = rule and (rule.power or self.powerType)
            local ok = pt ~= nil
            if ok and not powerCacheHas[pt] then
                local cur = UnitPower("player", pt)
                if type(cur) == "number" then
                    powerCache[pt] = cur
                    powerCacheHas[pt] = true
                else
                    ok = false
                end
            end

            local minV, maxV = rule and rule.min or 1, rule and rule.max
            if ok and rule.atMax then
                -- "at maximum": the cap can move with talents, so it is read
                -- live (with the last plain reading kept for restricted
                -- content).
                local mx = self:GetMaxPower(pt)
                if mx then minV, maxV = mx, nil else ok = false end
            end

            -- "ready" is the resource threshold OR a proc: a finisher that
            -- procced is ready no matter what the bar says. Forcing the value
            -- to the threshold lights it through the same path, gate included.
            if rule and rule.orProc ~= false
               and ns.IsProcced and ns.IsProcced(rule.spell) then
                frame:ApplyState(minV, false, minV, nil, gateAllowed)
            elseif not ok then
                Silence(frame)
            else
                local v = powerCache[pt]
                frame:ApplyState(v, IsSecret(v), minV, maxV, gateAllowed)
            end
        end
    end
end

function CG:UpdateAuras()
    if not self.initialized then return end
    if #self.auraFrames == 0 then return end
    if self:Suppressed() then
        for _, f in ipairs(self.auraFrames) do Silence(f) end
        return
    end
    for _, frame in ipairs(self.auraFrames) do
        ns.ApplyAuraRule(frame, frame.rule)
    end
end

function CG:QueueAuraUpdate()
    if self.auraPending then return end
    if #self.auraFrames == 0 then return end
    self.auraPending = true
    C_Timer.After(0.05, function()
        self.auraPending = false
        self:UpdateAuras()
    end)
end

function CG:UpdateNow()
    if not self.initialized then return end

    if self.testMode then
        for ov in self.pool:EnumerateActive() do
            ov.needSafeStyle = false
            ov:ApplyState(1, false, 1, nil, false)
        end
        for ic in self.centerPool:EnumerateActive() do
            ic.needSafeStyle = false
            ic:ApplyState(1, false, 1, nil, false)
        end
        return
    end

    self:UpdatePower()
    self:UpdateAuras()
end

function CG:Test(seconds)
    self.testMode = true
    self:UpdateNow()
    C_Timer.After(seconds or 6, function()
        self.testMode = false
        self:UpdateNow()
    end)
end

--[[-------------------------------------------------------------------------
    Spec / events
---------------------------------------------------------------------------]]
local function GetSpecID()
    local idx
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        idx = C_SpecializationInfo.GetSpecialization()
    elseif _G.GetSpecialization then
        idx = GetSpecialization()
    end
    if not idx then return 0 end
    local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or _G.GetSpecializationInfo
    if not getInfo then return 0 end
    local ok, id = pcall(getInfo, idx)
    if ok and type(id) == "number" then return id end
    return 0
end
ns.GetSpecID = GetSpecID

function CG:RefreshSpec()
    self.specID = GetSpecID()
    self.powerType = AutoPowerType(self.specID)
end

local REBUILD_EVENTS = {
    "ACTIONBAR_SLOT_CHANGED",
    "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_SHAPESHIFT_FORM",
    "UPDATE_MACROS",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "PLAYER_TALENT_UPDATE",
    "TRAIT_CONFIG_UPDATED",
}

function CG:Initialize()
    ComboGlowDB = ComboGlowDB or {}
    local hadDB = ComboGlowDB.version ~= nil
    local fromVersion = ComboGlowDB.version or DB_VERSION
    CopyDefaults(DEFAULTS, ComboGlowDB)
    self.db = ComboGlowDB

    -- v2: debuff rules were created with the finisher's proc glow before the
    -- two looks were split. A dot that is up is a steady state, so move them
    -- to the quiet border; an explicit change made since then is preserved
    -- because only the old default value is rewritten.
    if hadDB and fromVersion < 2 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" and not r.helpful and r.style == "modern" then
                    r.style = "pixel"
                end
            end
        end
    end

    -- v3: an aura that is up reads better as a plain tinted border than as a
    -- marching one -- green while it is yours, red while it is gone. Only the
    -- values the previous defaults produced are rewritten.
    if hadDB and fromVersion < 3 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" and (r.style == "pixel" or r.style == "modern") then
                    r.style = "active"
                    if r.r == 1 and r.g == 0.85 and r.b == 0.1 then
                        if r.missing then
                            r.r, r.g, r.b = 1, 0, 0
                        else
                            r.r, r.g, r.b = 0, 1, 0
                        end
                    end
                end
            end
        end
    end
    -- v4: Blizzard's highlight art is a faint grey image, so tinting it can
    -- only ever look washed out. Own crisp frame instead, plus the "running
    -- out" colour on a seconds threshold -- the old fraction-of-duration one
    -- could never fire without a readable duration.
    if hadDB and fromVersion < 4 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" then
                    if r.style == "active" then r.style = "solid" end
                    if r.alpha == nil then r.alpha = 1 end
                    if r.thick == nil then r.thick = 3 end
                    if r.warn == nil then r.warn = 4 end
                    if r.wr == nil then r.wr, r.wg, r.wb = 1, 0, 0 end
                    r.pandemic = nil
                end
            end
        end
    end
    -- v5: the two sweep markers drew nothing on a real button (the widget is
    -- fine standalone -- /cg cdtest proves it -- so the fault is in this
    -- overlay). Rather than leave anyone with an invisible marker, they are out
    -- of the gallery and any rule using one is moved to the frame.
    -- v6: the extra brightness steps of the soft border were indistinguishable
    -- from each other (the vertex colour clamps), and the light wash from the
    -- normal one. Everyone lands back on the single version.
    -- v7: new per-state defaults -- marching border while the aura is up, a
    -- colour wash while it is gone. Only rewrites what the old default
    -- produced (the plain frame in that state's own colour), so a marker
    -- picked by hand survives.
    -- v9: the strip's meaning changed from "mirror this to the middle of the
    -- screen" to "remind me this is missing", so flags set under the old
    -- meaning would populate it with things that are not reminders.
    if hadDB and fromVersion < 9 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do r.center = nil end
        end
        self.db.center.gap = 16
    end

    -- v8: the strip used to sit in the middle of the screen, which is where
    -- the character model is. Moved above the class resource bar, where the
    -- eye already is. Only the untouched default is relocated.
    if hadDB and fromVersion < 8 then
        local c = self.db.center
        if c.point == "CENTER" and c.x == 0 and c.y == -170 then
            c.point = "auto"
            c.size = 44
            c.spacing = 8
        end
    end

    if hadDB and fromVersion < 7 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" and r.style == "solid" and not r.proc then
                    if r.missing and r.r == 1 and r.g == 0 and r.b == 0 then
                        r.style, r.alpha = "fill", 0.30
                    elseif not r.missing and r.r == 0 and r.g == 1 and r.b == 0 then
                        r.style, r.alpha = "pixel", 1
                    end
                end
            end
        end
    end

    if hadDB and fromVersion < 6 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.style == "soft2" or r.style == "soft3" then r.style = "active" end
                if r.style == "washlite" then r.style = "fill" end
            end
        end
    end

    if hadDB and fromVersion < 5 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.style == "swipe" or r.style == "ring" then
                    r.style = "solid"
                    r.swipe = nil
                end
            end
        end
    end
    self.db.version = DB_VERSION

    self.pool = CreateFramePool("Frame", UIParent, "ComboGlowOverlayTemplate")
    self.centerPool = CreateFramePool("Frame", UIParent, "ComboGlowCenterIconTemplate")
    self.powerFrames = {}
    self.auraFrames  = {}
    self.watchedSlots = {}
    self.wantedSpells = {}

    self:RefreshSpec()
    CreateAnchor()
    self:PositionAnchor()
    self:SetAnchorLocked(self.db.center.locked ~= false)

    self.initialized = true

    for _, ev in ipairs(REBUILD_EVENTS) do
        pcall(self.RegisterEvent, self, ev)
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    -- Power rules react to procs too (see UpdatePower), so a proc has to poke
    -- that path as well, not just the aura one.
    self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    self:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    self:RegisterUnitEvent("UNIT_MAXPOWER", "player")
    self:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
    -- Aura rules
    ns.pollInterval = self.db.auraPoll or 0.2
    ns.PollCallback = function() self:UpdateAuras() end
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    self:RegisterEvent("UNIT_AURA")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("PLAYER_FOCUS_CHANGED")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    self:RegisterEvent("SPELL_UPDATE_USABLE")

    if EventRegistry and EventRegistry.RegisterCallback then
        pcall(EventRegistry.RegisterCallback, EventRegistry,
            "CooldownViewerSettings.OnDataChanged", function() self:MarkDirty() end)
    end

    self:Rebuild()
    self:QueueAutoPreset()
end

-- First time a spec is seen with no rules at all, build the obvious ones
-- instead of sitting there looking broken. Runs once per spec (the flag
-- survives deleting every rule, so an intentionally empty spec stays empty).
function CG:AutoPreset(attempt)
    attempt = attempt or 1
    if not (ns.Say and ns.BuildPreset) then return end
    local sid = self.specID or 0
    if self.db.presetDone[sid] then return end
    if #self:GetRules() > 0 then
        self.db.presetDone[sid] = true
        return
    end

    local added = ns.BuildPreset(true, ns.L(
        "first run on this spec - setting up default rules:",
        "первый вход на этой специализации — создаю правила по умолчанию:"))

    if added > 0 then
        self.db.presetDone[sid] = true
        return
    end
    -- Bars can still be empty this early. Retry a couple of times before
    -- giving up, so a slow login does not leave the spec silently unset.
    if attempt < 3 then
        C_Timer.After(5, function() self:AutoPreset(attempt + 1) end)
        return
    end
    self.db.presetDone[sid] = true
    ns.Say(ns.L("loaded. No resource spender found on your bars, so nothing was set up - |cffffd100/cg preset|r retries, |cffffd100/cg|r lists the commands.",
                "загружен. На панелях не нашлось расходников ресурса, правила не созданы — |cffffd100/cg preset|r повторит попытку, |cffffd100/cg|r покажет команды."))
end

-- The claimed slash token is not announced at login: it never changes, and a
-- line every single login is noise. /comboglow always works and the help text
-- prints the short form.
function CG:AnnounceSlash()
end

function CG:QueueAutoPreset()
    -- Bars and the spellbook are not reliably populated at login; give them
    -- a moment before scanning.
    C_Timer.After(4, function() self:AutoPreset(1) end)
end

CG:RegisterEvent("PLAYER_LOGIN")
CG:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:Initialize()
        return
    end
    if not self.initialized then return end

    if event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT"
       or event == "UNIT_MAXPOWER"
       or event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_USABLE" then
        self:UpdatePower()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        if type(spellID) == "number" then
            self.lastCast = spellID
            if ns.OnPlayerCast(spellID) then self:UpdateAuras() end
        end
    elseif event == "UNIT_AURA" then
        local unit = ...
        if ns.AURA_UNITS[unit] then self:QueueAuraUpdate() end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED"
        or event == "UPDATE_MOUSEOVER_UNIT"
        or event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW"
        or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        self:UpdateAuras()
        self:UpdatePower()
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        self:UpdateNow()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UNIT_DISPLAYPOWER" then
        self:RefreshSpec()
        self:MarkDirty()
        self:QueueAutoPreset()
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:RefreshSpec()
        self:MarkDirty()
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- This fires constantly (assisted combat, spell overrides). Rebuilding
        -- on every one of them restarts every glow animation and throws away
        -- in-flight state, so only slots that matter get through.
        local slot = ...
        if slot == nil or self.watchedSlots[slot]
           or self.wantedSpells[ns.ActionSpellID(slot)] then
            self:MarkDirty()
        end
    else
        self:MarkDirty()
    end
end)
