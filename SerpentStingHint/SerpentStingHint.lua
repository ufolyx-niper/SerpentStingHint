-- SPDX-License-Identifier: GPL-2.0-only
-- Aura clipping after EverAuras, and health-curve projection after Last Breath Forever.
-- See README and the accompanying licenses for attribution.
local addon, ns = ...
local _, class = UnitClass("player")
if class ~= "HUNTER" then return end

local ICON_SIZE = 44
local SPELL_ICON = "Interface\\Icons\\Ability_Hunter_Quickshot"
local STING_RANKS = {
    [1978] = true, [13549] = true, [13550] = true, [13551] = true, [13552] = true,
    [13553] = true, [13554] = true, [13555] = true, [25295] = true,
}
local FILTER = "HARMFUL|PLAYER"
local LAYOUT_TEMPLATE = "DisableUntrustedLayoutScriptsTemplate"
local MIN_TIME = 2
local MIN_HITS = 3
local MIN_LOSS = 0.05
local MAX_IDLE = 5
local OPENING_TIME = 6
local BAND_COUNT = 40
local EPSILON = 0.0000001

local anchor = CreateFrame("Frame", nil, UIParent)
anchor:SetSize(1, 1)
anchor:SetPoint("CENTER", UIParent, "CENTER", 140, -100)
local root = CreateFrame("Frame", nil, anchor, LAYOUT_TEMPLATE)
root:SetSize(ICON_SIZE, ICON_SIZE)
root:SetPoint("CENTER", anchor)
root:Hide()
local sampleGates = {}
local sampleTime, lastHit, hits
local estimatesVisible = false
local thresholdCurve, transparent, opaque
local elapsedUpdate = 0
local initialized, unsupported, estimatorReady
local timerContainer, missingContainer
local openingHighlight, openingEndsAt, targetMaxHealth
local neutral

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function TargetIsAttackable()
    local attackable = UnitCanAttack("player", "target")
    local dead = UnitIsDeadOrGhost("target")
    return not IsSecret(attackable) and attackable == true
        and not IsSecret(dead) and dead == false
end

local function ApplySettings()
    local db = ns.db
    if not InCombatLockdown() then
        root:SetScale(db.scale / 100)
        ns.PlaceFrame(anchor, ICON_SIZE)
    end
    anchor:SetShown(not ns.previewActive)
    if neutral then neutral:SetShown(db.showIdle) end
end

local function NewIcon(parent)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(parent)
    icon:SetTexture(SPELL_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return icon
end

local function NewAuraContainer()
    local container = CreateFrame("AuraContainer", nil, root, "CustomAuraContainerTemplate")
    container:SetPoint("TOPLEFT", root, "TOPLEFT")
    return container
end

local function BuildAuraDisplay()
    neutral = NewIcon(root)
    neutral:SetDesaturated(true)
    neutral:SetVertexColor(0.55, 0.55, 0.55)

    local tracker = NewAuraContainer()
    tracker:SetFrameLevel(root:GetFrameLevel() + 4)
    local slot = tracker:AddAuraSlot("sting-timer", FILTER, {
        candidateFilters = { includeSpellIDs = STING_RANKS },
        initializeFrame = function(button)
            button:ClearAllPoints()
            button:SetAllPoints(root)
            button:SetMouseClickEnabled(false)
            button:EnableMouseMotion(false)
            local icon = NewIcon(button)
            local timer = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            timer:SetPoint("CENTER")
            timer:SetTextColor(1, 1, 1)
            button:SetIcon(icon)
            button:SetDurationText(timer, nil)
        end,
    })
    assert(slot, "Aura slot unavailable")
    tracker:SetUnit("target")
    tracker:SetEnabled(true)

    local indicator = NewAuraContainer()
    indicator:AddAuraGroup("sting-missing", FILTER, {
        candidateFilters = { includeSpellIDs = STING_RANKS },
        maxFrameCount = 1,
        layout = { elementWidth = ICON_SIZE + 1, elementHeight = ICON_SIZE },
        initializeFrame = function(button)
            button:SetSize(ICON_SIZE + 1, ICON_SIZE)
            button:SetMouseClickEnabled(false)
            button:EnableMouseMotion(false)
        end,
    })
    indicator:SetUnit("target")
    indicator:SetEnabled(true)

    -- The engine gives the group width 1 when empty, or ICON_SIZE + 1 when occupied.
    local missingClip = CreateFrame("Frame", nil, root, LAYOUT_TEMPLATE)
    missingClip:SetFrameLevel(root:GetFrameLevel() + 1)
    missingClip:SetClipsChildren(true)
    missingClip:SetPoint("TOPLEFT", indicator, "TOPRIGHT", -1, 0)
    missingClip:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT")
    timerContainer, missingContainer = tracker, indicator
    return missingClip
end

local function NewColorCurve()
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    return curve
end

local function NewHighlight(parent)
    local highlight = CreateFrame("Frame", nil, parent, LAYOUT_TEMPLATE)
    highlight:SetAllPoints(root)
    local border = highlight:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(highlight)
    border:SetColorTexture(1, 0.8, 0.12, 1)
    local icon = NewIcon(highlight)
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    return highlight
end

local function BuildEstimateDisplay(missingClip)
    transparent = CreateColor(1, 1, 1, 0)
    opaque = CreateColor(1, 1, 1, 1)
    thresholdCurve = NewColorCurve()
    openingHighlight = NewHighlight(missingClip)
    openingHighlight:Hide()

    for index = 1, BAND_COUNT do
        local lower = (index - 1) / BAND_COUNT
        local upper = index / BAND_COUNT
        local band = NewColorCurve()
        band:AddPoint(0, index == 1 and opaque or transparent)
        if index > 1 then band:AddPoint(lower, opaque) end
        if index < BAND_COUNT then band:AddPoint(upper, transparent) end

        local sampleGate = CreateFrame("Frame", nil, missingClip, LAYOUT_TEMPLATE)
        sampleGate:SetAllPoints(root)
        sampleGate:Hide()
        sampleGates[index] = { band = band, upper = upper, frame = sampleGate, highlight = NewHighlight(sampleGate) }
    end
end

local function HideEstimates()
    if not estimatesVisible then return end
    for _, gate in ipairs(sampleGates) do gate.frame:Hide() end
    estimatesVisible = false
end

local function ResetSample()
    HideEstimates()
    if openingHighlight then openingHighlight:Hide() end
    sampleTime, lastHit, hits = nil, nil, 0
end

local function ApplyHealthCurve(frame, curve)
    -- Alpha is used only by the engine. Its value is never inspected or compared in Lua.
    local color = UnitHealthPercent("target", false, curve)
    local _, _, _, alpha = color:GetRGBA()
    frame:SetAlpha(alpha)
end

local function StartSample(now)
    for _, gate in ipairs(sampleGates) do
        ApplyHealthCurve(gate.frame, gate.band)
    end
    sampleTime, lastHit, hits = now, now, 1
end

local function OpeningThreshold(now)
    if not openingEndsAt then
        local fighting = UnitAffectingCombat("target")
        if not IsSecret(fighting) and fighting == true then openingEndsAt = now + OPENING_TIME end
    end
    if not ns.db.openingEnabled or (openingEndsAt and now >= openingEndsAt) then return nil end

    local ok, maximum = pcall(UnitHealthMax, "target")
    if ok and not IsSecret(maximum) and type(maximum) == "number" then
        targetMaxHealth = maximum
    end
    local openingHealth = ns.db.openingHealth
    if targetMaxHealth and targetMaxHealth >= openingHealth then
        -- Put the float boundary between the two adjacent whole HP values.
        return (openingHealth - 0.5) / targetMaxHealth
    end
end

local function UpdateEstimate(now)
    if not estimatorReady or not root:IsShown() then return end
    if sampleTime and now - lastHit >= MAX_IDLE then
        openingEndsAt = now
        ResetSample()
    end
    local openingThreshold = OpeningThreshold(now)
    local elapsed = sampleTime and now - sampleTime
    if not elapsed or hits < MIN_HITS or elapsed < MIN_TIME then
        openingHighlight:Hide()
        if openingThreshold then
            thresholdCurve:ClearPoints()
            thresholdCurve:AddPoint(0, transparent)
            thresholdCurve:AddPoint(openingThreshold, opaque)
            ApplyHealthCurve(openingHighlight, thresholdCurve)
            openingHighlight:Show()
        end
        return
    end
    openingHighlight:Hide()

    local refreshTime = ns.db.refreshTime
    for _, gate in ipairs(sampleGates) do
        -- Use the top of the sampled health band as the starting share. With a constant
        -- damage rate, time left exceeds 10 s only above this projected health share.
        local lower = refreshTime * gate.upper / (refreshTime + elapsed) + EPSILON
        local enoughLossBelow = gate.upper - MIN_LOSS
        local openingFrom = openingThreshold and math.max(openingThreshold, enoughLossBelow)
        thresholdCurve:ClearPoints()
        thresholdCurve:AddPoint(0, transparent)
        if lower < enoughLossBelow then
            thresholdCurve:AddPoint(lower, opaque)
            if openingFrom ~= enoughLossBelow then
                thresholdCurve:AddPoint(enoughLossBelow, transparent)
            end
        end
        -- Above the loss cutoff, this band still has insufficient data for a TTD estimate.
        if openingFrom and (lower >= enoughLossBelow or openingFrom > enoughLossBelow) then
            thresholdCurve:AddPoint(openingFrom, opaque)
        end
        ApplyHealthCurve(gate.highlight, thresholdCurve)
    end
    if not estimatesVisible then
        for _, gate in ipairs(sampleGates) do gate.frame:Show() end
        estimatesVisible = true
    end
end

local function RefreshTarget()
    root:SetShown(TargetIsAttackable())
    if not root:IsShown() then ResetSample() end
end

local function Initialize()
    if initialized or unsupported or InCombatLockdown() then return end
    local ok, missingClip = pcall(function()
        C_AddOns.LoadAddOn("Blizzard_AuraContainer")
        return BuildAuraDisplay()
    end)
    if not ok then
        unsupported = true
        print("Serpent Sting Hint: this client could not initialize the aura display.")
        return
    end
    if type(UnitHealthPercent) == "function" then
        estimatorReady = pcall(BuildEstimateDisplay, missingClip)
    end
    initialized = true
    ApplySettings()
    ResetSample()
    RefreshTarget()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
local registered = pcall(events.RegisterUnitEvent, events, "UNIT_COMBAT", "target")
if not registered then pcall(events.RegisterEvent, events, "UNIT_COMBAT") end
if not pcall(events.RegisterUnitEvent, events, "UNIT_MAXHEALTH", "target") then
    pcall(events.RegisterEvent, events, "UNIT_MAXHEALTH")
end
events:SetScript("OnEvent", function(_, event, unit, action)
    if event == "ADDON_LOADED" then
        if unit == addon then ns.SetupSettings(ICON_SIZE, SPELL_ICON, ApplySettings) end
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        ns.EndPreview()
        return
    elseif event == "DISPLAY_SIZE_CHANGED" then
        ns.RefreshSettingsLayout()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
        ns.SetupSettings(ICON_SIZE, SPELL_ICON, ApplySettings)
        Initialize()
        ApplySettings()
    end
    if not initialized then return end

    if event == "UNIT_MAXHEALTH" then
        if not IsSecret(unit) and unit == "target" then targetMaxHealth = nil end
        return
    end
    if event ~= "UNIT_COMBAT" then
        if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
            openingEndsAt, targetMaxHealth = nil, nil
        elseif event == "PLAYER_REGEN_ENABLED" then
            local fighting = UnitAffectingCombat("target")
            if not IsSecret(fighting) and fighting == false then
                openingEndsAt, targetMaxHealth = nil, nil
            end
        end
        ResetSample()
        RefreshTarget()
        if root:IsShown() then
            timerContainer:UpdateAllAuras()
            missingContainer:UpdateAllAuras()
        end
        return
    end
    if not estimatorReady or IsSecret(unit) or IsSecret(action) or unit ~= "target" or action ~= "WOUND" then return end
    if not TargetIsAttackable() then return end
    local now = GetTime()
    openingEndsAt = openingEndsAt or now + OPENING_TIME
    if sampleTime and now - lastHit >= MAX_IDLE then openingEndsAt = now end
    if not sampleTime or now - lastHit >= MAX_IDLE then
        ResetSample()
        if not pcall(StartSample, now) then ResetSample() end
    else
        hits, lastHit = hits + 1, now
    end
end)

events:SetScript("OnUpdate", function(_, elapsed)
    if not initialized then return end
    elapsedUpdate = elapsedUpdate + elapsed
    if elapsedUpdate < 0.2 then return end
    elapsedUpdate = 0
    RefreshTarget()
    if not pcall(UpdateEstimate, GetTime()) then ResetSample() end
end)
