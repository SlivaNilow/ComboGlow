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
local DB_VERSION = 13

local DEFAULTS = {
    version    = DB_VERSION,
    enabled    = true,
    combatOnly = false,
    showBars   = true,   -- mark the action bars

    secretMode = true,   -- keep working in restricted (secret-value) content
    cdm        = false,  -- also glow Cooldown Manager icons
    auraPoll   = 0.2,    -- re-read aura state every N seconds (0 = events only)
    mirror     = true,   -- fall back to Cooldown Manager state when reads fail
    blizzGlow  = false,  -- let the game draw its own gold proc glow as well
    hideCDM    = false,  -- keep the Cooldown Manager running but invisible
    minimap    = { angle = 200, hide = false },
    stackPos   = "topleft",  -- where the aura stack count sits on the marker
    stackScale = 100,        -- its size, as a percentage of the default
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
        -- So is a free cast appearing: it happens to you rather than because
        -- you pressed something, which is exactly what the strip is for.
        autoProc = true,
        -- Close the gap where a state we can read is not lit. Mirrored ones
        -- keep their place either way -- their state is not ours to know.
        pack = true,
        -- One row per kind instead of one long row: each packs on its own, so
        -- a kind with nothing lit takes no height at all.
        rows = false,
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

--[[-------------------------------------------------------------------------
    Hiding the Cooldown Manager

    Everything the aura states know comes from it, so it has to keep running --
    which is why this sets ALPHA and never calls Hide(). A hidden frame is not
    guaranteed to keep updating, and the moment it stops, the mirror it feeds
    goes with it. At zero alpha it is invisible and still ticking.

    Re-applied on every map rebuild: Blizzard's own code sets these back when
    the viewers are rebuilt, on a spec change among other things.
---------------------------------------------------------------------------]]
local cdmHooked, cdmPending, cdmDirtyAt = {}, false, 0
-- What each viewer looked like before we first touched it, so unhiding puts
-- back what the player had rather than assuming defaults.
local cdmWas = setmetatable({}, { __mode = "k" })

--[[-------------------------------------------------------------------------
    Hidden by SCALE, not by alpha and not by Hide()

    Hide() is what the dedicated addons use and it is not open to us: a hidden
    frame stops updating, and the aura states read the countdown text off these
    very frames. Invisible is required; stopped is not.

    Alpha was the obvious middle ground and it lost. Blizzard fades the viewer
    in when its contents change, and a fade drives alpha -- so whatever we set
    was overwritten by the animation a moment later, which is what the blink
    every few seconds was. Reapplying faster only made the fight faster.

    Scale is not animated. At 0.01 the viewer is half a pixel across, still
    laid out, still ticking, still readable by us -- and nothing puts it back.
---------------------------------------------------------------------------]]
local HIDDEN_SCALE = 0.01

local function ScheduleCDMVisibility()
    if cdmPending then return end
    cdmPending = true
    C_Timer.After(0, function()
        cdmPending = false
        ns.ApplyCDMVisibility()

        -- A viewer laying itself out again means its item frames were rebuilt,
        -- and every mirror we hold points at the old ones. That is what a
        -- specialization change does, and why the markers only came back after
        -- a SECOND reload: the first read the map before the viewers existed.
        --
        -- Throttled, because Layout also fires as entries come and go, and a
        -- rebuild walks every action slot on the bars.
        local now = GetTime()
        if CG.initialized and now - cdmDirtyAt > 2 then
            cdmDirtyAt = now
            CG:MarkDirty()
        end
    end)
end

function ns.ApplyCDMVisibility()
    -- Never hidden while Edit Mode is open: that is where the Cooldown Manager
    -- is configured, and a half-pixel frame cannot be configured.
    local em = _G.EditModeManagerFrame
    local editing = em and em.IsEditModeActive and em:IsEditModeActive()
    local hide = CG.db and CG.db.hideCDM and not editing

    for _, name in ipairs(CDM_ALL_VIEWERS) do
        local f = _G[name]
        if f and f.SetScale then
            if cdmWas[f] == nil then
                local okS, s = pcall(f.GetScale, f)
                cdmWas[f] = (okS and s and s > HIDDEN_SCALE and s) or 1
            end
            pcall(f.SetScale, f, hide and HIDDEN_SCALE or cdmWas[f])

            if not cdmHooked[f] then
                cdmHooked[f] = true
                if f.Layout then
                    pcall(hooksecurefunc, f, "Layout", ScheduleCDMVisibility)
                end
                if f.HookScript then
                    pcall(f.HookScript, f, "OnShow", function(self)
                        local e = _G.EditModeManagerFrame
                        local ed = e and e.IsEditModeActive and e:IsEditModeActive()
                        if CG.db and CG.db.hideCDM and not ed then
                            pcall(self.SetScale, self, HIDDEN_SCALE)
                        end
                    end)
                end
            end
        end
    end
end

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
-- The same lists keyed by NAME. A viewer often tracks the aura's id while the
-- bar holds the id that casts it -- Moonfire casts as one spell and lands as
-- another -- so an id-only match silently found nothing for those specs. The
-- name is shared, and it is the client's own localised string on both sides.
ns.cdmAuraNames = {}
ns.cdmEssentialNames = {}
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
    wipe(ns.cdmAuraNames)
    wipe(ns.cdmEssentialNames)
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
        local name = ns.SpellName(id)
        if name and not name:find("^spell:") then name = name:lower() else name = nil end

        if currentViewer == "EssentialCooldownViewer" then
            ns.cdmEssentialSpells[id] = true
            if name then ns.cdmEssentialNames[name] = true end
        end
        if isAuraViewer then
            auraSet[id] = true
            if name and not ns.cdmAuraNames[name] then ns.cdmAuraNames[name] = frame end
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
    ns.ApplyCDMVisibility()
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
-- What an icon on the reminder strip MEANS, which is how the row is ordered
-- and, in rows mode, which row it lands on. Left to right, bottom to top: a
-- free cast, what is up, what has fallen off, and last the buttons that are
-- simply ready. State first, things to press at the end.
--
-- Ordering by this rather than by the order rules were created in also puts
-- the gaps in one place: a state we cannot read holds its slot whether or not
-- it is lit, and scattered between the lit icons those spaces look like a
-- fault.
local function StripRank(rule)
    if rule.kind == "aura" and rule.proc then return 1 end
    if rule.kind == "aura" and rule.missing then return 3 end
    if rule.kind == "aura" then return 2 end
    return 4
end

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
        tostring(rule.combat), tostring(rule.style2), tostring(rule.stripOff),
        tostring(rule.soon),
        -- Sorted at the source, so the same set of buffs always reads the same
        -- and picking one in the options window does force a rebuild.
        type(rule.auraIDs) == "table" and table.concat(rule.auraIDs, "+") or "",
    }, ",")
end

function CG:Teardown()
    self.pool:ReleaseAll()
    self.centerPool:ReleaseAll()
    ns.UntrackAuraFrames()
    wipe(ns.procActive)
    self._packSig = nil
    -- Released frames keep their rule reference, and a rebuild that ends up
    -- with an empty strip would otherwise leave the last one's icons here.
    if self.centerIcons then wipe(self.centerIcons) end
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
    wipe(ns.procOwned)
    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and rule.kind == "aura" and rule.proc and rule.spell then
            ns.procOwned[rule.spell] = true
            -- A proc drawn with Blizzard's gold artwork is the same mark as
            -- "ready", whatever colour is stored, which defeats the entire
            -- point of separating them. Corrected here, on every rebuild,
            -- rather than in a database migration or a rescan: both are
            -- one-shot paths that fire on one version or one button press,
            -- and this correction has now been missed by both.
            --
            -- styleLocked means the marker was chosen by hand in the options
            -- window. A deliberate choice is left alone -- the gallery labels
            -- those tiles "(gold)", so it is an informed one.
            local d = ns.STATE_DEFAULTS and ns.STATE_DEFAULTS.proc
            if d and not rule.styleLocked then
                -- The WHOLE look, assigned outright. Merging field by field is
                -- what kept this broken: one repair moved the style off the
                -- gold artwork and left the gold COLOUR behind, and a later
                -- one added a second layer that then had no way to go away
                -- again. An unlocked proc state simply looks like the default,
                -- and picking anything by hand locks it out of this.
                rule.style  = d.style
                rule.style2 = d.style2
                rule.alpha  = ns.StyleAlpha and ns.StyleAlpha(d.style) or nil
                rule.thick  = d.thick or rule.thick
                rule.r, rule.g, rule.b = d.r, d.g, d.b
            end
        end
    end
    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and rule.spell then
            local ids = SpellVariants(rule.spell)
            for id in pairs(ids) do
                wanted[id] = wanted[id] or {}
                table.insert(wanted[id], rule)
                any = true
                -- Aura rules also react to the cast itself, so the display
                -- does not have to wait for the aura event. Not proc rules:
                -- casting the spell SPENDS the proc, so the optimistic guess
                -- would light the free-cast marker the instant it stopped
                -- being true.
                if rule.kind == "aura" and not rule.proc then
                    castMap[id] = castMap[id] or {}
                    table.insert(castMap[id], rule)
                end
            end
        end
    end

    -- Before the early exit below, not after: the scan that CREATES the first
    -- rules reads this map, and a spec with no rules yet would never get here
    -- to build it. Chicken and egg -- a freshly changed spec found nothing to
    -- set up and said so.
    ns.RebuildCDMMap()
    ns.mirrorEnabled = self.db.mirror ~= false

    if not self.db.enabled or #rules == 0 or not any then
        self:Teardown()
        self.lastSig = nil
        return
    end

    -- Collect what WOULD be built, and fingerprint it.
    local placeButtons, placeRules, placeStyles = {}, {}, {}
    local sigParts, watched = {}, {}
    local function place(button, rule, styleKey)
        placeButtons[#placeButtons + 1] = button
        placeRules[#placeRules + 1] = rule
        placeStyles[#placeStyles + 1] = styleKey
        sigParts[#sigParts + 1] =
            tostring(button) .. "#" .. tostring(styleKey) .. "#" .. RuleFingerprint(rule)
    end
    local function collect(button, spellID)
        local list = spellID and wanted[spellID]
        if not list then return end
        if button.action then watched[button.action] = true end
        for _, rule in ipairs(list) do
            place(button, rule, rule.style)
            -- A second marker for the same state. One frame carries one style,
            -- so two styles means two frames on the same button driven by the
            -- same rule -- they light and go dark together, and the pair reads
            -- as one mark. Cheaper and far less fragile than teaching a frame
            -- to run two sets of art at once.
            if rule.style2 and rule.style2 ~= rule.style then
                place(button, rule, rule.style2)
            end
        end
    end
    -- Two surfaces, one switch each. The Cooldown Manager path has been here
    -- since the beginning, buried in a slash command; the bars are what it was
    -- always paired with. Turning the bars off is a real preference: the
    -- Cooldown Manager is the only place that draws the EMPOWERED art for a
    -- dot, so marking state there and leaving the buttons clean is a coherent
    -- way to run it.
    if self.db.showBars ~= false then ForEachActionButton(collect) end
    if self.db.cdm then ForEachCooldownViewerFrame(collect) end

    local centerRules = {}
    if self.db.center.enabled then
        -- One slot per STATE, not per spell. It used to be one per spell, to
        -- avoid the same icon appearing twice -- but the second state was
        -- dropped silently, and whichever rule happened to come first won.
        -- Starsurge's resource state took the slot and its proc, ticked and
        -- reported as on, never appeared; Starfall's proc did, purely because
        -- nothing else of its spell had asked.
        --
        -- Two slots for one spell is not the problem it looked like: they are
        -- different colours, they are mutually exclusive in practice (a proc
        -- stands the resource marker down), and a reserved dark slot is what
        -- every state on this strip already is until it lights.
        for _, rule in ipairs(rules) do
            -- Auto-added: "gone" states that watch their OWN aura, bursts
            -- whose cooldown is up, and procs.
            --
            -- A redirected "gone" is excluded on purpose. Primal Wrath's
            -- means "Rip is not up", which Rip's own icon already says, and it
            -- is a situational choice rather than something you forgot to
            -- press -- so it would be a second nag for the same fact. The
            -- manual /cg center flag still forces one in.
            --
            -- A burst coming up and a free cast appearing are the same kind of
            -- nudge as a dot falling off: something changed that you did not
            -- press a button to cause, and the strip is where those go.
            if ns.OnStrip(rule) and rule.enabled ~= false then
                centerRules[#centerRules + 1] = rule
                sigParts[#sigParts + 1] = "c" .. RuleFingerprint(rule)
            end
        end
        sigParts[#sigParts + 1] = "sz" .. tostring(self.db.center.size)

        -- table.sort is not stable, so the position it came in at is the
        -- tiebreak; without it the row reshuffles between rebuilds.
        local came = {}
        for i, r in ipairs(centerRules) do came[r] = i end
        table.sort(centerRules, function(a, b)
            local ra, rb = StripRank(a), StripRank(b)
            if ra ~= rb then return ra < rb end
            return came[a] < came[b]
        end)
    end

    local sig = table.concat(sigParts, "|")
    if sig == self.lastSig then
        -- Same buttons, same rules, same look. Rebuilding here is what made a
        -- marker blink off every time an action slot twitched -- which, with
        -- assisted combat on the bars, is every cast.
        self:HideBlizzGlow()
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
        local styleKey = placeStyles[i]
        local primary = (styleKey == rule.style)
        local ov = self.pool:Acquire()
        ov:Attach(button)
        ov.secondary = (not primary) or nil
        ov.isStrip = nil
        -- The second marker takes the style's own opacity: the rule's alpha
        -- was chosen for the first one and a wash's 30% would gut a glow.
        local alpha = rule.alpha
        if not primary then alpha = ns.StyleAlpha(styleKey) end
        ov:SetStyle(styleKey, rule.r, rule.g, rule.b, alpha, rule.thick)
        register(ov, rule)
        -- Counted once per button, not once per marker: /cg list reports where
        -- a rule sits, and two markers on one button is still one button.
        if primary then
            ns.buttonCount[rule] = (ns.buttonCount[rule] or 0) + 1
        end
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
            wipe(self.centerIcons)
            for i, rule in ipairs(centerRules) do
                local ic = self.centerPool:Acquire()
                ic.secondary = nil
                ic.isStrip = true
                ic.stripRank = StripRank(rule)
                self.centerIcons[#self.centerIcons + 1] = ic
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

    -- Anything the game lit before we got here.
    self:HideBlizzGlow()
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

--[[-------------------------------------------------------------------------
    Blizzard's own proc glow

    Suppressed by default. This addon exists to make button marking mean
    something specific -- which state, in which colour, chosen per spell -- and
    the game's own glow works against that: it is gold, it cannot be coloured,
    it is the same gold as "ready", and it says only "something happened" with
    no way to tell what. Two glows on one button, one of them unreadable, is
    worse than one. "/cg blizzglow on" puts it back.

    Done by hiding the alert the moment the game says it appeared, NOT by
    replacing ActionButtonSpellAlertManager.ShowAlert or the old global helper.
    Those are called from the secure action-button path, and a Lua closure in
    the middle of it spreads taint -- which surfaces as blocked actions in
    combat, long after the change that caused it. A hide is just a frame call.

    Every way a button might carry the alert is tried, because there is no one
    supported way and third-party bars roll their own.
---------------------------------------------------------------------------]]
-- Only what Blizzard documents for this, and nothing else.
--
-- An earlier version also called EllesmereUI's StopGlow on the button and hid
-- any frame the button kept under a LibCustomGlow key or under "overlay" /
-- "Overlay". That made the action bars vanish in combat: those names are not
-- reserved for proc glows, and on someone else's button they are parts of the
-- button. Reaching into another addon's fields to hide something is guesswork,
-- and guessing wrong here costs the player their bars mid-fight.
--
-- If a third-party bar draws its own proc glow, that is its feature and its
-- option to turn off. Ours is not the code to fight it.
local function HideAlertOn(button)
    if not button then return end
    if button.HideSpellActivationAlert then
        pcall(button.HideSpellActivationAlert, button)
    end
    local mgr = _G.ActionButtonSpellAlertManager
    if mgr and mgr.HideAlert then pcall(mgr.HideAlert, mgr, button) end
    local a = button.SpellActivationAlert
    if type(a) == "table" and a.Hide then pcall(a.Hide, a) end
end

-- spellID limits the sweep to the buttons that spell sits on; without one
-- every button is checked, which is for a rebuild, not for every proc.
function CG:HideBlizzGlow(spellID)
    if self.db.blizzGlow ~= false then return end
    local ids = spellID and SpellVariants(spellID) or nil
    ForEachActionButton(function(b, sid)
        if not ids or (sid and ids[sid]) then HideAlertOn(b) end
    end)
end

--[[-------------------------------------------------------------------------
    Who belongs in the reminder strip

    Split out because the options window has to answer the same question. Its
    checkbox used to read rule.center alone, so a dot that the strip had picked
    up on its own showed an EMPTY box next to an icon that was plainly there --
    the control disagreed with the display, and the display was right.

    center = true forces a rule in, stripOff = true forces it out, and neither
    means "decide by its nature". A plain false is left meaning "decide": rules
    have been created with center = false since the first version and it never
    meant "keep this out".
---------------------------------------------------------------------------]]
function ns.AutoStrip(rule)
    local c = CG.db and CG.db.center
    if not c or not c.enabled then return false end
    if rule.enabled == false then return false end
    if rule.kind == "aura" and rule.proc then return c.autoProc ~= false end
    if c.autoMissing == false then return false end
    if rule.kind == "cd" then return true end
    -- Debuffs only. A personal cooldown is missing most of the time, so a
    -- buff's "gone" state on the strip would be a permanent icon that means
    -- nothing -- on the button it costs nothing, here it costs the strip.
    return (rule.kind == "aura" and rule.missing and not rule.auraID
            and not rule.helpful) and true or false
end

function ns.OnStrip(rule)
    if rule.stripOff then return false end
    if rule.center then return true end
    return ns.AutoStrip(rule)
end

local function Silence(frame)
    frame.pandemicOn = nil
    ns.ResetMirror(frame)
    ns.ClearTimer(frame)
    ns.ClearStacks(frame)
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

-- A burst is a spell you wait for. Anything on the global cooldown alone is a
-- filler, and marking every filler as "ready" lights the whole bar -- which is
-- exactly what happened when the only test was "does not spend the resource":
-- a Balance druid's fillers spend nothing either.
local BURST_MIN_COOLDOWN = 20   -- seconds

function ns.HasRealCooldown(spellID)
    if not spellID then return false end
    if _G.GetSpellBaseCooldown then
        local ok, ms = pcall(_G.GetSpellBaseCooldown, spellID)
        if ok and type(ms) == "number" then
            return ms >= BURST_MIN_COOLDOWN * 1000
        end
    end
    -- No base-cooldown API: fall back to whatever it is doing right now. A
    -- spell sitting on a long cooldown is a burst; one that is ready tells us
    -- nothing, so it is left out rather than guessed in.
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and type(info) == "table" and info.isActive and not info.isOnGCD then
            local d = tonumber(info.duration)
            if d and d >= BURST_MIN_COOLDOWN then return true end
        end
    end
    return false
end

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

        -- The spell's proc state is lit right now, so this one keeps quiet:
        -- two markers on one button saying "press me" is one too many, and the
        -- free cast is the one worth reading.
        if rule and rule.spell and ns.procActive[rule.spell] then
            Silence(frame)

        elseif rule and rule.kind == "cd" then
            -- Burst: ready means off cooldown, not a resource count. Kept to
            -- combat by default -- a major cooldown sitting ready in town is
            -- not something anyone needs reminding of.
            -- The tracker's own icon, with the sweep on it: a burst
            -- marker otherwise says "ready" when it means "tracked".
            if ns.ShowEntryBadge then ns.ShowEntryBadge(frame, rule) end
            local on = CooldownReady(rule.spell)
            if on and rule.combat ~= false and not InCombatLockdown() then
                on = false
            end
            if not on and rule.orProc ~= false and not ns.procOwned[rule.spell]
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
            --
            -- Unless the spell has a "proc" state of its own -- then the proc
            -- belongs to that marker and this one stays about the resource, so
            -- the two say different things instead of firing together.
            if rule and rule.orProc ~= false and not ns.procOwned[rule.spell]
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
    -- A proc outranks the resource: a free cast is the better news, so while
    -- the proc marker is lit the "ready" one stands down. ApplyAuraRule keeps
    -- ns.procActive, which the power pass reads -- and a flip re-runs that
    -- pass, because an aura event does not reach the power frames on its own
    -- and the resource marker would otherwise stay lit until the next power
    -- tick.
    -- Debuffs on something else are kept to combat by default, the same way a
    -- burst cooldown is. A dot missing from a training dummy, or from whatever
    -- you last had targeted in town, is not news -- and the row of red marks
    -- that produces is the kind of noise that teaches you to stop reading the
    -- markers at all.
    --
    -- Buffs on yourself are left alone: those you do keep up before a pull.
    -- Per rule, so /cgl combat and the rule's own flag still win.
    local peace = not InCombatLockdown()
    ns.procDirty = false
    for _, frame in ipairs(self.auraFrames) do
        local rule = frame.rule
        if peace and rule and rule.kind == "aura" and rule.combat ~= false
           and rule.unit and rule.unit ~= "player" then
            Silence(frame)
        else
            ns.ApplyAuraRule(frame, rule)
        end
    end
    if ns.procDirty then
        ns.procDirty = false
        self:UpdatePower()
    end
    self:PackStrip()
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
    self:PackStrip()
end

--[[-------------------------------------------------------------------------
    Closing the gaps in the strip

    Slots used to be fixed, because in restricted content the state is resolved
    engine-side and we genuinely cannot know which icons are lit -- so a state
    driven by the mirror keeps its place regardless. Everything else we DO know
    about: a proc that has not procced, a burst on cooldown, a dot that reads.
    Those close up, which is most of the gaps in practice.

    "/cg pack off" for anyone who would rather the icons never move.
---------------------------------------------------------------------------]]
function CG:PackStrip()
    local icons = self.centerIcons
    if not icons or #icons == 0 then return end
    local c = self.db.center
    if not c.enabled or c.pack == false then return end

    local size = c.size or 52
    local spacing = c.spacing or 10

    -- Repositioning runs on every update pass, so the set is fingerprinted and
    -- the work skipped unless it actually changed.
    -- Whether the Cooldown Manager's own frames can be believed.
    --
    -- IsActive() on an entry is a secret boolean and must never be read. But
    -- IsShown() is a plain one -- it only means "inactive" when the player has
    -- "hide when inactive" turned on for that viewer, and there is no way to
    -- ask which setting they chose. So it is inferred: if any tracked entry is
    -- hidden right now, the setting is on and the flag can be trusted. With it
    -- off nothing is ever hidden, nothing is inferred, and the layout falls
    -- back to reserving a slot. Conservative in the only direction that
    -- matters -- it never packs away an icon that might be lit.
    local trustShown = false
    for _, f in pairs(ns.cdmAuraFrames or {}) do
        if f.IsShown and not f:IsShown() then
            trustShown = true
            break
        end
    end

    -- Two passes, and the order matters. What we can read packs first;
    -- anything still unknowable goes last, so a gap that cannot be closed
    -- lands at the end of the row rather than between the icons that are lit.
    local live, sig = {}, ""
    local function Take(ic)
        live[#live + 1] = ic
        sig = sig .. tostring(ic)
    end
    for _, ic in ipairs(icons) do
        if ic.rule and not ic._mirroring and ic:IsShown() then Take(ic) end
    end
    for _, ic in ipairs(icons) do
        if ic.rule and ic._mirroring then
            local keep = true
            if trustShown then
                local mf, isAura = ns.FindMirror(ic.rule)
                if mf and isAura and mf.IsShown then
                    local up = mf:IsShown()
                    -- A "gone" state is lit by absence, so the two read the
                    -- entry in opposite directions.
                    keep = ic.rule.missing and (not up)
                        or (not ic.rule.missing and up)
                end
            end
            if keep then Take(ic) end
        end
    end
    sig = sig .. tostring(trustShown)
    sig = sig .. tostring(c.rows)
    if sig == self._packSig then return end
    self._packSig = sig

    local a = anchor

    -- One row per kind, stacked upward with the free casts on top. Each row
    -- packs on its own, so a kind with nothing lit takes no height at all --
    -- and the kinds we CAN read leave no gaps, whatever the mirrored ones do.
    if c.rows then
        local groups, ranks = {}, {}
        for _, ic in ipairs(live) do
            local r = ic.stripRank or 4
            if not groups[r] then
                groups[r] = {}
                ranks[#ranks + 1] = r
            end
            groups[r][#groups[r] + 1] = ic
        end
        table.sort(ranks)

        local widest, row = size, 0
        -- Highest rank at the bottom, so rank 1 (a free cast) ends up on top.
        for i = #ranks, 1, -1 do
            local g = groups[ranks[i]]
            local n = #g
            local w = n * size + (n - 1) * spacing
            if w > widest then widest = w end
            local y = row * (size + spacing)
            for j, ic in ipairs(g) do
                local x = (j - 1) * (size + spacing) - w * 0.5 + size * 0.5
                ic:ClearAllPoints()
                ic:SetPoint("CENTER", a or ic:GetParent(), "CENTER", x, y)
            end
            row = row + 1
        end
        if a then
            a:SetSize(widest, math.max(size, row * (size + spacing) - spacing))
        end
        return
    end

    local n = #live
    local totalW = size
    if n > 0 then totalW = n * size + (n - 1) * spacing end
    if a then a:SetSize(totalW, size) end
    for i, ic in ipairs(live) do
        local x = (i - 1) * (size + spacing) - totalW * 0.5 + size * 0.5
        ic:ClearAllPoints()
        ic:SetPoint("CENTER", a or ic:GetParent(), "CENTER", x, 0)
    end
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
    -- v10: a proc state watched exactly one buff. It can have several -- one
    -- buff frees one spell, another frees two -- so the single id becomes a
    -- list. auraID keeps its old meaning for every other kind of rule.
    if hadDB and fromVersion < 10 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" and r.proc and r.auraID then
                    r.auraIDs = { r.auraID }
                    r.auraID = nil
                end
            end
        end
    end
    -- v12: proc states drawn with Blizzard's proc artwork. It is a gold
    -- animation that ignores the colour it is given, so a proc looked exactly
    -- like "ready" -- the one marker it must never be confused with. Moved to
    -- the frame we draw ourselves, where the colour is ours.
    --
    -- v11 did this for "shine" alone, which was the wrong culprit: shine takes
    -- a colour perfectly well. The gold ones are the ones flagged fixedColor.
    if hadDB and fromVersion < 13 then
        for _, rules in pairs(self.db.specs) do
            for _, r in ipairs(rules) do
                if r.kind == "aura" and r.proc then
                    local st = ns.StyleByKey(r.style)
                    if st and st.fixedColor then
                        local d = ns.STATE_DEFAULTS and ns.STATE_DEFAULTS.proc
                        r.style = "solid"
                        r.alpha = nil
                        r.r = d and d.r or 0.2
                        r.g = d and d.g or 0.9
                        r.b = d and d.b or 1
                    end
                end
            end
        end
    end
    self.db.version = DB_VERSION

    self.pool = CreateFramePool("Frame", UIParent, "ComboGlowOverlayTemplate")
    self.centerPool = CreateFramePool("Frame", UIParent, "ComboGlowCenterIconTemplate")
    self.powerFrames = {}
    self.auraFrames  = {}
    self.centerIcons = {}
    self.watchedSlots = {}
    self.wantedSpells = {}

    self:RefreshSpec()
    CreateAnchor()
    self:PositionAnchor()
    self:SetAnchorLocked(self.db.center.locked ~= false)

    -- Opt-in, and remembered. It puts a formatter on Blizzard's own Cooldown
    -- Manager entries, which is insecure code touching frames the secure path
    -- owns -- so it is never on because nobody said otherwise.
    ns.entryFormat = self.db.entryFormat and true or false

    -- Purely additive and touches nothing of theirs: their texture goes
    -- into ours unread. On by default because it is the only way the
    -- empowered art reaches the button at all.
    ns.showEntryIcon = self.db.entryIcon ~= false
    ns.entryIconScale = tonumber(self.db.entryIconScale) or 75

    self.initialized = true
    if ns.CreateMinimapButton then ns.CreateMinimapButton() end

    for _, ev in ipairs(REBUILD_EVENTS) do
        pcall(self.RegisterEvent, self, ev)
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- Entering or leaving Edit Mode changes whether the Cooldown Manager may
    -- be hidden at all, and the layout it rebuilds on the way out.
    pcall(self.RegisterEvent, self, "EDIT_MODE_LAYOUTS_UPDATED")
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

    -- Re-read the spec here rather than trusting what the event handler saw:
    -- PLAYER_SPECIALIZATION_CHANGED can fire before GetSpecialization() answers
    -- the new one, and acting on the stale id marks the OLD spec as done while
    -- leaving the new one with nothing.
    self:RefreshSpec()
    local sid = self.specID or 0

    -- Spec id 0 means the client has not answered yet. Creating rules under it
    -- files them where nothing will ever look again, so wait instead.
    if sid == 0 then
        if attempt < 4 then
            C_Timer.After(5, function() self:AutoPreset(attempt + 1) end)
        end
        return
    end

    -- Rescue anything an earlier run filed under 0 before the id settled.
    local orphans = self.db.specs[0]
    if orphans and #orphans > 0 and #self:GetRules() == 0 then
        local rules = self:GetRules()
        for i = 1, #orphans do rules[i] = orphans[i] end
        self.db.specs[0] = nil
        self:Rebuild()
        if ns.Say then
            ns.Say(ns.L("recovered %d rules saved before the specialization was known",
                        "восстановлено правил, сохранённых до определения специализации: %d"),
                   #rules)
        end
        self.db.presetDone[sid] = true
        return
    end

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
        if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
            -- Same frame the game raised it in, so it never gets drawn.
            self:HideBlizzGlow(...)
        end
        self:UpdateAuras()
        self:UpdatePower()
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        self:UpdateNow()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UNIT_DISPLAYPOWER" then
        self:RefreshSpec()
        self:MarkDirty()
        self:QueueAutoPreset()
        -- The Cooldown Manager rebuilds its viewers for the new spec, and its
        -- Layout hook usually catches that. Usually: the viewers can lay
        -- themselves out before their entries have any data, and then the map
        -- we read is empty. Two later passes cost nothing and close that.
        for _, delay in ipairs({ 2, 5 }) do
            C_Timer.After(delay, function()
                if self.initialized then
                    ns.RebuildCDMMap()
                    self.lastSig = nil
                    self:Rebuild()
                end
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:RefreshSpec()
        self:MarkDirty()
    elseif event == "EDIT_MODE_LAYOUTS_UPDATED" then
        ns.ApplyCDMVisibility()
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
