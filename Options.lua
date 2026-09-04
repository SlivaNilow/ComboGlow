--[[---------------------------------------------------------------------------
    ComboGlow - Options.lua

    One row per SPELL, not per rule. A spell can carry three states (up, gone,
    ready/proc) and listing them as three separate rows made the same icon
    appear three times and hid the fact that states exist at all. Internally
    each state is still its own rule; this window just groups them.

    Every gallery tile is a LIVE preview: a real overlay from the same
    template, running the same code as the bar, drawn on the spell's own icon.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...
local CG = ns.CG

local ROWS       = 12      -- visible spell rows before the wheel scrolls
local ROW_H      = 22
local TILE       = 46      -- preview icon size
local TILE_PAD_X = 92
local TILE_PAD_Y = 74
local COLS       = 4

local UI, offset = nil, 0
local selSpell, selSlot = nil, "active"

local function L(en, ru) return ns.L(en, ru) end

local SLOTS = { "active", "missing", "ready" }

--[[-------------------------------------------------------------------------
    Small helpers -- plain frames and textures, no backdrop template needed
---------------------------------------------------------------------------]]
local function Panel(parent, r, g, b, a)
    local f = CreateFrame("Frame", nil, parent)
    local tex = f:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(f)
    tex:SetColorTexture(r or 0.06, g or 0.06, b or 0.07, a or 0.95)
    f.bg = tex
    return f
end

local function Line(parent, r, g, b, a)
    local tex = parent:CreateTexture(nil, "BORDER")
    tex:SetColorTexture(r or 1, g or 1, b or 1, a or 0.10)
    return tex
end

local function Label(parent, text, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local font = fs:GetFont()
    if font and size then fs:SetFont(font, size, "") end
    fs:SetText(text or "")
    fs:SetTextColor(r or 1, g or 1, b or 1)
    return fs
end

local function TextButton(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    bg:SetColorTexture(1, 1, 1, 0.07)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    b.text = fs
    b:SetScript("OnEnter", function() bg:SetColorTexture(0.05, 0.82, 0.62, 0.35) end)
    b:SetScript("OnLeave", function() bg:SetColorTexture(1, 1, 1, 0.07) end)
    b:SetScript("OnClick", onClick)
    return b
end

--[[-------------------------------------------------------------------------
    Selection
---------------------------------------------------------------------------]]
-- Distinct spells, in the order their first rule appears.
local function SpellList()
    local list, seen = {}, {}
    for _, r in ipairs(CG:GetRules()) do
        if r.spell and not seen[r.spell] then
            seen[r.spell] = true
            list[#list + 1] = r.spell
        end
    end
    return list
end

local function CurrentRule()
    if not selSpell then return nil end
    return ns.FindSlotRule(selSpell, selSlot)
end

-- Keeps the selection pointing at something that exists.
local function Normalise()
    local list = SpellList()
    if #list == 0 then
        selSpell = nil
        return list
    end
    local ok = false
    for _, id in ipairs(list) do
        if id == selSpell then ok = true break end
    end
    if not ok then selSpell = list[1] end

    if not ns.FindSlotRule(selSpell, selSlot) then
        for _, slot in ipairs(SLOTS) do
            if ns.FindSlotRule(selSpell, slot) then
                selSlot = slot
                break
            end
        end
    end
    return list
end

--[[-------------------------------------------------------------------------
    Refresh
---------------------------------------------------------------------------]]
local function RefreshRows(list)
    local total = #list
    local maxOffset = math.max(0, total - ROWS)
    if offset > maxOffset then offset = maxOffset end

    for i = 1, ROWS do
        local row = UI.rows[i]
        local spell = list[i + offset]
        if not spell then
            row:Hide()
        else
            row.spell = spell
            row.icon:SetTexture(ns.SpellIcon(spell))
            row.text:SetText(ns.SpellName(spell))
            row.sel:SetShown(spell == selSpell)
            -- Three pips: which states this spell has configured.
            for j, slot in ipairs(SLOTS) do
                local has = ns.FindSlotRule(spell, slot) ~= nil
                row.pips[j]:SetAlpha(has and 1 or 0.15)
            end
            row:Show()
        end
    end
    UI.empty:SetShown(total == 0)
end

local function RefreshTiles()
    local rule = CurrentRule()
    local r, g, b, alphaSrc, thick
    if rule then
        r, g, b, alphaSrc, thick = rule.r, rule.g, rule.b, rule.alpha, rule.thick
    else
        -- Nothing configured for this state yet: the gallery still previews,
        -- and clicking a tile is what creates it.
        local d = ns.STATE_DEFAULTS[selSlot] or ns.STATE_DEFAULTS.active
        r, g, b, thick = d.r, d.g, d.b, 3
    end

    for _, tile in ipairs(UI.tiles) do
        if not selSpell then
            tile:Hide()
        else
            tile:Show()
            tile.icon:SetTexture(ns.SpellIcon(selSpell))
            tile.overlay:SetStyle(tile.styleKey, r, g, b, tile.defAlpha or alphaSrc, thick)
            tile.overlay.needSafeStyle = false
            tile.overlay:Show()
            tile.overlay:StartArt()
            tile.sel:SetShown(rule ~= nil and rule.style == tile.styleKey)
            tile:SetAlpha(rule and 1 or 0.55)
        end
    end
end

local function RefreshDetails()
    local rule = CurrentRule()

    if selSpell then
        UI.title:SetText(ns.SpellName(selSpell))
        UI.titleIcon:SetTexture(ns.SpellIcon(selSpell))
        UI.titleIcon:Show()
    else
        UI.title:SetText(L("no spell selected", "заклинание не выбрано"))
        UI.titleIcon:Hide()
    end

    UI.hint:SetText(rule and L("pick a marker for this state", "выбери отметку для этого состояния")
                         or L("state not set up - click a marker to add it",
                              "состояние не настроено — кликни отметку, чтобы добавить"))

    for _, t in ipairs(UI.toggles) do
        if not rule or (t.auraOnly and rule.kind ~= "aura") then
            t:Hide()
        else
            t:Show()
            t.check:SetShown(t.get(rule) and true or false)
        end
    end

    -- Which aura this state watches (aura states only).
    if not rule or rule.kind ~= "aura" then
        UI.auraRow:Hide()
        UI.auraList:Hide()
    else
        UI.auraRow:Show()
        local watching = rule.auraID and ns.SpellName(rule.auraID)
            or rule.auraName
            or L("its own aura", "своя аура")
        UI.auraRow.label:SetText(L("watching: ", "следит за: ") .. "|cffffd100" .. watching .. "|r")
    end

    -- Slot strip: bright = editing, lit = configured, dim = empty.
    for _, b in ipairs(UI.slots) do
        if not selSpell then
            b:Hide()
        else
            b:Show()
            local has = ns.FindSlotRule(selSpell, b.slot) ~= nil
            if b.slot == selSlot then
                b.bg:SetColorTexture(0.05, 0.82, 0.62, 0.35)
                b.text:SetTextColor(1, 1, 1)
            elseif has then
                b.bg:SetColorTexture(1, 1, 1, 0.12)
                b.text:SetTextColor(0.85, 0.85, 0.85)
            else
                b.bg:SetColorTexture(1, 1, 1, 0.04)
                b.text:SetTextColor(0.45, 0.45, 0.45)
            end
        end
    end

    UI.del.text:SetText(rule and L("Delete state", "Удалить состояние")
                             or L("Delete spell", "Удалить заклинание"))
end

local function Refresh()
    if not UI or not UI:IsShown() then return end
    local list = Normalise()
    RefreshRows(list)
    RefreshTiles()
    RefreshDetails()
end
ns.RefreshOptions = Refresh

--[[-------------------------------------------------------------------------
    Build
---------------------------------------------------------------------------]]
local function Build()
    UI = Panel(UIParent, 0.05, 0.05, 0.06, 0.96)
    UI:SetSize(680, 444)
    UI:SetPoint("CENTER")
    UI:SetMovable(true)
    UI:EnableMouse(true)
    UI:SetClampedToScreen(true)
    UI:RegisterForDrag("LeftButton")
    UI:SetScript("OnDragStart", UI.StartMoving)
    UI:SetScript("OnDragStop", UI.StopMovingOrSizing)
    UI:SetFrameStrata("DIALOG")
    UI:Hide()
    tinsert(UISpecialFrames, "ComboGlowOptionsFrame")
    _G.ComboGlowOptionsFrame = UI

    local header = Label(UI, "|cff0cd29fComboGlow|r", 15)
    header:SetPoint("TOPLEFT", 14, -12)

    UI.hint = Label(UI, "", 11, 0.6, 0.6, 0.6)
    UI.hint:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)

    local close = TextButton(UI, "X", 22, 22, function() UI:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -10)

    local div = Line(UI)
    div:SetPoint("TOPLEFT", 250, -54)
    div:SetPoint("BOTTOMLEFT", 250, 44)
    div:SetWidth(1)

    -- Spell list ------------------------------------------------------------
    UI.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, UI)
        row:SetSize(228, ROW_H)
        row:SetPoint("TOPLEFT", 12, -58 - (i - 1) * ROW_H)

        local sel = row:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints(row)
        sel:SetColorTexture(0.05, 0.82, 0.62, 0.20)
        sel:Hide()
        row.sel = sel

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ROW_H - 4, ROW_H - 4)
        icon:SetPoint("LEFT", 2, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon = icon

        -- Three pips on the right: at a glance, which states are set up.
        row.pips = {}
        local pipColors = { { 0, 1, 0 }, { 1, 0, 0 }, { 1, 0.85, 0.1 } }
        for j = 1, 3 do
            local p = row:CreateTexture(nil, "OVERLAY")
            p:SetSize(6, 6)
            p:SetPoint("RIGHT", row, "RIGHT", -4 - (3 - j) * 9, 0)
            p:SetColorTexture(unpack(pipColors[j]))
            row.pips[j] = p
        end

        local text = Label(row, "", 11)
        text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -32, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        row.text = text

        row:SetScript("OnClick", function(self)
            selSpell = self.spell
            Refresh()
        end)
        UI.rows[i] = row
    end

    UI:EnableMouseWheel(true)
    UI:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta)
        Refresh()
    end)

    UI.empty = Label(UI, L("nothing here yet - use the buttons below",
                           "пока пусто — используй кнопки внизу"), 11, 0.7, 0.7, 0.7)
    UI.empty:SetPoint("TOPLEFT", 14, -62)

    -- Selected spell --------------------------------------------------------
    UI.titleIcon = UI:CreateTexture(nil, "ARTWORK")
    UI.titleIcon:SetSize(20, 20)
    UI.titleIcon:SetPoint("TOPLEFT", 264, -56)
    UI.titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    UI.title = Label(UI, "", 13)
    UI.title:SetPoint("LEFT", UI.titleIcon, "RIGHT", 6, 0)

    -- State slots -----------------------------------------------------------
    UI.slots = {}
    local slotDefs = {
        { key = "active",  label = L("up", "висит") },
        { key = "missing", label = L("gone", "нет") },
        { key = "ready",   label = L("ready / proc", "готово / прок") },
    }
    for i, def in ipairs(slotDefs) do
        local b = CreateFrame("Button", nil, UI)
        b:SetSize(120, 20)
        b:SetPoint("TOPLEFT", 264 + (i - 1) * 126, -80)
        b.slot = def.key

        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(b)
        bg:SetColorTexture(1, 1, 1, 0.06)
        b.bg = bg

        local fs = Label(b, def.label, 11, 0.8, 0.8, 0.8)
        fs:SetPoint("CENTER")
        b.text = fs

        -- Selecting an empty state does NOT create a rule: picking a marker
        -- does. Otherwise merely looking around litters the spec with rules.
        b:SetScript("OnClick", function(self)
            selSlot = self.slot
            Refresh()
        end)
        UI.slots[i] = b
    end

    -- Which aura this state watches -----------------------------------------
    -- Some spells apply another spell's debuff: Primal Wrath puts Rip on
    -- everything, and every class has a pair like it. The button then has no
    -- aura of its own, so the state has to be pointed at the other spell's.
    UI.auraRow = CreateFrame("Button", nil, UI)
    UI.auraRow:SetSize(378, 18)
    UI.auraRow:SetPoint("TOPLEFT", 264, -104)
    local arBg = UI.auraRow:CreateTexture(nil, "BACKGROUND")
    arBg:SetAllPoints(UI.auraRow)
    arBg:SetColorTexture(1, 1, 1, 0.05)
    UI.auraRow.label = Label(UI.auraRow, "", 11, 0.75, 0.75, 0.75)
    UI.auraRow.label:SetPoint("LEFT", 4, 0)
    UI.auraRow:SetScript("OnEnter", function() arBg:SetColorTexture(0.05, 0.82, 0.62, 0.25) end)
    UI.auraRow:SetScript("OnLeave", function() arBg:SetColorTexture(1, 1, 1, 0.05) end)

    UI.auraList = Panel(UI, 0.08, 0.08, 0.09, 0.98)
    UI.auraList:SetSize(378, 10)
    UI.auraList:SetPoint("TOPLEFT", UI.auraRow, "BOTTOMLEFT", 0, -2)
    UI.auraList:SetFrameStrata("FULLSCREEN_DIALOG")
    UI.auraList:Hide()
    UI.auraList.entries = {}
    for i = 1, 12 do
        local e = CreateFrame("Button", nil, UI.auraList)
        e:SetSize(370, 18)
        e:SetPoint("TOPLEFT", 4, -2 - (i - 1) * 18)
        local ebg = e:CreateTexture(nil, "BACKGROUND")
        ebg:SetAllPoints(e)
        ebg:SetColorTexture(1, 1, 1, 0)
        e:SetScript("OnEnter", function() ebg:SetColorTexture(0.05, 0.82, 0.62, 0.25) end)
        e:SetScript("OnLeave", function() ebg:SetColorTexture(1, 1, 1, 0) end)
        e.label = Label(e, "", 11, 0.9, 0.9, 0.9)
        e.label:SetPoint("LEFT", 4, 0)
        e:SetScript("OnClick", function(self)
            local rule = CurrentRule()
            if rule then
                rule.auraID = self.spellID
                rule.auraName = nil
                CG:Rebuild()
            end
            UI.auraList:Hide()
            Refresh()
        end)
        UI.auraList.entries[i] = e
    end

    UI.auraRow:SetScript("OnClick", function()
        if UI.auraList:IsShown() then UI.auraList:Hide() return end
        if not selSpell then return end

        local seen, list = {}, { { id = nil, name = L("its own aura", "своя аура") } }
        seen[selSpell] = true
        for _, r in ipairs(CG:GetRules()) do
            if r.spell and not seen[r.spell] then
                seen[r.spell] = true
                list[#list + 1] = { id = r.spell, name = ns.SpellName(r.spell) }
            end
        end

        for i, e in ipairs(UI.auraList.entries) do
            local item = list[i]
            if item then
                e.spellID = item.id
                e.label:SetText(item.name)
                e:Show()
            else
                e:Hide()
            end
        end
        UI.auraList:SetHeight(math.min(#list, 12) * 18 + 6)
        UI.auraList:Show()
    end)

    -- Marker gallery --------------------------------------------------------
    UI.tiles = {}
    local gallery = {}
    for _, style in ipairs(ns.STYLES) do
        if not style.hidden then gallery[#gallery + 1] = style end
    end

    for i, style in ipairs(gallery) do
        local col = (i - 1) % COLS
        local rowN = math.floor((i - 1) / COLS)

        local tile = CreateFrame("Button", nil, UI)
        tile:SetSize(TILE + 26, TILE + 26)
        tile:SetPoint("TOPLEFT", 264 + col * TILE_PAD_X, -130 - rowN * TILE_PAD_Y)
        tile.styleKey = style.key
        tile.defAlpha = style.defAlpha

        local sel = tile:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints(tile)
        sel:SetColorTexture(0.05, 0.82, 0.62, 0.25)
        sel:Hide()
        tile.sel = sel

        local icon = tile:CreateTexture(nil, "ARTWORK")
        icon:SetSize(TILE, TILE)
        icon:SetPoint("TOP", 0, -4)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        tile.icon = icon

        local host = CreateFrame("Frame", nil, tile)
        host:SetSize(TILE, TILE)
        host:SetPoint("TOP", 0, -4)
        tile.host = host

        local ov = CreateFrame("Frame", nil, host, "ComboGlowOverlayTemplate")
        ov:Attach(host)
        ov.TimerText:Hide()
        tile.overlay = ov

        local name = Label(tile, style.short or style.label, 10, 0.75, 0.75, 0.75)
        name:SetPoint("BOTTOM", 0, 2)
        name:SetPoint("LEFT", 2, 0)
        name:SetPoint("RIGHT", -2, 0)
        name:SetJustifyH("CENTER")
        name:SetWordWrap(false)

        tile:SetScript("OnClick", function(self)
            if not selSpell then return end
            -- Clicking a marker on an empty state is what creates it: one
            -- click instead of hunting for an "add" button.
            local rule = CurrentRule()
            if not rule then
                rule = ns.AddSlotRule(selSpell, selSlot)
                if not rule then return end
            end
            rule.style = self.styleKey
            if self.defAlpha then rule.alpha = self.defAlpha end
            CG:Rebuild()
            Refresh()
        end)
        UI.tiles[i] = tile
    end

    -- Toggles ---------------------------------------------------------------
    UI.toggles = {}
    local defs = {
        { key = "enabled", auraOnly = false, label = L("state on", "состояние вкл"),
          get = function(r) return r.enabled ~= false end,
          set = function(r) r.enabled = not (r.enabled ~= false) end },
        { key = "timer", auraOnly = true, label = L("timer", "таймер"),
          get = function(r) return r.timer ~= false end,
          set = function(r) r.timer = not (r.timer ~= false) end },
        { key = "orProc", auraOnly = false, label = L("also on proc", "также по проку"),
          get = function(r) return r.kind ~= "aura" and r.orProc ~= false end,
          set = function(r) if r.kind ~= "aura" then r.orProc = not (r.orProc ~= false) end end },
        { key = "center", auraOnly = false, label = L("centre icon", "иконка в центре"),
          get = function(r) return r.center end,
          set = function(r) r.center = not r.center end },
    }

    for i, def in ipairs(defs) do
        local t = CreateFrame("Button", nil, UI)
        t:SetSize(126, 18)
        t:SetPoint("TOPLEFT", 264 + ((i - 1) % 3) * 132,
                   -130 - 2 * TILE_PAD_Y - 10 - math.floor((i - 1) / 3) * 22)
        t.auraOnly = def.auraOnly
        t.get = def.get

        local box = t:CreateTexture(nil, "BACKGROUND")
        box:SetSize(12, 12)
        box:SetPoint("LEFT")
        box:SetColorTexture(1, 1, 1, 0.12)

        local check = t:CreateTexture(nil, "ARTWORK")
        check:SetSize(8, 8)
        check:SetPoint("CENTER", box, "CENTER")
        check:SetColorTexture(0.05, 0.82, 0.62, 1)
        check:Hide()
        t.check = check

        local fs = Label(t, def.label, 11, 0.85, 0.85, 0.85)
        fs:SetPoint("LEFT", box, "RIGHT", 5, 0)

        t:SetScript("OnClick", function()
            local rule = CurrentRule()
            if not rule then return end
            def.set(rule)
            CG:Rebuild()
            Refresh()
        end)
        UI.toggles[i] = t
    end

    -- Bottom bar ------------------------------------------------------------
    local bottom = Line(UI)
    bottom:SetPoint("BOTTOMLEFT", 12, 38)
    bottom:SetPoint("BOTTOMRIGHT", -12, 38)
    bottom:SetHeight(1)

    local bPreset = TextButton(UI, L("Scan bars", "Сканировать панели"), 130, 22, function()
        if ns.BuildPreset then ns.BuildPreset() end
        Refresh()
    end)
    bPreset:SetPoint("BOTTOMLEFT", 12, 10)

    local bDot = TextButton(UI, L("Add last cast", "Добавить последний каст"), 160, 22, function()
        if not CG.lastCast then
            if ns.Say then ns.Say(L("cast something first", "сначала примени способность")) end
            return
        end
        selSpell = CG.lastCast
        selSlot = "active"
        ns.AddSlotRule(CG.lastCast, "active")
        Refresh()
    end)
    bDot:SetPoint("LEFT", bPreset, "RIGHT", 8, 0)

    UI.del = TextButton(UI, "", 140, 22, function()
        local rules = CG:GetRules()
        local rule, idx = CurrentRule()
        if rule and idx then
            table.remove(rules, idx)
        elseif selSpell then
            -- No rule in this state: the button removes the whole spell.
            for i = #rules, 1, -1 do
                if rules[i].spell == selSpell then table.remove(rules, i) end
            end
            selSpell = nil
        end
        CG:Rebuild()
        Refresh()
    end)
    UI.del:SetPoint("BOTTOMRIGHT", -12, 10)

    UI:SetScript("OnHide", function()
        for _, tile in ipairs(UI.tiles) do
            if tile.overlay then tile.overlay:StopArt() end
        end
    end)
end

function ns.ToggleOptions()
    if not UI then Build() end
    if UI:IsShown() then
        UI:Hide()
    else
        UI:Show()
        Refresh()
    end
end
