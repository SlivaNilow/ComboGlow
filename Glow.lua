--[[---------------------------------------------------------------------------
    ComboGlow - Glow.lua

    Glow artwork + the "gate": a geometry-driven visibility trick that keeps
    working when UnitPower() hands back a SECRET value (restricted instances in
    12.x). A secret number can be fed to StatusBar:SetValue() but can never be
    compared in Lua, so visibility is produced by clipping instead of by an if.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...

local _issecret = _G.issecretvalue
local function IsSecret(v) return _issecret ~= nil and _issecret(v) end
ns.IsSecret = IsSecret

local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Style list. euiIndex lines up with EllesmereUI.Glows.STYLES when that suite
-- is installed; without it we fall back to our own two looks.
-- "hidden" keeps a style working for anyone who set it, and for /cg style,
-- while leaving it out of the gallery: several of these are indistinguishable
-- from each other once tinted, and two never drew at all.
ns.STYLES = {
    -- Drawn by us: no engine, no animation, exact colour and opacity. A state
    -- that is simply true reads better as a steady mark than as a proc.
    { key = "solid",   euiIndex = nil, fallback = "solid",     defAlpha = 1,    short = "Frame",      label = "Solid colour frame" },
    { key = "fill",    euiIndex = nil, fallback = "fill",      defAlpha = 0.30, short = "Wash",       label = "Colour wash"        },
    -- One brightness only: this highlight is a faint image and the vertex
    -- colour clamps at 1.0, so overdriving it changed nothing visible.
    { key = "active",  euiIndex = nil, fallback = "highlight", defAlpha = 1,    short = "Soft",       label = "Soft border"        },
    { key = "swipe",   euiIndex = nil, fallback = "none",                       hidden = true, short = "Sweep",      label = "Cooldown sweep"     },
    { key = "ring",    euiIndex = nil, fallback = "none",                       hidden = true, short = "Sweep+edge", label = "Sweep with edge"    },
    { key = "pixel",   euiIndex = 1,   fallback = "border",                     short = "Pixel",      label = "Pixel Glow"         },
    { key = "button",  euiIndex = 2,   fallback = "border",                     hidden = true, short = "Button",     label = "Action Button Glow" },
    -- Also fixedColor, by observation: a proc set to cyan came out the same
    -- gold as "ready". The sparkle textures behind it are Blizzard's autocast
    -- art and the colour handed to the engine does not reach them.
    { key = "shine",   euiIndex = 3,   fallback = "border", fixedColor = true,  short = "Shine",      label = "Auto-Cast Shine"    },
    -- fixedColor: Blizzard's own proc artwork. It is a gold animation with no
    -- colour input -- ours is accepted and ignored, by the engine and by the
    -- texture we fall back to alike. Worth saying out loud: two states set to
    -- different colours look identical if both land here, which is exactly how
    -- a proc ended up indistinguishable from "ready".
    { key = "gcd",     euiIndex = 5,   fallback = "proc", fixedColor = true,    hidden = true, short = "Ants",       label = "GCD Ants"           },
    { key = "modern",  euiIndex = 6,   fallback = "proc", fixedColor = true,    short = "Modern",     label = "Modern WoW Glow"    },
    { key = "classic", euiIndex = 7,   fallback = "border",                     hidden = true, short = "Classic",    label = "Classic WoW Glow"   },
}
-- Shape Glow (EllesmereUI index 4) is deliberately absent: without the mask and
-- border textures its options expect, it paints a filled block over the icon.

function ns.StyleByKey(key)
    for _, s in ipairs(ns.STYLES) do
        if s.key == key then return s end
    end
    for _, s in ipairs(ns.STYLES) do
        if s.key == "modern" then return s end
    end
    return ns.STYLES[1]
end

local function EUIGlows()
    local G = _G.EllesmereUI and _G.EllesmereUI.Glows
    if G and G.StartGlow and G.StopGlow then return G end
    return nil
end
ns.EUIGlows = EUIGlows

--[[-------------------------------------------------------------------------
    The gate

    gateH  : fixed to the host rect, clips its children.
    gateV  : child of gateH, host sized, its RIGHT edge anchored to minBar's
             fill texture. minBar spans [min-1 .. min] so the fill is empty
             below the threshold (gateV slides a full width to the left and
             everything inside it is clipped away) and full at or above it
             (gateV lines up with the host, nothing is clipped).
    Art    : child of gateV but positioned in HOST space by maxBar's vertical
             fill, which spans [max .. max+1]: above the upper bound the art is
             pushed a full height up, out of gateV, and clipped.

    Both bars sit at alpha 0, so the mechanism is never visible. Every compare
    happens inside the C status bars; Lua never touches the number itself.
---------------------------------------------------------------------------]]
local function BuildGate(host)
    if host.gateH then return end
    local w, h = host:GetSize()
    if not w or w <= 0 then return end

    local gateH = CreateFrame("Frame", nil, host)
    gateH:SetAllPoints(host)
    gateH:SetClipsChildren(true)

    local gateV = CreateFrame("Frame", nil, gateH)
    gateV:SetSize(w, h)
    gateV:SetClipsChildren(true)

    local function MakeBar(orientation)
        local bar = CreateFrame("StatusBar", nil, host)
        bar:SetAllPoints(host)
        bar:SetOrientation(orientation)
        bar:SetStatusBarTexture(WHITE)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(orientation == "HORIZONTAL" and 1 or 0)
        bar:SetAlpha(0)
        return bar
    end

    local minBar = MakeBar("HORIZONTAL")
    local maxBar = MakeBar("VERTICAL")

    gateV:ClearAllPoints()
    gateV:SetPoint("RIGHT", minBar:GetStatusBarTexture(), "RIGHT", 0, 0)

    host.Art:SetParent(gateV)
    host.Art:ClearAllPoints()
    host.Art:SetSize(w, h)
    host.Art:SetPoint("BOTTOM", maxBar:GetStatusBarTexture(), "TOP", 0, 0)

    host.gateH, host.gateV, host.minBar, host.maxBar = gateH, gateV, minBar, maxBar
end

local function ResizeGate(host, w, h)
    if not host.gateH then return end
    host.gateV:SetSize(w, h)
    host.Art:SetSize(w, h)
end

-- Drive the gate from a (possibly secret) value. Never compares cur.
local function DriveGate(host, cur, minV, maxV)
    if not host.gateH then return end
    host.minBar:SetMinMaxValues(minV - 1, minV)
    host.minBar:SetValue(cur)
    if maxV then
        host.maxBar:SetMinMaxValues(maxV, maxV + 1)
        host.maxBar:SetValue(cur)
    else
        host.maxBar:SetMinMaxValues(0, 1)
        host.maxBar:SetValue(0)
    end
end

ns.BuildGate  = BuildGate
ns.ResizeGate = ResizeGate
ns.DriveGate  = DriveGate

--[[-------------------------------------------------------------------------
    Shared art control (used by both the button overlay and the center icon)
---------------------------------------------------------------------------]]
local StartArt, StopArt

--[[-------------------------------------------------------------------------
    Own static markers

    Four solid strips laid just outside the icon, or one wash over it. Drawn
    with SetColorTexture, so the colour is exactly the colour asked for at
    exactly the alpha asked for -- unlike Blizzard's highlight art, which is a
    faint grey image that any tint can only make fainter.
---------------------------------------------------------------------------]]
local function EnsureMarkers(A)
    if A.SolidT then return end
    local function strip()
        local t = A:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 1)
        t:Hide()
        return t
    end
    A.SolidT, A.SolidB, A.SolidL, A.SolidR = strip(), strip(), strip(), strip()
    A.Fill = strip()
end

local function LayoutSolid(self, t)
    local A, W = self.Art, self.Art.Wrap
    if not W then return end
    A.SolidT:ClearAllPoints()
    A.SolidT:SetPoint("BOTTOMLEFT",  W, "TOPLEFT",  -t,  0)
    A.SolidT:SetPoint("BOTTOMRIGHT", W, "TOPRIGHT",  t,  0)
    A.SolidT:SetHeight(t)

    A.SolidB:ClearAllPoints()
    A.SolidB:SetPoint("TOPLEFT",  W, "BOTTOMLEFT",  -t, 0)
    A.SolidB:SetPoint("TOPRIGHT", W, "BOTTOMRIGHT",  t, 0)
    A.SolidB:SetHeight(t)

    A.SolidL:ClearAllPoints()
    A.SolidL:SetPoint("TOPRIGHT",    W, "TOPLEFT",    0, 0)
    A.SolidL:SetPoint("BOTTOMRIGHT", W, "BOTTOMLEFT", 0, 0)
    A.SolidL:SetWidth(t)

    A.SolidR:ClearAllPoints()
    A.SolidR:SetPoint("TOPLEFT",    W, "TOPRIGHT",    0, 0)
    A.SolidR:SetPoint("BOTTOMLEFT", W, "BOTTOMRIGHT", 0, 0)
    A.SolidR:SetWidth(t)
end

local function HideMarkers(A)
    if not A.SolidT then return end
    A.SolidT:Hide(); A.SolidB:Hide(); A.SolidL:Hide(); A.SolidR:Hide()
    A.Fill:Hide()
end

function StartArt(self)
    -- In gate mode the Lua-driven EllesmereUI engines (pixel glow, shine, ...)
    -- are swapped for their C-side FlipBook equivalent, which keeps animating
    -- in restricted content. Outside gate mode the chosen style is used as is.
    local wantSafe = self.needSafeStyle and true or false
    local failed = self.sweepFailed and true or false
    if self.artRunning then
        if self.artSafe == wantSafe and self.artFailed == failed then return end
        StopArt(self)
    end
    self.artRunning = true
    self.artSafe = wantSafe
    self.artFailed = failed
    local A = self.Art
    local G = EUIGlows()
    local st = self.styleEntry or ns.StyleByKey("modern")
    local r, g, b = self.r or 0, self.g or 1, self.b or 0
    if st.fallback == "none" and not failed then
        -- The duration widget is the whole marker; no border art at all.
        A.Proc:Hide(); A.Border:Hide()
        if A.Highlight then A.Highlight:Hide() end
        HideMarkers(A)
    elseif st.fallback == "solid" or (st.fallback == "none" and failed) then
        A.Proc:Hide(); A.Border:Hide(); A.Highlight:Hide()
        EnsureMarkers(A)
        LayoutSolid(self, self.thick or 3)
        local a = self.alpha or 1
        for _, tex in ipairs({ A.SolidT, A.SolidB, A.SolidL, A.SolidR }) do
            tex:SetVertexColor(r, g, b)
            tex:SetAlpha(a)
            tex:Show()
        end
        A.Fill:Hide()
    elseif st.fallback == "fill" then
        A.Proc:Hide(); A.Border:Hide(); A.Highlight:Hide()
        EnsureMarkers(A)
        A.Fill:ClearAllPoints()
        A.Fill:SetAllPoints(A.Wrap or A)
        A.Fill:SetVertexColor(r, g, b)
        -- Hard cap: a wash that hides the icon it marks is never useful, so
        -- brightness inherited from a border style cannot make it opaque.
        local a = self.alpha or 0.30
        if a > 0.55 then a = 0.55 end
        A.Fill:SetAlpha(a)
        A.Fill:Show()
        A.SolidT:Hide(); A.SolidB:Hide(); A.SolidL:Hide(); A.SolidR:Hide()
    elseif st.fallback == "highlight" then
        -- Plain state marker, no engine and no animation.
        A.Proc:Hide()
        A.Border:Hide()
        HideMarkers(A)
        A.Highlight:SetVertexColor(r, g, b)
        A.Highlight:SetAlpha(self.alpha or 1)
        A.Highlight:Show()
    elseif st.euiIndex and G and self.useEUI then
        local idx = st.euiIndex
        if wantSafe and G.RestrictionSafeStyle then
            local ok, safe = pcall(G.RestrictionSafeStyle, idx)
            if ok and safe then idx = safe end
        end
        -- The engines draw relative to the wrapper they are given, so it has
        -- to be exactly the icon, not our oversized overlay -- otherwise the
        -- border marches around a rectangle far bigger than the button.
        pcall(G.StartGlow, A.Wrap or A, idx, self.artW, self.r, self.g, self.b, nil, self.artH)
    elseif st.fallback == "proc" then
        A.Border:Hide()
        A.Proc:Show()
        if not A.ProcLoop:IsPlaying() then A.ProcLoop:Play() end
    else
        A.Proc:Hide()
        A.Border:Show()
        A.Border:SetVertexColor(self.r or 1, self.g or 0.85, self.b or 0.1)
        if not A.Pulse:IsPlaying() then A.Pulse:Play() end
    end
end

function StopArt(self)
    if not self.artRunning then return end
    self.artRunning = false
    self.artSafe = nil
    local A = self.Art
    local G = EUIGlows()
    if G and self.useEUI then
        pcall(G.StopGlow, A.Wrap or A)
    end
    if A.ProcLoop:IsPlaying() then A.ProcLoop:Stop() end
    if A.Pulse:IsPlaying() then A.Pulse:Stop() end
    A.Proc:Hide()
    A.Border:Hide()
    if A.Highlight then A.Highlight:Hide() end
    HideMarkers(A)
end

local function SetStyle(self, styleKey, r, g, b, alpha, thick)
    local wasRunning = self.artRunning
    if wasRunning then StopArt(self) end
    self.styleEntry = ns.StyleByKey(styleKey)
    self.r, self.g, self.b = r or 1, g or 0.85, b or 0.1
    self.alpha, self.thick = alpha, thick
    self.useEUI = EUIGlows() ~= nil
    if wasRunning then StartArt(self) end
end

-- Live recolour of the static markers. The components may be SECRET (they come
-- out of a colour curve evaluated against the aura's duration), so they are
-- only ever handed to a setter, never inspected. Animated engine glows are not
-- recoloured live -- restarting them mid-animation would stutter.
local function SetArtColor(self, r, g, b)
    local A = self.Art
    if not A then return end
    if A.SolidT and A.SolidT:IsShown() then
        A.SolidT:SetVertexColor(r, g, b)
        A.SolidB:SetVertexColor(r, g, b)
        A.SolidL:SetVertexColor(r, g, b)
        A.SolidR:SetVertexColor(r, g, b)
    end
    if A.Fill and A.Fill:IsShown() then A.Fill:SetVertexColor(r, g, b) end
    if A.Highlight and A.Highlight:IsShown() then A.Highlight:SetVertexColor(r, g, b) end
    if A.Border and A.Border:IsShown() then A.Border:SetVertexColor(r, g, b) end
end

-- Show/hide state for one element.
--   secret == false -> plain Show/Hide (the gate, if it exists, is kept in
--                      sync so a mid-fight switch to secret values lands on
--                      correct geometry)
--   secret == true  -> gate mode: the element stays shown, clipping decides.
local function ApplyState(self, cur, secret, minV, maxV, gateAllowed)
    if secret then
        if not gateAllowed then
            StopArt(self)
            self:Hide()
            return
        end
        BuildGate(self)
        if not self.gateH then
            self:Hide()
            return
        end
        DriveGate(self, cur, minV, maxV)
        if not self:IsShown() then self:Show() end
        self.needSafeStyle = true
        StartArt(self)
        return
    end

    local on = (cur >= minV) and (maxV == nil or cur <= maxV)
    if self.gateH then DriveGate(self, cur, minV, maxV) end
    self.needSafeStyle = false
    if on then
        if not self:IsShown() then self:Show() end
        StartArt(self)
    else
        StopArt(self)
        self:Hide()
    end
end

-- The aura timer widgets live on the host frame itself (never inside Art), so
-- the power gate's clipping does not touch them.
function ns.SetupTimer(self, w, h)
    -- The countdown lives inside Art (see Glow.xml); everything else refers to
    -- it as frame.TimerText, so it is aliased once here.
    if self.Art and self.Art.TimerText then
        self.TimerText = self.Art.TimerText
    end
    if self.CD then
        -- Pinned to the icon rect explicitly. The overlay is deliberately
        -- larger than the button (the proc art needs the room), and a sweep
        -- inheriting that size spills over the neighbouring buttons.
        self.CD:ClearAllPoints()
        self.CD:SetPoint("CENTER", self, "CENTER", 0, 0)
        self.CD:SetSize(w, h)
        -- The swipe is off unless asked for: the template does not turn it on,
        -- which is why a perfectly valid cooldown drew nothing at all.
        if self.CD.SetDrawSwipe then self.CD:SetDrawSwipe(true) end
        -- Blizzard's own swipe texture is left alone on purpose: overriding it
        -- with a flat one loses the circular mask the widget draws through.
        self.CD:SetDrawEdge(false)
        self.CD:SetDrawBling(false)
        self.CD:SetSwipeColor(0, 0, 0, 0.6)
        self.CD:SetHideCountdownNumbers(true)
        self.CD:SetFrameLevel(self:GetFrameLevel())
    end
    if self.TimerText then
        self.TimerText:ClearAllPoints()
        self.TimerText:SetPoint("CENTER", self.Art or self, "CENTER", 0, -h * 0.34)
        local font = self.TimerText:GetFont()
        if font then
            -- Always outlined: it sits on top of a spell icon, which can be
            -- any colour.
            self.TimerText:SetFont(font, math.max(10, math.floor(h * 0.36)), "OUTLINE")
        end
        self.TimerText:SetTextColor(1, 1, 1)
    end
end

--[[-------------------------------------------------------------------------
    Action button overlay
---------------------------------------------------------------------------]]
ComboGlowOverlayMixin = {}

function ComboGlowOverlayMixin:OnHide()
    StopArt(self)
end

function ComboGlowOverlayMixin:Attach(button)
    local w, h = button:GetSize()
    if not w or w <= 1 then w, h = 45, 45 end
    if not h or h <= 1 then h = w end

    local W, H = w * 1.8, h * 1.8

    self:SetParent(button)
    self:ClearAllPoints()
    self:SetPoint("CENTER", button, "CENTER", 0, 0)
    self:SetSize(W, H)
    self:SetFrameStrata(button:GetFrameStrata())
    self:SetFrameLevel((button:GetFrameLevel() or 1) + 6)

    self.artW, self.artH = w, h
    if self.gateH then
        ResizeGate(self, W, H)
        -- A pooled frame can arrive with the gate parked where its previous
        -- rule left it. Neutralise it, or the artwork sits a full frame away
        -- from the button until something drives it again.
        DriveGate(self, 1, 1, nil)
    else
        self.Art:SetParent(self)
        self.Art:ClearAllPoints()
        self.Art:SetAllPoints(self)
    end
    if self.Art.Wrap then
        self.Art.Wrap:SetSize(w, h)
        self.Art.Wrap:ClearAllPoints()
        self.Art.Wrap:SetPoint("CENTER", self.Art, "CENTER", 0, 0)
    end
    self.Art.Proc:SetSize(w * 1.4, h * 1.4)
    self.Art.Border:SetSize(w * 1.4, h * 1.4)
    if self.Art.Highlight then self.Art.Highlight:SetSize(w, h) end
    ns.SetupTimer(self, w, h)
end

ComboGlowOverlayMixin.SetStyle    = SetStyle
ComboGlowOverlayMixin.SetArtColor = SetArtColor
ComboGlowOverlayMixin.ApplyState = ApplyState
ComboGlowOverlayMixin.StartArt   = StartArt
ComboGlowOverlayMixin.StopArt    = StopArt

--[[-------------------------------------------------------------------------
    Center screen icon
---------------------------------------------------------------------------]]
ComboGlowCenterIconMixin = {}

function ComboGlowCenterIconMixin:OnHide()
    StopArt(self)
end

function ComboGlowCenterIconMixin:Setup(size, iconID)
    local W, H = size * 1.8, size * 1.8
    self:SetSize(W, H)
    self.artW, self.artH = size, size
    if self.gateH then
        ResizeGate(self, W, H)
        DriveGate(self, 1, 1, nil)
    else
        self.Art:SetParent(self)
        self.Art:ClearAllPoints()
        self.Art:SetAllPoints(self)
    end
    if self.Art.Wrap then
        self.Art.Wrap:SetSize(size, size)
        self.Art.Wrap:ClearAllPoints()
        self.Art.Wrap:SetPoint("CENTER", self.Art, "CENTER", 0, 0)
    end
    self.Art.Icon:SetSize(size, size)
    self.Art.Icon:SetTexture(iconID or 134400)
    self.Art.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    self.Art.Proc:SetSize(size * 1.4, size * 1.4)
    self.Art.Border:SetSize(size * 1.4, size * 1.4)
    if self.Art.Highlight then self.Art.Highlight:SetSize(size, size) end
    ns.SetupTimer(self, size, size)

    -- These icons are smaller than an action button and are read at a glance
    -- from the corner of the eye, so the countdown gets proportionally more
    -- room than it does on the bar.
    if self.TimerText then
        local font = self.TimerText:GetFont()
        if font then
            self.TimerText:SetFont(font, math.max(12, math.floor(size * 0.46)), "OUTLINE")
        end
        self.TimerText:ClearAllPoints()
        self.TimerText:SetPoint("CENTER", self.Art or self, "CENTER", 0, -size * 0.30)
    end
end

ComboGlowCenterIconMixin.SetStyle    = SetStyle
ComboGlowCenterIconMixin.SetArtColor = SetArtColor
ComboGlowCenterIconMixin.ApplyState = ApplyState
ComboGlowCenterIconMixin.StartArt   = StartArt
ComboGlowCenterIconMixin.StopArt    = StopArt
