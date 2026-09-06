--[[---------------------------------------------------------------------------
    ComboGlow - Options.lua

    One row per SPELL, not per rule. A spell can carry several states and
    listing them as separate rows made the same icon appear several times and
    hid the fact that states exist at all. Internally each state is still its
    own rule; this window just groups them.

    The proc state is shown for one thing only: pointing it at the buffs behind
    it. Its detection and its marker look after themselves.

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

-- Proc is here for one reason: pointing the state at the buffs behind it, for
-- the spells whose cost cannot answer. Its marker needs no choosing -- it is
-- kept the same cyan frame unless one is picked by hand.
local SLOTS = { "active", "missing", "ready", "proc" }

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

-- Where the early-gone threshold is stored, which is not where it is edited.
-- It belongs to "gone" -- that state consumes it -- but it is set from the
-- "up" tab, because that is where you are looking at an aura that is still on
-- the target and deciding when to stop calling it that. Same boundary from the
-- other side.
local function SoonRule()
    if not selSpell then return nil end
    local rule = CurrentRule()
    if not rule or rule.kind ~= "aura" or rule.proc or rule.missing then return nil end
    return ns.FindSlotRule(selSpell, "missing")
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
            -- Which states this spell has configured.
            for j, slot in ipairs(SLOTS) do
                local has = ns.FindSlotRule(spell, slot) ~= nil
                row.pips[j]:SetAlpha(has and 1 or 0.15)
            end
            row:Show()
        end
    end
    UI.empty:SetShown(total == 0)

    local nAura, nEss = 0, 0
    for _ in pairs(ns.cdmAuraSpells or {}) do nAura = nAura + 1 end
    for _ in pairs(ns.cdmEssentialSpells or {}) do nEss = nEss + 1 end
    if nAura == 0 then
        UI.source:SetText("|cffff6060" .. L("Cooldown Manager tracks no auras for this spec",
                                            "Cooldown Manager не отслеживает аур в этом спеке") .. "|r")
    else
        UI.source:SetText(L("Cooldown Manager: %d auras, %d cooldowns",
                            "Cooldown Manager: аур %d, кулдаунов %d"):format(nAura, nEss))
    end
    UI.onBars.text:SetText(CG.db.showBars ~= false
        and L("marking: action bars ON", "отмечать: панели ВКЛ")
        or L("marking: action bars off", "отмечать: панели выкл"))
    UI.onCDM.text:SetText(CG.db.cdm
        and L("marking: Cooldown Manager ON", "отмечать: Cooldown Manager ВКЛ")
        or L("marking: Cooldown Manager off", "отмечать: Cooldown Manager выкл"))
    UI.hideCDM.text:SetText(CG.db.hideCDM
        and L("show the Cooldown Manager", "показать Cooldown Manager")
        or L("hide the Cooldown Manager", "скрыть Cooldown Manager"))
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
            if tile.styleKey == false then
                -- The "no marker" tile: the icon, and nothing drawn over it.
                tile.overlay:StopArt()
                tile.overlay:Hide()
                tile.sel:SetShown(rule ~= nil and rule.enabled == false)
                tile.sel2:Hide()
            else
                tile.overlay:SetStyle(tile.styleKey, r, g, b, tile.defAlpha or alphaSrc, thick)
                tile.overlay.needSafeStyle = false
                tile.overlay:Show()
                tile.overlay:StartArt()
                local on = rule ~= nil and rule.enabled ~= false
                tile.sel:SetShown(on and rule.style == tile.styleKey)
                tile.sel2:SetShown(on and rule.style2 == tile.styleKey)
            end
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

    local hint
    if rule then
        hint = L("pick a marker for this state", "выбери отметку для этого состояния")
    elseif selSpell and not ns.CanAddSlot(selSpell, selSlot) then
        hint = L("nothing to be ready for: no resource cost, no cooldown",
                 "нечего ждать: ни стоимости ресурса, ни кулдауна")
    else
        hint = L("state not set up - click a marker to add it",
                 "состояние не настроено — кликни отметку, чтобы добавить")
    end
    UI.hint:SetText(hint)

    -- Said here rather than left to be discovered: an aura state whose spell
    -- the Cooldown Manager does not track cannot work at all on a target
    -- debuff, and there is nothing in the window to hint at that otherwise.
    -- Finding out which spell is missing was the whole chore.
    local blind = false
    if rule and rule.kind == "aura" and not rule.proc then
        local mf, isAuraEntry = ns.FindMirror(rule)
        blind = not (mf and isAuraEntry) and not ns.ReadsWork(rule)
    end
    if blind then
        UI.warn:SetText("|cffff6060" .. L("not tracked in the Cooldown Manager - add it there",
                                          "нет в Cooldown Manager — добавь его туда") .. "|r")
    else
        UI.warn:SetText("")
    end

    for _, t in ipairs(UI.toggles) do
        if not rule or (t.auraOnly and rule.kind ~= "aura")
           or (t.hide and t.hide(rule)) then
            t:Hide()
        else
            t:Show()
            if t.labelFor then t.fs:SetText(t.labelFor(selSlot)) end
            t.check:SetShown(t.get(rule) and true or false)
        end
    end

    -- Resource threshold, for count rules only.
    if rule and rule.kind ~= "aura" and rule.kind ~= "cd" then
        UI.countRow:Show()
        local what
        if rule.atMax then
            what = L("at maximum", "на максимуме")
        elseif rule.max and rule.max == rule.min then
            what = ("= %d"):format(rule.min)
        elseif rule.max then
            what = ("%d-%d"):format(rule.min, rule.max)
        else
            what = ("%d+"):format(rule.min or 1)
        end
        UI.countRow.label:SetText(L("lights at: ", "загорается при: ")
            .. "|cffffd100" .. what .. "|r")
    else
        UI.countRow:Hide()
    end

    -- How early to call the aura gone. Shown on the "up" tab and written to the
    -- "gone" rule -- see SoonRule. Zero is off.
    local soonRule = SoonRule()
    if soonRule then
        UI.soonRow:Show()
        local n = tonumber(soonRule.soon) or 0
        UI.soonRow.label:SetText(n > 0
            and L("countdown turns the warning colour %ds early",
                  "отсчёт краснеет за %d с до конца"):format(n)
            or L("countdown never changes colour",
                 "отсчёт не меняет цвет"))
    else
        UI.soonRow:Hide()
    end

    -- Which aura this state watches (aura states only). For a proc the same
    -- row picks the buff that makes the cast free -- plenty of procs are a
    -- plain buff and never touch the game's spell-alert API.
    if not rule or rule.kind ~= "aura" then
        UI.auraRow:Hide()
        UI.auraList:Hide()
    else
        UI.auraRow:Show()
        if rule.proc then
            local named = ns.ProcAuraText(rule)
            local watching, warn
            if (rule.baseCost or 0) > 0 and not named then
                -- The exact answer, and the one that needs no configuring:
                -- the game reports what the cast costs right now.
                watching = L("the cast costs nothing", "каст ничего не стоит")
                warn = L("by cost", "по стоимости")
            else
                watching = named or L("the game's own proc alert",
                                      "штатная подсветка прока")
                if not named then
                    warn = L("click to pick the buffs", "нажми, чтобы выбрать баффы")
                elseif not ns.ProcAurasFit(rule) then
                    warn = "|cffff6060" .. L("does not name this spell",
                                             "не называет это заклинание") .. "|r"
                else
                    warn = ""
                end
            end
            UI.auraRow.label:SetText(L("free while: ", "бесплатен, пока: ")
                .. "|cffffd100" .. watching .. "|r")
            UI.auraRow.hint:SetText(warn)
        else
            local named = ns.ProcAuraText(rule) or rule.auraName
            local watching = named or L("its own aura", "своя аура")
            UI.auraRow.label:SetText(L("watching: ", "следит за: ")
                .. "|cffffd100" .. watching .. "|r")
            UI.auraRow.hint:SetText(named and ""
                or L("click to pick auras", "нажми, чтобы выбрать ауры"))
        end
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

    UI.delSpell:SetAlpha(selSpell and 1 or 0.35)
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
    -- Taller than it started: the state panel grew a "watching" row, a warning
    -- line and an expiry threshold above the gallery, and they were landing on
    -- the tiles.
    UI:SetSize(680, 500)
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

    -- Sits with the aura row, where the state being edited is: the warning is
    -- about this spell, not about the window.
    UI.warn = Label(UI, "", 11, 1, 1, 1)
    UI.warn:SetPoint("TOPLEFT", 264, -152)
    UI.warn:SetPoint("RIGHT", UI, "LEFT", 642, 0)
    UI.warn:SetJustifyH("LEFT")

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

        -- One pip per state on the right: at a glance, which are set up.
        row.pips = {}
        local pipColors = {
            { 0, 1, 0 }, { 1, 0, 0 }, { 1, 0.85, 0.1 }, { 0.2, 0.9, 1 },
        }
        local n = #SLOTS
        for j = 1, n do
            local p = row:CreateTexture(nil, "OVERLAY")
            p:SetSize(6, 6)
            p:SetPoint("RIGHT", row, "RIGHT", -4 - (n - j) * 9, 0)
            p:SetColorTexture(unpack(pipColors[j] or pipColors[1]))
            row.pips[j] = p
        end

        local text = Label(row, "", 11)
        text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -8 - n * 9, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        row.text = text

        row:SetScript("OnClick", function(self)
            selSpell = self.spell
            -- The aura list belongs to the state that was open. Leaving it up
            -- would show the previous spell's candidates, and clicking one
            -- would apply it to this one.
            UI.auraList:Hide()
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

    -- What the scan has to work with, under the list where it is always
    -- visible. Aura states are only as good as the Cooldown Manager's tracked
    -- list, that list is per specialization, and a spec where it is empty
    -- looks exactly like a broken addon from here.
    UI.source = Label(UI, "", 10, 0.55, 0.55, 0.55)
    UI.source:SetPoint("BOTTOMLEFT", 14, 40)
    UI.source:SetPoint("RIGHT", UI, "LEFT", 246, 0)
    UI.source:SetJustifyH("LEFT")

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
        -- Ready and proc are split: one says you saved up for it, the other
        -- says this cast is free. Same button, different decision.
        { key = "ready",   label = L("ready", "готово") },
        { key = "proc",    label = L("proc", "прок") },
    }
    for i, def in ipairs(slotDefs) do
        local b = CreateFrame("Button", nil, UI)
        b:SetSize(90, 20)
        b:SetPoint("TOPLEFT", 264 + (i - 1) * 96, -80)
        b.slot = def.key

        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(b)
        bg:SetColorTexture(1, 1, 1, 0.06)
        b.bg = bg

        local fs = Label(b, def.label, 11, 0.8, 0.8, 0.8)
        fs:SetPoint("CENTER")
        b.text = fs

        -- Clicking an empty state CREATES it. Not doing so was a mistake:
        -- the slot looked dead, and everything that configures a state --
        -- the marker gallery, the "watching" row -- needs the rule to exist
        -- before it has anything to act on. An unwanted one is removed with
        -- the button below.
        b:SetScript("OnClick", function(self)
            selSlot = self.slot
            UI.auraList:Hide()
            if selSpell and not ns.FindSlotRule(selSpell, selSlot) then
                ns.AddSlotRule(selSpell, selSlot)
            end
            Refresh()
        end)
        UI.slots[i] = b
    end

    -- Which aura this state watches -----------------------------------------
    -- Some spells apply another spell's debuff: Primal Wrath puts Rip on
    -- everything, and every class has a pair like it. The button then has no
    -- aura of its own, so the state has to be pointed at the other spell's.
    UI.auraRow = CreateFrame("Button", nil, UI)
    UI.auraRow:SetSize(378, 20)
    UI.auraRow:SetPoint("TOPLEFT", 264, -104)
    local arBg = UI.auraRow:CreateTexture(nil, "BACKGROUND")
    arBg:SetAllPoints(UI.auraRow)
    arBg:SetColorTexture(1, 1, 1, 0.10)

    -- It reads as a caption unless it is framed and carries an arrow, and a
    -- control nobody recognises as a control may as well not exist.
    for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 0, nil, 1 },
                         { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, nil, 1 },
                         { "TOPLEFT", "BOTTOMLEFT", 0, 0, 1, nil },
                         { "TOPRIGHT", "BOTTOMRIGHT", 0, 0, 1, nil } }) do
        local edge = UI.auraRow:CreateTexture(nil, "BORDER")
        edge:SetColorTexture(1, 1, 1, 0.18)
        edge:SetPoint(p[1])
        edge:SetPoint(p[2])
        if p[5] then edge:SetWidth(p[5]) end
        if p[6] then edge:SetHeight(p[6]) end
    end

    UI.auraRow.arrow = Label(UI.auraRow, "▼", 10, 0.6, 0.6, 0.6)
    UI.auraRow.arrow:SetPoint("RIGHT", -6, 0)

    UI.auraRow.hint = Label(UI.auraRow, "", 10, 0.5, 0.5, 0.5)
    UI.auraRow.hint:SetPoint("RIGHT", UI.auraRow.arrow, "LEFT", -6, 0)
    UI.auraRow.hint:SetJustifyH("RIGHT")
    UI.auraRow.hint:SetWordWrap(false)

    -- Bounded by the hint on its right. Both were free to grow towards the
    -- middle and simply drew over each other there.
    UI.auraRow.label = Label(UI.auraRow, "", 11, 0.75, 0.75, 0.75)
    UI.auraRow.label:SetPoint("LEFT", 6, 0)
    UI.auraRow.label:SetPoint("RIGHT", UI.auraRow.hint, "LEFT", -8, 0)
    UI.auraRow.label:SetJustifyH("LEFT")
    UI.auraRow.label:SetWordWrap(false)

    UI.auraRow:SetScript("OnEnter", function() arBg:SetColorTexture(0.05, 0.82, 0.62, 0.30) end)
    UI.auraRow:SetScript("OnLeave", function() arBg:SetColorTexture(1, 1, 1, 0.10) end)

    UI.auraList = Panel(UI, 0.08, 0.08, 0.09, 0.98)
    UI.auraList:SetSize(378, 10)
    UI.auraList:SetPoint("TOPLEFT", UI.auraRow, "BOTTOMLEFT", 0, -2)
    UI.auraList:SetFrameStrata("FULLSCREEN_DIALOG")
    UI.auraList:Hide()
    UI.auraList.entries = {}
    local PopulateAuraList   -- assigned below; the entries call back into it
    for i = 1, 16 do
        local e = CreateFrame("Button", nil, UI.auraList)
        e:SetSize(370, 18)
        e:SetPoint("TOPLEFT", 4, -2 - (i - 1) * 18)
        local ebg = e:CreateTexture(nil, "BACKGROUND")
        ebg:SetAllPoints(e)
        ebg:SetColorTexture(1, 1, 1, 0)
        -- The game's own tooltip for the buff. A list of names says nothing
        -- about what any of them does, and "Starweaver's Warp" versus
        -- "Starweaver's Haze" is not a choice anyone can make from the names.
        e:SetScript("OnEnter", function(self)
            ebg:SetColorTexture(0.05, 0.82, 0.62, 0.25)
            if not self.spellID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellID)
            if ok then GameTooltip:Show() else GameTooltip:Hide() end
        end)
        e:SetScript("OnLeave", function()
            ebg:SetColorTexture(1, 1, 1, 0)
            GameTooltip:Hide()
        end)
        e.label = Label(e, "", 11, 0.9, 0.9, 0.9)
        e.label:SetPoint("LEFT", 4, 0)
        e:SetScript("OnClick", function(self)
            local rule = CurrentRule()
            if not rule then
                UI.auraList:Hide()
                Refresh()
                return
            end

            -- The list toggles rather than picks, for both kinds of state. A
            -- proc can have several buffs behind it, and an ordinary state can
            -- watch several auras from one cast -- Vampiric Touch applies
            -- Shadow Word: Pain as well, and both have to be up. It stays open.
            if not self.spellID then
                rule.auraIDs, rule.auraID, rule.auraName = nil, nil, nil
                if rule.proc then rule.timer = false end
            else
                local ids = rule.auraIDs
                if type(ids) ~= "table" then ids = {} end
                -- Fold in the single-id form rules were created with before
                -- the list existed, so the first toggle does not drop it.
                if rule.auraID then
                    local dup = false
                    for _, id in ipairs(ids) do
                        if id == rule.auraID then dup = true break end
                    end
                    if not dup then ids[#ids + 1] = rule.auraID end
                    rule.auraID = nil
                end
                local at
                for k, id in ipairs(ids) do
                    if id == self.spellID then at = k break end
                end
                if at then table.remove(ids, at) else ids[#ids + 1] = self.spellID end
                table.sort(ids)
                rule.auraIDs = (#ids > 0) and ids or nil
                rule.auraName = nil
                -- A proc pointed at a buff has a real duration to show; the
                -- spell-alert fallback has none, so the timer follows.
                if rule.proc then rule.timer = rule.auraIDs ~= nil end
            end
            CG:Rebuild()
            Refresh()
            PopulateAuraList()
        end)
        UI.auraList.entries[i] = e
    end

    PopulateAuraList = function()
        if not selSpell then UI.auraList:Hide() return end

        local rule = CurrentRule()
        local list
        if rule and rule.proc then
            local chosen = {}
            if type(rule.auraIDs) == "table" then
                for _, id in ipairs(rule.auraIDs) do chosen[id] = true end
            end
            -- Candidates are the player buffs the Cooldown Manager tracks:
            -- Blizzard's own list of what matters for the spec, so there is
            -- nothing hardcoded and it follows talent and patch changes.
            -- Deduped by name -- one buff is registered under its own id, its
            -- override and every linked id, all with the same name.
            list = { { id = nil, name = L("the game's own proc alert",
                                          "штатная подсветка прока") } }
            local names, rest = {}, {}
            for id in pairs(ns.cdmAuraSpells or {}) do
                local nm = ns.SpellName(id)
                if nm and not nm:find("^spell:") and not names[nm] then
                    local harmful = false
                    if C_Spell and C_Spell.IsSpellHarmful then
                        local okH, v = pcall(C_Spell.IsSpellHarmful, id)
                        if okH and v then harmful = true end
                    end
                    if not harmful then
                        names[nm] = true
                        -- Marked and sorted first when the buff's description
                        -- mentions this spell -- a hint about where to look,
                        -- not a verdict. A buff can name a spell because the
                        -- spell TRIGGERS it: Starlord and Starweaver both name
                        -- Starsurge and neither makes it free. The tooltip on
                        -- hover is what actually answers the question.
                        local mine = ns.AuraMentions(id, selSpell)
                        local box = chosen[id] and "|cff0cd29f[x]|r "
                                                or "|cff606060[ ]|r "
                        local body = mine and (nm .. "  |cff0cd29f" ..
                                     L("mentions it", "упоминает") .. "|r")
                                  or ("|cff909090" .. nm .. "|r")
                        rest[#rest + 1] = {
                            id = id, mine = mine, sort = nm, name = box .. body,
                        }
                    end
                end
            end
            table.sort(rest, function(a, b)
                if a.mine ~= b.mine then return a.mine and true or false end
                return a.sort < b.sort
            end)
            for _, item in ipairs(rest) do list[#list + 1] = item end
        else
            -- Everything that can actually be watched, not only spells that
            -- already have rules. A state is pointed elsewhere precisely when
            -- its own aura is invisible, and the useful targets are the ones
            -- the Cooldown Manager tracks -- listing only configured spells
            -- offered the choice least likely to help.
            local chosen = {}
            if type(rule and rule.auraIDs) == "table" then
                for _, id in ipairs(rule.auraIDs) do chosen[id] = true end
            end
            if rule and rule.auraID then chosen[rule.auraID] = true end
            list = { { id = nil, name = L("its own aura", "своя аура") } }
            local names, rest = {}, {}
            local function Add(id, tracked)
                if not id or id == selSpell then return end
                local nm = ns.SpellName(id)
                if not nm or nm:find("^spell:") or names[nm] then return end
                names[nm] = true
                local box = chosen[id] and "|cff0cd29f[x]|r " or "|cff606060[ ]|r "
                rest[#rest + 1] = {
                    id = id, sort = nm, tracked = tracked and true or false,
                    name = box .. (tracked and nm or ("|cff909090" .. nm .. "|r")),
                }
            end
            for id in pairs(ns.cdmAuraSpells or {}) do Add(id, true) end
            for _, r in ipairs(CG:GetRules()) do Add(r.spell, false) end
            -- Tracked ones first: those are the ones that will work.
            table.sort(rest, function(a, b)
                if a.tracked ~= b.tracked then return a.tracked end
                return a.sort < b.sort
            end)
            for _, item in ipairs(rest) do list[#list + 1] = item end
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
        UI.auraList:SetHeight(math.min(#list, 16) * 18 + 6)
        UI.auraList:Show()
    end

    UI.auraRow:SetScript("OnClick", function()
        if UI.auraList:IsShown() then UI.auraList:Hide() return end
        PopulateAuraList()
    end)

    -- Resource threshold ----------------------------------------------------
    -- The scan can only guess this from what the spell costs, and a cost is
    -- not a decision: 40 astral power is what Starsurge takes, not when a
    -- Balance druid wants to be told about it. So it is adjustable.
    UI.countRow = CreateFrame("Frame", nil, UI)
    UI.countRow:SetSize(378, 20)
    UI.countRow:SetPoint("TOPLEFT", 264, -104)
    local crBg = UI.countRow:CreateTexture(nil, "BACKGROUND")
    crBg:SetAllPoints(UI.countRow)
    crBg:SetColorTexture(1, 1, 1, 0.06)

    UI.countRow.label = Label(UI.countRow, "", 11, 0.75, 0.75, 0.75)
    UI.countRow.label:SetPoint("LEFT", 6, 0)

    -- Minus and plus rather than a slider: these numbers are exact by nature
    -- and a slider makes it fiddly to land on one. One per click; shift moves
    -- by ten, so a hundred-point pool does not cost a hundred clicks.
    local function Step(delta)
        local rule = CurrentRule()
        if not rule or rule.kind == "aura" or rule.kind == "cd" then return end
        local mx = math.max(1, CG:GetMaxPower(CG.powerType) or 5)
        if IsShiftKeyDown() then delta = delta * 10 end
        local cur = rule.atMax and mx or (rule.min or 1)
        local v = math.min(math.max(1, cur + delta), mx)
        rule.min, rule.max, rule.atMax = v, nil, nil
        CG:Rebuild()
        Refresh()
    end

    UI.countRow.max = TextButton(UI.countRow, L("max", "макс"), 56, 16, function()
        local rule = CurrentRule()
        if not rule or rule.kind == "aura" or rule.kind == "cd" then return end
        rule.atMax, rule.max = true, nil
        CG:Rebuild()
        Refresh()
    end)
    UI.countRow.max:SetPoint("RIGHT", UI.countRow, "RIGHT", -6, 0)

    UI.countRow.plus = TextButton(UI.countRow, "+", 22, 16, function() Step(1) end)
    UI.countRow.plus:SetPoint("RIGHT", UI.countRow.max, "LEFT", -4, 0)

    UI.countRow.minus = TextButton(UI.countRow, "-", 22, 16, function() Step(-1) end)
    UI.countRow.minus:SetPoint("RIGHT", UI.countRow.plus, "LEFT", -4, 0)

    -- Marker gallery --------------------------------------------------------
    UI.tiles = {}
    -- First tile: no marker at all. Turning a state off belongs with choosing
    -- its look, not behind a delete button -- deleting a state you may want
    -- back is a worse answer to "I do not want this one lit".
    local gallery = { { key = false, short = L("none", "без свечения") } }
    for _, style in ipairs(ns.STYLES) do
        if not style.hidden then gallery[#gallery + 1] = style end
    end

    for i, style in ipairs(gallery) do
        local col = (i - 1) % COLS
        local rowN = math.floor((i - 1) / COLS)

        local tile = CreateFrame("Button", nil, UI)
        tile:SetSize(TILE + 26, TILE + 26)
        tile:SetPoint("TOPLEFT", 264 + col * TILE_PAD_X, -176 - rowN * TILE_PAD_Y)
        tile.styleKey = style.key
        tile.defAlpha = style.defAlpha

        local sel = tile:CreateTexture(nil, "BACKGROUND")
        sel:SetAllPoints(tile)
        sel:SetColorTexture(0.05, 0.82, 0.62, 0.25)
        sel:Hide()
        tile.sel = sel

        -- The second marker, if the state has one. A different colour so the
        -- pair is readable at a glance: teal is the marker, amber is the
        -- one layered on top of it.
        local sel2 = tile:CreateTexture(nil, "BACKGROUND")
        sel2:SetAllPoints(tile)
        sel2:SetColorTexture(0.95, 0.7, 0.1, 0.22)
        sel2:Hide()
        tile.sel2 = sel2

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

        -- Said on the tile, because the preview cannot say it: this marker is
        -- Blizzard's own gold proc artwork and the colour you pick does
        -- nothing. Two states set to different colours look identical here.
        local caption = style.short or style.label
        if style.fixedColor then
            caption = caption .. " |cff909090" .. L("(gold)", "(золотой)") .. "|r"
        end
        local name = Label(tile, caption, 10, 0.75, 0.75, 0.75)
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
            if self.styleKey == false then
                rule.enabled = false
                CG:Rebuild()
                Refresh()
                return
            end
            -- Picking any marker turns the state back on.
            rule.enabled = true
            rule.style = self.styleKey
            -- A second layered marker used to live on shift-click. It existed
            -- only while the proc marker was still coming out gold and looked
            -- like it needed the help; one marker in a colour nothing else
            -- uses does the job, and the extra click was one more thing to
            -- explain for no gain.
            rule.style2 = nil
            if self.defAlpha then rule.alpha = self.defAlpha end
            -- Chosen by hand: the rebuild stops applying the default look.
            rule.styleLocked = true
            CG:Rebuild()
            Refresh()
        end)
        UI.tiles[i] = tile
    end

    -- Toggles ---------------------------------------------------------------
    UI.toggles = {}
    local defs = {
        { key = "timer", auraOnly = true, label = L("timer", "таймер"),
          get = function(r) return r.timer ~= false end,
          set = function(r) r.timer = not (r.timer ~= false) end },
        { key = "stacks", auraOnly = true, label = L("stacks", "стаки"),
          get = function(r) return r.stacks ~= false end,
          set = function(r) r.stacks = not (r.stacks ~= false) end },
        -- Per state, because it is worth it on some and clutter on others: a
        -- dot wants the tracker's art laid over the button (that is where the
        -- empowered form appears, and nowhere else), while a cooldown you can
        -- already read at a glance does not.
        { key = "badge", auraOnly = false,
          label = L("tracker icon over the button", "иконка трекера поверх кнопки"),
          get = function(r) return r.badge == true end,
          set = function(r) r.badge = (not r.badge) or nil end },
        -- Only offered where it can do anything: an aura state has no resource
        -- to be ready for, and a spell with its own "proc" state has already
        -- answered the question -- the proc belongs to that marker.
        { key = "orProc", auraOnly = false, label = L("also on proc", "также по проку"),
          hide = function(r) return r.kind == "aura" or ns.procOwned[r.spell] end,
          get = function(r) return r.orProc ~= false end,
          set = function(r) r.orProc = not (r.orProc ~= false) end },
        -- Reads the state the strip is actually in, automatic entries
        -- included. Reading rule.center alone left the box empty next to an
        -- icon that was plainly on the strip.
        { key = "center", auraOnly = false,
          -- Named for the state being edited. "Show above the resource" left
          -- out the half that matters: above the resource WHEN?
          labelFor = function(slot)
              if slot == "missing" then
                  return L("on the strip while gone", "над ресурсом, если нет")
              elseif slot == "ready" then
                  return L("on the strip while ready", "над ресурсом, если готов")
              elseif slot == "proc" then
                  return L("on the strip on a proc", "над ресурсом, если прок")
              end
              return L("on the strip while up", "над ресурсом, если висит")
          end,
          get = function(r) return ns.OnStrip(r) end,
          set = function(r)
              if ns.OnStrip(r) then
                  r.center, r.stripOff = nil, true
              else
                  r.center, r.stripOff = true, nil
              end
          end },
    }

    for i, def in ipairs(defs) do
        local t = CreateFrame("Button", nil, UI)
        t:SetSize(170, 18)
        t:SetPoint("TOPLEFT", 264 + ((i - 1) % 2) * 190,
                   -176 - 2 * TILE_PAD_Y - 10 - math.floor((i - 1) / 2) * 22)
        t.auraOnly = def.auraOnly
        t.hide = def.hide
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

        local fs = Label(t, def.label or "", 11, 0.85, 0.85, 0.85)
        fs:SetPoint("LEFT", box, "RIGHT", 5, 0)
        t.fs = fs
        t.labelFor = def.labelFor

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

    -- Alpha, not Hide: the aura states read that frame, and a hidden one is
    -- not guaranteed to keep updating.
    UI.hideCDM = TextButton(UI, "", 190, 22, function()
        CG.db.hideCDM = not CG.db.hideCDM
        ns.ApplyCDMVisibility()
        Refresh()
    end)
    -- Above the status line, clear of the buttons along the bottom.
    UI.hideCDM:SetPoint("BOTTOMLEFT", 14, 62)

    -- Where the marks go. Two surfaces, and neither is a fallback for the
    -- other: the Cooldown Manager is the one place that draws the EMPOWERED
    -- art for a dot, so marking state there and leaving the buttons clean is
    -- a coherent way to run it.
    UI.onBars = TextButton(UI, "", 190, 22, function()
        CG.db.showBars = (CG.db.showBars == false) or nil
        CG.lastSig = nil
        CG:Rebuild()
        Refresh()
    end)
    UI.onBars:SetPoint("BOTTOMLEFT", UI.hideCDM, "TOPLEFT", 0, 4)

    UI.onCDM = TextButton(UI, "", 190, 22, function()
        CG.db.cdm = not CG.db.cdm
        CG.lastSig = nil
        CG:Rebuild()
        Refresh()
    end)
    UI.onCDM:SetPoint("BOTTOMLEFT", UI.onBars, "TOPLEFT", 0, 4)

    -- Per state, not one number for everything: how much warning a dot needs
    -- depends on the dot. Sits at -128, under the "watching" row, on the line
    -- the gallery starts below.
    UI.soonRow = CreateFrame("Frame", nil, UI)
    UI.soonRow:SetSize(378, 20)
    UI.soonRow:SetPoint("TOPLEFT", 264, -128)
    local srBg = UI.soonRow:CreateTexture(nil, "BACKGROUND")
    srBg:SetAllPoints(UI.soonRow)
    srBg:SetColorTexture(1, 1, 1, 0.06)

    local function StepSoon(delta)
        local rule = SoonRule()
        if not rule then return end
        if IsShiftKeyDown() then delta = delta * 5 end
        rule.soon = math.max(0, math.min(60, (tonumber(rule.soon) or 0) + delta))
        CG.lastSig = nil
        CG:Rebuild()
        Refresh()
    end

    UI.soonRow.plus = TextButton(UI.soonRow, "+", 22, 16, function() StepSoon(1) end)
    UI.soonRow.plus:SetPoint("RIGHT", UI.soonRow, "RIGHT", -6, 0)
    UI.soonRow.minus = TextButton(UI.soonRow, "-", 22, 16, function() StepSoon(-1) end)
    UI.soonRow.minus:SetPoint("RIGHT", UI.soonRow.plus, "LEFT", -4, 0)

    -- Bounded by the buttons. Every text in this window that was free to grow
    -- towards another one has ended up drawn on top of it.
    UI.soonRow.label = Label(UI.soonRow, "", 11, 0.75, 0.75, 0.75)
    UI.soonRow.label:SetPoint("LEFT", 6, 0)
    UI.soonRow.label:SetPoint("RIGHT", UI.soonRow.minus, "LEFT", -8, 0)
    UI.soonRow.label:SetJustifyH("LEFT")
    UI.soonRow.label:SetWordWrap(false)

    UI.openCDM = TextButton(UI, L("Cooldown Manager settings", "Настройки Cooldown Manager"),
                            190, 22, function()
        local ok, why = ns.OpenCooldownManagerSettings()
        if ok then
            UI:Hide()
            if why == "editmode" then
                ns.Say(L("Edit Mode: pick the Cooldown Manager to choose its spells",
                         "Режим редактирования: выбери Cooldown Manager, чтобы задать заклинания"))
            end
        elseif why == "combat" then
            ns.Say(L("not in combat", "не в бою"))
        else
            ns.Say(L("could not open it - Game Menu, Edit Mode, Cooldown Manager",
                     "не удалось открыть — Меню игры, Режим редактирования, Cooldown Manager"))
        end
    end)
    UI.openCDM:SetPoint("BOTTOMLEFT", UI.onCDM, "TOPLEFT", 0, 4)

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

    -- Only the whole spell. Removing a single state was never the right
    -- answer to "do not light this one" -- the gallery's first tile turns a
    -- state off and keeps it, which is what that actually asks for.
    UI.delSpell = TextButton(UI, L("Delete spell", "Удалить заклинание"), 150, 22, function()
        if not selSpell then return end
        local rules = CG:GetRules()
        for i = #rules, 1, -1 do
            if rules[i].spell == selSpell then table.remove(rules, i) end
        end
        selSpell = nil
        CG:Rebuild()
        Refresh()
    end)
    UI.delSpell:SetPoint("BOTTOMRIGHT", -12, 10)

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

--[[-------------------------------------------------------------------------
    Opening Blizzard's Cooldown Manager settings

    There is no documented entry point, so the known ones are tried in turn:
    the settings panel itself if this client has it, then Edit Mode, which is
    where the Cooldown Manager is configured. If neither is there the caller
    says where to go by hand rather than failing silently.
---------------------------------------------------------------------------]]
function ns.OpenCooldownManagerSettings()
    if InCombatLockdown() then return false, "combat" end

    local panel = _G.CooldownViewerSettings
    if panel and _G.ShowUIPanel then
        local ok = pcall(_G.ShowUIPanel, panel)
        if ok and panel:IsShown() then return true end
    end

    local em = _G.EditModeManagerFrame
    if em and em.EnterEditMode then
        local ok = pcall(em.EnterEditMode, em)
        if ok then return true, "editmode" end
    end
    return false
end

--[[-------------------------------------------------------------------------
    Minimap button

    Written out rather than pulled from LibDBIcon: this is the only library
    the addon would need, for one button, and it would have to be shipped
    alongside. The angle is saved, so it stays where it is dragged.
---------------------------------------------------------------------------]]
local mmButton

local function PlaceMinimapButton()
    if not mmButton then return end
    local angle = math.rad(CG.db.minimap.angle or 200)
    mmButton:ClearAllPoints()
    mmButton:SetPoint("CENTER", Minimap, "CENTER",
                      math.cos(angle) * 80, math.sin(angle) * 80)
end

local function DragMinimapButton(self)
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    CG.db.minimap.angle = math.deg(math.atan2(py - my, px - mx))
    PlaceMinimapButton()
end

function ns.UpdateMinimapButton()
    if not mmButton then return end
    mmButton:SetShown(not CG.db.minimap.hide)
    PlaceMinimapButton()
end

function ns.CreateMinimapButton()
    if mmButton or not Minimap then return end

    mmButton = CreateFrame("Button", "ComboGlowMinimapButton", Minimap)
    mmButton:SetSize(31, 31)
    mmButton:SetFrameStrata("MEDIUM")
    mmButton:SetFrameLevel(8)
    mmButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mmButton:RegisterForDrag("LeftButton")
    mmButton:SetMovable(true)

    local icon = mmButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    -- The addon's own art. TGA because the client reads TGA and BLP and
    -- nothing else: a PNG in this slot simply draws nothing.
    --
    -- Forward slashes on purpose. The usual backslash form needs doubling in a
    -- Lua string, and a single one here is not a path with a typo -- "\I" is an
    -- invalid escape sequence and the whole file stops compiling.
    icon:SetTexture("Interface/AddOns/ComboGlow/icon.tga")

    local border = mmButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface/Minimap/MiniMap-TrackingBorder")

    mmButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", DragMinimapButton)
    end)
    mmButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    mmButton:SetScript("OnClick", function() ns.ToggleOptions() end)

    mmButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ComboGlow")
        GameTooltip:AddLine(L("Click to open the options", "Клик — открыть настройки"),
                            1, 1, 1)
        GameTooltip:AddLine(L("Drag to move around the minimap",
                              "Перетащить — сдвинуть по краю миникарты"), 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ns.UpdateMinimapButton()
end
