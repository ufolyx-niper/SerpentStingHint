-- SPDX-License-Identifier: GPL-2.0-only
local _, ns = ...
if select(2, UnitClass("player")) ~= "HUNTER" then return end

local defaults = {
    x = 140, y = -100, scale = 100, showIdle = true,
    refreshTime = 10, openingEnabled = true, openingHealth = 5000,
}
local ranges = {
    x = { -4000, 4000 }, y = { -4000, 4000 }, scale = { 50, 200 },
    refreshTime = { 1, 60 }, openingHealth = { 1, 10000000 },
}
local title = "Serpent Sting Hint"
local labels = {
    scale = "Icon and timer size", idle = "Show the gray icon when there is no reminder",
    refreshTime = "Minimum estimated time left (seconds)", openingHealth = "Opening minimum health (HP)",
    openingEnabled = "Use the opening health rule", preview = "Preview: %s",
    modes = { "Off", "Countdown", "Gold border", "Gray icon" },
    unlock = "Unlock and drag", lock = "Lock position", reset = "Restore defaults",
    location = "Position: %d, %d", drag = "Drag to position", sample = "Preview",
    tip = "The opening health rule applies while the kill-time estimate is unavailable.",
    busy = "Preview and dragging are available out of combat.",
    unavailable = "The game settings panel is unavailable.",
}
local locale = GetLocale()
if locale == "zhCN" then
    labels = {
        scale = "图标和倒计时大小", idle = "没有提醒时显示灰色图标",
        refreshTime = "预计剩余击杀时间门槛（秒）", openingHealth = "开怪剩余血量门槛（点）",
        openingEnabled = "启用开怪血量规则", preview = "预览：%s",
        modes = { "关闭", "倒计时", "金框", "灰色" },
        unlock = "解锁并拖动", lock = "锁定位置", reset = "恢复默认",
        location = "位置：%d，%d", drag = "拖动设置位置", sample = "预览",
        tip = "击杀时间尚未算出时，可以按开怪血量提示。",
        busy = "请在脱战时预览或拖动图标。",
        unavailable = "游戏设置面板暂不可用。",
    }
elseif locale == "zhTW" then
    labels = {
        scale = "圖示和倒數計時大小", idle = "沒有提醒時顯示灰色圖示",
        refreshTime = "預計剩餘擊殺時間門檻（秒）", openingHealth = "開怪剩餘生命值門檻（點）",
        openingEnabled = "啟用開怪生命值規則", preview = "預覽：%s",
        modes = { "關閉", "倒數計時", "金框", "灰色" },
        unlock = "解鎖並拖曳", lock = "鎖定位置", reset = "恢復預設",
        location = "位置：%d，%d", drag = "拖曳設定位置", sample = "預覽",
        tip = "擊殺時間尚未算出時，可以按開怪生命值提示。",
        busy = "請在脫戰時預覽或拖曳圖示。",
        unavailable = "遊戲設定面板暫不可用。",
    }
end

local size, texturePath, apply
local panel, category, preview, previewArt, icon, border, timer, badge
local scaleSlider, scaleLabel, idleCheck, openingCheck, secondsInput, healthInput
local previewButton, moveButton, positionLabel
local mode, unlocked, dragging, syncing = 1, false, false, false

local function ValidValue(key, value, fallback)
    local limits = ranges[key]
    if not limits then
        if type(value) == "boolean" then return value end
    elseif type(value) == "number" and value >= limits[1] and value <= limits[2] then
        return math.floor(value + 0.5)
    end
    return fallback
end

local function ClampOffset(value, extent, scaledSize)
    local limit = math.max(0, (extent - scaledSize) / 2)
    return math.max(-limit, math.min(value, limit))
end

function ns.PlaceFrame(frame, iconSize)
    local db = ns.db
    local scaledSize = iconSize * db.scale / 100
    local x = ClampOffset(db.x, UIParent:GetWidth(), scaledSize)
    local y = ClampOffset(db.y, UIParent:GetHeight(), scaledSize)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

local function RefreshPreview()
    if not badge then return end
    local scale = ns.db.scale / 100
    preview:SetSize(size * scale, size * scale)
    previewArt:SetScale(scale)
    if not dragging then ns.PlaceFrame(preview, size) end
    icon:SetDesaturated(mode == 4)
    local tint = mode == 4 and 0.55 or 1
    icon:SetVertexColor(tint, tint, tint)
    icon:ClearAllPoints()
    if mode == 3 then
        icon:SetPoint("TOPLEFT", 3, -3)
        icon:SetPoint("BOTTOMRIGHT", -3, 3)
    else
        icon:SetAllPoints(previewArt)
    end
    border:SetShown(mode == 3)
    timer:SetShown(mode == 2)
    badge:SetText(unlocked and labels.drag or labels.sample)
    preview:EnableMouse(unlocked)
    preview:SetShown(mode ~= 1)
end

function ns.RefreshSettingsLayout()
    if not apply then return end
    ns.previewActive = mode ~= 1
    apply()
    RefreshPreview()
    if previewButton then previewButton:SetText(labels.preview:format(labels.modes[mode])) end
    if moveButton then moveButton:SetText(unlocked and labels.lock or labels.unlock) end
    if positionLabel then positionLabel:SetText(labels.location:format(ns.db.x, ns.db.y)) end
end

local function StopDrag(save)
    if not dragging then return end
    dragging = false
    preview:StopMovingOrSizing()
    if save then
        local x, y = preview:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if x and y and ux and uy then
            ns.db.x = ValidValue("x", x - ux, ns.db.x)
            ns.db.y = ValidValue("y", y - uy, ns.db.y)
        end
    end
end

function ns.EndPreview()
    if mode == 1 then return end
    StopDrag(false)
    mode, unlocked = 1, false
    ns.RefreshSettingsLayout()
end

local function PreviewAvailable()
    if not InCombatLockdown() then return true end
    print(title .. ": " .. labels.busy)
    return false
end

local function CreatePreview()
    preview = CreateFrame("Frame", nil, UIParent)
    preview:Hide()
    preview:SetFrameStrata("FULLSCREEN_DIALOG")
    preview:SetMovable(true)
    preview:SetClampedToScreen(true)
    preview:RegisterForDrag("LeftButton")
    preview:SetScript("OnDragStart", function(self)
        if not unlocked or InCombatLockdown() then return end
        dragging = true
        self:StartMoving()
    end)
    preview:SetScript("OnDragStop", function()
        StopDrag(not InCombatLockdown())
        ns.RefreshSettingsLayout()
    end)
    previewArt = CreateFrame("Frame", nil, preview)
    previewArt:SetSize(size, size)
    previewArt:SetPoint("CENTER", preview)
    border = previewArt:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(previewArt)
    border:SetColorTexture(1, 0.8, 0.12, 1)
    icon = previewArt:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(texturePath)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    timer = previewArt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    timer:SetPoint("CENTER")
    timer:SetTextColor(1, 1, 1)
    timer:SetText("8")
    badge = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    badge:SetPoint("BOTTOM", preview, "TOP", 0, 5)
end

local function Text(parent, font, value, x, y)
    local text = parent:CreateFontString(nil, "ARTWORK", font)
    text:SetPoint("TOPLEFT", x, y)
    text:SetText(value)
    return text
end

local function Button(parent, text, x, y, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", x, y)
    button:SetSize(width, 24)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function Checkbox(parent, key, text, y, onChanged)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", 24, y)
    check:SetSize(24, 24)
    local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 5, 0)
    label:SetText(text)
    check:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() == true
        if onChanged then onChanged() end
        ns.RefreshSettingsLayout()
    end)
    return check
end

local function NumberInput(parent, key, label, y)
    Text(parent, "GameFontHighlight", label, 29, y - 5)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetPoint("TOPLEFT", 330, y)
    input:SetSize(105, 24)
    input:SetAutoFocus(false)
    input:SetNumeric(true)
    input:SetMaxLetters(8)
    local limits = ranges[key]
    local rangeLabel = input:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rangeLabel:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -1)
    rangeLabel:SetText(("%d–%d"):format(limits[1], limits[2]))
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(ns.db[key]))
        self:ClearFocus()
    end)
    input:SetScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText())
        ns.db[key] = ValidValue(key, value, ns.db[key])
        self:SetText(tostring(ns.db[key]))
        ns.RefreshSettingsLayout()
    end)
    return input
end

local function SyncPanel()
    local db = ns.db
    syncing = true
    scaleSlider:SetValue(db.scale)
    scaleLabel:SetText(db.scale .. "%")
    idleCheck:SetChecked(db.showIdle)
    openingCheck:SetChecked(db.openingEnabled)
    healthInput:SetEnabled(db.openingEnabled)
    secondsInput:SetText(tostring(db.refreshTime))
    healthInput:SetText(tostring(db.openingHealth))
    syncing = false
    ns.RefreshSettingsLayout()
end

local function CreatePanel()
    panel = CreateFrame("Frame", nil, UIParent)
    panel:Hide()
    Text(panel, "GameFontNormalLarge", title, 24, -20)
    Text(panel, "GameFontHighlight", labels.scale, 29, -67)
    scaleLabel = Text(panel, "GameFontHighlight", "", 440, -67)
    scaleSlider = CreateFrame("Slider", nil, panel)
    scaleSlider:SetPoint("TOPLEFT", 250, -60)
    scaleSlider:SetSize(180, 24)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:EnableMouse(true)
    scaleSlider:SetMinMaxValues(ranges.scale[1], ranges.scale[2])
    scaleSlider:SetValueStep(1)
    scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local track = scaleSlider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(0.55, 0.55, 0.55, 1)
    scaleSlider:SetScript("OnValueChanged", function(_, value)
        if syncing then return end
        ns.db.scale = ValidValue("scale", value, ns.db.scale)
        scaleLabel:SetText(ns.db.scale .. "%")
        ns.RefreshSettingsLayout()
    end)
    idleCheck = Checkbox(panel, "showIdle", labels.idle, -95)
    secondsInput = NumberInput(panel, "refreshTime", labels.refreshTime, -135)
    openingCheck = Checkbox(panel, "openingEnabled", labels.openingEnabled, -173, function()
        healthInput:SetEnabled(ns.db.openingEnabled)
    end)
    healthInput = NumberInput(panel, "openingHealth", labels.openingHealth, -204)
    Text(panel, "GameFontHighlightSmall", labels.tip, 29, -238)

    previewButton = Button(panel, "", 24, -277, 155, function()
        if not PreviewAvailable() then return end
        StopDrag(false)
        mode = mode % #labels.modes + 1
        if mode == 1 then unlocked = false end
        ns.RefreshSettingsLayout()
    end)
    moveButton = Button(panel, "", 188, -277, 138, function()
        if not PreviewAvailable() then return end
        StopDrag(true)
        unlocked = not unlocked
        if unlocked and mode == 1 then mode = 2 end
        ns.RefreshSettingsLayout()
    end)
    Button(panel, labels.reset, 335, -277, 130, function()
        StopDrag(false)
        for key, value in pairs(defaults) do ns.db[key] = value end
        SyncPanel()
    end)
    positionLabel = Text(panel, "GameFontHighlight", "", 29, -320)
    panel:SetScript("OnShow", SyncPanel)
    panel:SetScript("OnHide", ns.EndPreview)
    local entry = Settings.RegisterCanvasLayoutCategory(panel, title)
    Settings.RegisterAddOnCategory(entry)
    category = entry
end

function ns.SetupSettings(iconSize, iconTexture, applySettings)
    if ns.db then return end
    if type(SerpentStingHintPosition) ~= "table" then SerpentStingHintPosition = {} end
    ns.db = SerpentStingHintPosition
    for key, fallback in pairs(defaults) do
        ns.db[key] = ValidValue(key, ns.db[key], fallback)
    end
    size, texturePath, apply = iconSize, iconTexture, applySettings
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        pcall(function()
            CreatePreview()
            CreatePanel()
        end)
    end
    ns.RefreshSettingsLayout()
end

SLASH_SERPENTSTINGHINT1 = "/sshint"
SlashCmdList.SERPENTSTINGHINT = function(message)
    if not ns.db then return end
    local command = message:match("^%s*(.-)%s*$")
    if command == "" then
        if not category or not Settings.OpenToCategory then
            print(title .. ": " .. labels.unavailable)
        else
            local ok = pcall(Settings.OpenToCategory, category:GetID())
            if not ok then print(title .. ": " .. labels.unavailable) end
        end
        return
    end
    local x, y = command:match("^([+-]?%d+)%s+([+-]?%d+)$")
    x, y = ValidValue("x", tonumber(x)), ValidValue("y", tonumber(y))
    if command == "reset" then
        x, y = defaults.x, defaults.y
    elseif not x or not y then
        print(title .. ": /sshint | /sshint <x> <y> | /sshint reset")
        return
    end
    StopDrag(false)
    ns.db.x, ns.db.y = x, y
    ns.RefreshSettingsLayout()
end
