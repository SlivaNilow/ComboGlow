--[[---------------------------------------------------------------------------
    ComboGlow - Options.lua

    A rule list on the left, a gallery of the ready-made markers on the right.
    Every tile is a LIVE preview: a real overlay from the same template, running
    the same code as the bar, drawn on the rule's own spell icon. Picking a look
    is then a matter of looking at it, not of remembering a keyword.
-----------------------------------------------------------------------------]]

local ADDON, ns = ...
local CG = ns.CG

local ROWS       = 12      -- visible rule rows before the wheel scrolls
local ROW_H      = 22
local TILE       = 46      -- preview icon size
local TILE_PAD_X = 92
local TILE_PAD_Y = 74
local COLS       = 4

local UI, selected, offset = nil, 1, 0

local function L(en, ru) return ns.L(en, ru) end

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
    Refresh
---------------------------------------------------------------------------]]
local function CurrentRule()
    local rules = CG:GetRules()
    return rules[selected], rules
end

local function RefreshRows()
    local rules = CG:GetRules()
    local total = #rules
    if selected > total then selected = total end
    if selected < 1 then selected = 1 end

    local maxOffset = math.max(0, total - ROWS)
    if offset > maxOffset then offset = maxOffset end

    for i = 1, ROWS do
        local row = UI.rows[i]
        local idx = i + offset
        local rule = rules[idx]
        if not rule then
            row:Hide()
        else
            row.index = idx
            row.icon:SetTexture(ns.SpellIcon(rule.spell))
            local kind
            if rule.kind ~= "aura" then
                kind = L("ready / proc", "готово / прок")
            elseif rule.proc then
                kind = L("proc", "прок")
            elseif rule.missing then
                kind = L("gone", "нет")
            else
                kind = L("up", "висит")
            end
            row.text:SetText(("%d. %s |cff888888(%s)|r"):format(idx, ns.SpellName(rule.spell), kind))
            row.text:SetTextColor(rule.enabled == false and 0.5 or 1,
                                  rule.enabled == false and 0.5 or 1,
                                  rule.enabled == false and 0.5 or 1)
            row.sel:SetShown(idx == selected)
            row:Show()
        end
    end
    UI.empty:SetShown(total == 0)
end

local function RefreshTiles()
    local rule = CurrentRule()
    for _, tile in ipairs(UI.tiles) do
        if not rule then
            tile:Hide()
        else
            tile:Show()
            tile.icon:SetTexture(ns.SpellIcon(rule.spell))
            -- Same overlay code as the action bar, so what you see here is
            -- exactly what lands on the button.
            local alpha = tile.defAlpha or rule.alpha
            tile.overlay:SetStyle(tile.styleKey, rule.r, rule.g, rule.b, alpha, rule.thick)
            tile.overlay.needSafeStyle = false
            tile.overlay:Show()
            tile.overlay:StartArt()
            -- The time-shaped markers have nothing to show standing still, so
            -- the preview runs a dummy countdown.
            if tile.styleKey == "swipe" or tile.styleKey == "ring" then
                tile.overlay.CD:SetDrawEdge(tile.styleKey == "ring")
                tile.overlay.CD:Show()
                tile.overlay.CD:SetCooldown(GetTime() - 12, 20)
            else
                tile.overlay.CD:Hide()
            end
            tile.sel:SetShown(rule.style == tile.styleKey)
        end
    end
end

local function RefreshToggles()
    local rule = CurrentRule()
    for _, t in ipairs(UI.toggles) do
        if not rule or (t.auraOnly and rule.kind ~= "aura") then
            t:Hide()
        else
            t:Show()
            t.check:SetShown(t.get(rule) and true or false)
        end
    end
    if rule then
        UI.title:SetText(ns.SpellName(rule.spell))
        UI.titleIcon:SetTexture(ns.SpellIcon(rule.spell))
        UI.titleIcon:Show()
    else
        UI.title:SetText(L("no rule selected", "правило не выбрано"))
        UI.titleIcon:Hide()
    end

    -- Which aura the rule watches.
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

    -- Slot strip: lit = a rule exists, brightest = the one being edited.
    for _, b in ipairs(UI.slots) do
        if not rule then
            b:Hide()
        else
            b:Show()
            local slotRule, idx = ns.FindSlotRule(rule.spell, b.slot)
            local current = idx == selected
            if current then
                b.bg:SetColorTexture(0.05, 0.82, 0.62, 0.35)
                b.text:SetTextColor(1, 1, 1)
            elseif slotRule then
                b.bg:SetColorTexture(1, 1, 1, 0.12)
                b.text:SetTextColor(0.85, 0.85, 0.85)
            else
                b.bg:SetColorTexture(1, 1, 1, 0.04)
                b.text:SetTextColor(0.45, 0.45, 0.45)
            end
        end
    end
end

local function Refresh()
    if not UI or not UI:IsShown() then return end
    RefreshRows()
    RefreshTiles()
    RefreshToggles()
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

    local hint = Label(UI, L("pick a marker for the selected rule", "выбери отметку для выбранного правила"), 11, 0.6, 0.6, 0.6)
    hint:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)

    local close = TextButton(UI, "X", 22, 22, function() UI:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -10)

    local div = Line(UI)
    div:SetPoint("TOPLEFT", 250, -54)
    div:SetPoint("BOTTOMLEFT", 250, 44)
    div:SetWidth(1)

    -- Rule list ------------------------------------------------------------
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

        local text = Label(row, "", 11)
        text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        text:SetJustifyH("LEFT")
        row.text = text

        row:SetScript("OnClick", function(self)
            selected = self.index or 1
            Refresh()
        end)
        UI.rows[i] = row
    end

    UI:EnableMouseWheel(true)
    UI:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta)
        Refresh()
    end)

    UI.empty = Label(UI, L("no rules yet - use the buttons below", "правил нет — используй кнопки внизу"), 11, 0.7, 0.7, 0.7)
    UI.empty:SetPoint("TOPLEFT", 14, -62)

    -- Selected rule --------------------------------------------------------
    UI.titleIcon = UI:CreateTexture(nil, "ARTWORK")
    UI.titleIcon:SetSize(20, 20)
    UI.titleIcon:SetPoint("TOPLEFT", 264, -56)
    UI.titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    UI.title = Label(UI, "", 13)
    UI.title:SetPoint("LEFT", UI.titleIcon, "RIGHT", 6, 0)

    -- State slots ----------------------------------------------------------
    -- Three slots per spell, always offered. A slot with no rule behind it is
    -- dim and draws nothing; clicking it creates one.
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

        b:SetScript("OnClick", function(self)
            local rule = CurrentRule()
            if not rule then return end
            local _, idx = ns.FindSlotRule(rule.spell, self.slot)
            if not idx then
                local _, newIdx = ns.AddSlotRule(rule.spell, self.slot)
                idx = newIdx
            end
            selected = idx or selected
            Refresh()
        end)
        UI.slots[i] = b
    end

    -- Which aura this rule watches ------------------------------------------
    -- Some spells apply another spell's debuff: Primal Wrath puts Rip on
    -- everything, and every class has a pair like it. The button then has no
    -- aura of its own, so the rule has to be pointed at the other spell's.
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
        local rule = CurrentRule()
        if not rule then return end

        -- Candidates: itself, plus every other spell this spec has a rule for.
        local seen, list = {}, { { id = nil, name = L("its own aura", "своя аура") } }
        seen[rule.spell] = true
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

    -- Marker gallery -------------------------------------------------------
    UI.tiles = {}
    -- Only the visually distinct ones. Several EllesmereUI engines land on the
    -- same "green glow" or "green dashes" once tinted, and a gallery of
    -- lookalikes is worse than a short list; the rest stay reachable through
    -- /cg style.
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

        -- Short one-line names: the full ones wrapped onto three lines and
        -- covered the preview they were labelling.
        local name = Label(tile, style.short or style.label, 10, 0.75, 0.75, 0.75)
        name:SetPoint("BOTTOM", 0, 2)
        name:SetPoint("LEFT", 2, 0)
        name:SetPoint("RIGHT", -2, 0)
        name:SetJustifyH("CENTER")
        name:SetWordWrap(false)

        tile.defAlpha = style.defAlpha
        tile:SetScript("OnClick", function(self)
            local rule = CurrentRule()
            if not rule then return end
            rule.style = self.styleKey
            -- Each marker carries the brightness that suits it: a wash at the
            -- frame's full opacity hides the icon completely.
            if self.defAlpha then rule.alpha = self.defAlpha end
            CG:Rebuild()
            Refresh()
        end)
        UI.tiles[i] = tile
    end

    -- Toggles --------------------------------------------------------------
    UI.toggles = {}
    local defs = {
        { key = "enabled", auraOnly = false, label = L("rule on", "правило вкл"),
          get = function(r) return r.enabled ~= false end,
          set = function(r) r.enabled = not (r.enabled ~= false) end },
        -- The state itself is picked in the slot strip above, not here, so two
        -- rules can never end up claiming the same slot.
        { key = "orProc", auraOnly = false, label = L("also on proc", "также по проку"),
          get = function(r) return r.kind ~= "aura" and r.orProc ~= false end,
          set = function(r) if r.kind ~= "aura" then r.orProc = not (r.orProc ~= false) end end },
        { key = "timer", auraOnly = true, label = L("timer", "таймер"),
          get = function(r) return r.timer ~= false end,
          set = function(r) r.timer = not (r.timer ~= false) end },
        { key = "center", auraOnly = false, label = L("centre icon", "иконка в центре"),
          get = function(r) return r.center end,
          set = function(r) r.center = not r.center end },
    }

    for i, def in ipairs(defs) do
        local t = CreateFrame("Button", nil, UI)
        t:SetSize(126, 18)
        t:SetPoint("TOPLEFT", 264 + ((i - 1) % 3) * 132, -130 - 2 * TILE_PAD_Y - 10 - math.floor((i - 1) / 3) * 22)
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

    -- Bottom bar -----------------------------------------------------------
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
        if ns.AddAuraRuleFor and CG.lastCast then
            ns.AddAuraRuleFor(CG.lastCast)
            Refresh()
        elseif ns.Say then
            ns.Say(L("cast something first", "сначала примени способность"))
        end
    end)
    bDot:SetPoint("LEFT", bPreset, "RIGHT", 8, 0)

    local bDel = TextButton(UI, L("Delete rule", "Удалить правило"), 120, 22, function()
        local rule, rules = CurrentRule()
        if not rule then return end
        table.remove(rules, selected)
        CG:Rebuild()
        Refresh()
    end)
    bDel:SetPoint("BOTTOMRIGHT", -12, 10)

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
