--[[---------------------------------------------------------------------------
    ComboGlow - ResourceGlow.lua

    Glow on the pips of EllesmereUI's class resource bar once the resource
    reaches a chosen count. Sits where the eye already is, so spending at the
    cap does not need a look down at the buttons. Parented to the bar, so it
    hides with it (a druid outside cat form).

    Same reasoning as the gate in Glow.lua: UnitPower() can be SECRET, so the
    count is never read here. Each pip has its own invisible status bar spanning
    [v-1 .. v], where v is the larger of the threshold and the pip's own index;
    the ring is anchored to the edge of its fill and clipped, so it slides out
    of sight below v. At a threshold of 3 of 5: three rings at 3, four at 4,
    five at 5.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...

local CG = ns.CG
local IsSecret = ns.IsSecret
local PT = Enum.PowerType

local RG = {}
ns.ResourceGlow = RG

-- Resources drawn as pips. A continuous bar has no pips to put a ring on.
local PIPS = {
    [PT.ComboPoints]   = true,
    [PT.HolyPower]     = true,
    [PT.Chi]           = true,
    [PT.SoulShards]    = true,
    [PT.ArcaneCharges] = true,
    [PT.Essence]       = true,
}
-- Anything not listed defaults to the cap, which moves with talents.
local DEFAULT_AT = { [PT.ComboPoints] = 5, [PT.HolyPower] = 3 }

local MAX_CELLS = 7        -- rogues reach 7 combo points
local OUTSET    = 10       -- room for a ring outside its pip
local GOLD_R, GOLD_G, GOLD_B = 1, 0.82, 0.2
local PIXEL_OPTS = { N = 8, th = 2, period = 3 }

local bar
local cells = {}

-- Styles that work on a pip: the ones drawn by the EllesmereUI engine, minus
-- the ones hidden from the gallery.
function RG.Styles()
    local out = {}
    for _, s in ipairs(ns.STYLES) do
        if s.euiIndex and not s.hidden then out[#out + 1] = s end
    end
    return out
end

function RG.Power()
    local pt = CG.powerType
    if pt ~= nil and PIPS[pt] then return pt end
end

function RG.Max()
    local pt = RG.Power()
    if pt == nil then return 5 end
    local n = UnitPowerMax("player", pt)
    if type(n) ~= "number" or IsSecret(n) or n < 1 then return 5 end
    return math.min(n, MAX_CELLS)
end

function RG.Threshold()
    local pt = RG.Power()
    if pt == nil then return 5 end
    local at = CG.db.barGlow.at[pt] or DEFAULT_AT[pt] or RG.Max()
    return math.min(at, RG.Max())
end

function RG.SetThreshold(n)
    local pt = RG.Power()
    if pt == nil then return false end
    CG.db.barGlow.at[pt] = n
    RG.Refresh()
    return true
end

local function Update()
    local pt = RG.Power()
    if not bar or pt == nil then return end
    local cur = UnitPower("player", pt)
    for _, cell in ipairs(cells) do cell.gate:SetValue(cur) end
end

local function StopAll()
    local G = ns.EUIGlows()
    if not G then return end
    for _, cell in ipairs(cells) do G.StopGlow(cell.ring) end
end

local function HideAll()
    StopAll()
    for _, cell in ipairs(cells) do cell.clip:Hide() end
end

function RG.Refresh()
    if not bar then return end
    local G = ns.EUIGlows()
    local s = CG.db and CG.db.barGlow
    if not G or not s or not s.enabled or not CG.db.enabled or RG.Power() == nil then
        HideAll()
        return
    end
    if not bar:IsVisible() then return end

    local w, h = bar:GetSize()
    local count = RG.Max()
    local cw = w / count
    if cw <= 0 or h <= 0 then return end

    local threshold = RG.Threshold()
    local style = ns.StyleByKey(s.style)
    local opts = style.key == "pixel" and PIXEL_OPTS or nil
    for i, cell in ipairs(cells) do
        if i <= count then
            local v = math.max(i, threshold)
            cell.clip:ClearAllPoints()
            cell.clip:SetPoint("TOPLEFT", bar, "TOPLEFT", (i - 1) * cw - OUTSET, OUTSET)
            cell.clip:SetSize(cw + OUTSET * 2, h + OUTSET * 2)
            cell.art:SetSize(cw + OUTSET * 2, h + OUTSET * 2)
            cell.ring:SetSize(cw, h)
            cell.gate:SetMinMaxValues(v - 1, v)
            cell.clip:Show()
            cell.ring:SetAlpha(1)      -- StopGlow leaves it at 0
            G.StartGlow(cell.ring, style.euiIndex, cw, GOLD_R, GOLD_G, GOLD_B, opts, h)
        else
            G.StopGlow(cell.ring)
            cell.clip:Hide()
        end
    end
    Update()
end

local function Build(frame)
    bar = frame
    for i = 1, MAX_CELLS do
        local clip = CreateFrame("Frame", nil, bar)
        clip:SetFrameLevel(bar:GetFrameLevel() + 20)
        clip:SetClipsChildren(true)

        local gate = CreateFrame("StatusBar", nil, clip)
        gate:SetAllPoints(clip)
        gate:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        gate:SetAlpha(0)

        local art = CreateFrame("Frame", nil, clip)
        art:SetPoint("RIGHT", gate:GetStatusBarTexture(), "RIGHT", 0, 0)

        local ring = CreateFrame("Frame", nil, art)
        ring:SetPoint("CENTER", art, "CENTER", 0, 0)

        cells[i] = { clip = clip, gate = gate, art = art, ring = ring }
    end
    bar:HookScript("OnShow", RG.Refresh)
    bar:HookScript("OnHide", StopAll)
    bar:HookScript("OnSizeChanged", RG.Refresh)
    RG.Refresh()
end

-- The resource module builds its frames some time after login.
local function WaitForBar(tries)
    local frame = _G.ERB_SecondaryFrame
    if frame and CG.initialized and ns.EUIGlows() then
        Build(frame)
    elseif tries > 0 then
        C_Timer.After(1, function() WaitForBar(tries - 1) end)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
events:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
events:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
events:RegisterUnitEvent("UNIT_MAXPOWER", "player")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        WaitForBar(30)
    elseif event == "UNIT_MAXPOWER" or event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- A tick later: Core refreshes the spec's resource on the same event.
        C_Timer.After(0, RG.Refresh)
    else
        Update()
    end
end)
