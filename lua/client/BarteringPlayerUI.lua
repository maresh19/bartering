require "ISUI/ISPanel"
require "ISUI/ISPanelJoypad"
require "ISUI/ISButton"
require "ISUI/ISToolTip"
require "Bartering"

local BarteringUIUtils = require "BarteringUIUtils"
local ISPanelJoypad = _G["ISPanelJoypad"]
local ISButton = _G["ISButton"]
local ISToolTip = _G["ISToolTip"]
local UIFont = _G["UIFont"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local InventoryItemFactory = _G["InventoryItemFactory"]
local BarteringTiming = require "BarteringTiming"

local LINE_H = 18
local ROW_GAP = 2
local PANEL_PAD = 4
local BTN_H = 20
local GAP_BETWEEN = 4
local HEADER_H = 22
local TAB_NAME = "Bartering"
local VALUE_COLUMN_FRACTION = 0.58
local STAR_COUNT = 10
local STAR_GAP = 2
local STAR_SIZE = 16
local SCROLL_BAR_W = 17
local CONTENT_TOP = PANEL_PAD + HEADER_H
local MIN_PANEL_W = 420
local SECTION_GAP = 5
local MET_CHECK_INTERVAL_TICKS = 60
local STALE_AGE_SECONDS = 60

local drawStar = Bartering.Relations.drawStar

local STATE_LABELS = {
    Waiting = "At Home",
    Approach = "Heading to Meetup",
    Return = "Returning Home",
    Retreat = "In Combat",
    DefendPistol = "In Combat",
    DefendKnife = "In Combat",
}

local STATE_COLORS = {
    ["Deceased"] = { 0.9, 0.25, 0.25 },
    ["In Combat"] = { 0.95, 0.55, 0.1 },
    ["Heading to Meetup"] = { 0.3, 0.8, 1.0 },
    ["Returning Home"] = { 1.0, 0.8, 0.2 },
    ["Sleeping"] = { 0.5, 0.5, 0.8 },
}

local DEFAULT_STATE_COLOR = { 0.4, 0.9, 0.4 }

local itemInfoCache = {}

local function getItemInfo(itemName)
    local info = itemInfoCache[itemName]
    if info then
        return info
    end
    local item = InventoryItemFactory.CreateItem(itemName)
    info = {
        texture = item and item:getTex() or nil,
        displayName = item and item:getDisplayName() or itemName,
    }
    itemInfoCache[itemName] = info
    return info
end

local pendingRefresh = {}

function Bartering.queuePlayerUIStockRefresh(bartererId, waitForChange)
    if waitForChange then
        pendingRefresh[bartererId] = { baseline = Bartering.getBartererStockMap(bartererId) }
    else
        pendingRefresh[bartererId] = { immediate = true }
    end
end

local function stockChanged(current, baseline)
    current = current or {}
    baseline = baseline or {}
    for itemName, qty in pairs(current) do
        if (baseline[itemName] or 0) ~= qty then
            return true
        end
    end
    for itemName, qty in pairs(baseline) do
        if (current[itemName] or 0) ~= qty then
            return true
        end
    end
    return false
end

local function getStockIntel(player)
    local modData = player:getModData()
    if not modData.BarteringStockIntel then
        modData.BarteringStockIntel = {}
    end
    return modData.BarteringStockIntel
end

local function getCachedStock(bartererId)
    local player = getSpecificPlayer(0)
    return player and getStockIntel(player)[bartererId] or nil
end

local stockVersion = {}

local function setCachedStock(bartererId, stock)
    local player = getSpecificPlayer(0)
    if not player then
        return
    end
    getStockIntel(player)[bartererId] = stock
    stockVersion[bartererId] = (stockVersion[bartererId] or 0) + 1
    player:transmitModData()
end

local function hasWalkieTalkie(player)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local fullType = items:get(i):getFullType()
        if fullType and string.find(fullType:lower(), "walkietalkie") then
            return true
        end
    end
    return false
end

local function getBartererSnapshot(bartererId)
    return (Bartering.TrackedBarterers and Bartering.TrackedBarterers[bartererId])
        or Bartering.getBartererIntel(bartererId)
end

local function getSnapshotAgeSeconds(snapshot)
    if not snapshot or not snapshot.seenAtWorldHours then
        return nil
    end
    local elapsedHours = getGameTime():getWorldAgeHours() - snapshot.seenAtWorldHours
    if elapsedHours <= 0 then
        return 0
    end
    return BarteringTiming.gameHoursToRealSeconds(elapsedHours)
end

local function getBartererState(bartererId)
    local lifeState = Bartering.getBartererLifeState(bartererId)
    if lifeState.permanentlyDead then
        return "Deceased", 0
    end

    local returningRemainingHours = BarteringTiming.remainingHours(lifeState.returningHomeAt)
    if returningRemainingHours > 0 then
        return "Returning Home", BarteringTiming.gameHoursToRealSeconds(returningRemainingHours)
    end

    local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
    if respawnRemainingHours > 0 then
        return "Deceased", BarteringTiming.gameHoursToRealSeconds(respawnRemainingHours)
    end

    local snapshot = getBartererSnapshot(bartererId)
    if snapshot then
        return STATE_LABELS[snapshot.state] or snapshot.state, 0, nil, getSnapshotAgeSeconds(snapshot)
    end

    local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(bartererId)
    if arrivalRemaining then
        return "Heading to Meetup", 0, arrivalRemaining
    end

    if not Bartering.isBartererCallOpenNow(bartererId) then
        return "Sleeping", 0
    end

    return "At Home", 0
end

local function getStateColor(state)
    local color = STATE_COLORS[state] or DEFAULT_STATE_COLOR
    return color[1], color[2], color[3]
end

local function canCallBarterer(player, bartererId)
    if not player or not hasWalkieTalkie(player) then
        return false
    end
    if not Bartering.isBartererKnown(player, bartererId) then
        return false
    end
    if Bartering.Relations.getStarCount(player, bartererId) < 1 then
        return false
    end
    if Bartering.isBartererPermanentlyDead(bartererId) then
        return false
    end
    if not Bartering.isBartererCallOpenNow(bartererId) then
        return false
    end
    local lifeState = Bartering.getBartererLifeState(bartererId)
    if BarteringTiming.remainingHours(lifeState.respawnAt) > 0 then
        return false
    end
    if BarteringTiming.remainingHours(lifeState.calledInCooldownAt) > 0 then
        return false
    end
    return true
end

local function getCallButtonTooltip(player, bartererId, hasTalkie)
    if not hasTalkie then
        return "Requires Walkie Talkie"
    end

    local displayName = Bartering.getBartererDisplayName(bartererId)
    if player and Bartering.Relations.getStarCount(player, bartererId) < 1 then
        return "Requires Level 1 Relationship With This Barterer"
    end
    if Bartering.isBartererPermanentlyDead(bartererId) then
        return displayName .. " is dead and cannot respawn with the current sandbox settings"
    end

    local lifeState = Bartering.getBartererLifeState(bartererId)
    local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
    if respawnRemainingHours > 0 then
        return displayName .. " is dead and will be replaced with a new barterer in "
            .. BarteringTiming.formatCountdown(BarteringTiming.gameHoursToRealSeconds(respawnRemainingHours))
    end

    local cooldownRemainingHours = BarteringTiming.remainingHours(lifeState.calledInCooldownAt)
    if cooldownRemainingHours > 0 then
        return displayName .. " call cooldown: "
            .. BarteringTiming.formatCountdown(BarteringTiming.gameHoursToRealSeconds(cooldownRemainingHours))
    end

    if not Bartering.isBartererCallOpenNow(bartererId) then
        local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(bartererId)
        local wakeSeconds = BarteringTiming.gameHoursToRealSeconds(
            BarteringTiming.hoursUntilTimeOfDay(callStartHour))
        return string.format("%s is asleep and accepts calls between %02d:00 and %02d:00 - awake in %s",
            displayName, callStartHour, callEndHour, BarteringTiming.formatCountdown(wakeSeconds))
    end

    return "Call " .. displayName .. " for stock, errands and meetings"
end

local function getStockRefreshRemainingSeconds(bartererId)
    local remainingHours = Bartering.getBartererStockRefreshRemainingHours(bartererId)
    if remainingHours <= 0 then
        return nil
    end
    return BarteringTiming.gameHoursToRealSeconds(remainingHours)
end

local function getWakeRemainingSeconds(bartererId)
    if Bartering.isBartererCallOpenNow(bartererId) then
        return nil
    end
    local startHour = Bartering.getBartererCallWindowHours(bartererId)
    return BarteringTiming.gameHoursToRealSeconds(BarteringTiming.hoursUntilTimeOfDay(startHour))
end

local function getHomeRemainingSeconds(bartererId)
    local snapshot = getBartererSnapshot(bartererId)
    if not snapshot or (snapshot.departureAtMs or 0) <= 0 then
        local returningHours = BarteringTiming.remainingHours(
            Bartering.getBartererLifeState(bartererId).returningHomeAt)
        if returningHours > 0 then
            return BarteringTiming.gameHoursToRealSeconds(returningHours)
        end
        return nil
    end

    local barterer = Bartering.Barterers[bartererId]
    local waiting = BarteringTiming.remainingRealSecondsUntilMs(snapshot.departureAtMs) or 0
    local travel = BarteringTiming.calculateTravelSeconds(
        snapshot.x,
        snapshot.y,
        barterer.x,
        barterer.y,
        barterer.travelSecondsPerTile,
        Bartering.getSandboxNumber("TravelTimeMultiplier", 1)
    )
    if waiting + travel <= 0 then
        return nil
    end
    return waiting + travel
end

local function buildTimerRows(bartererId)
    local rows = {}
    local arrival = Bartering.getBartererArrivalRemainingSeconds(bartererId)
    if arrival then
        table.insert(rows, { label = "Arrives to your location in:", seconds = arrival })
    end
    local home = getHomeRemainingSeconds(bartererId)
    if home then
        table.insert(rows, { label = "Home In:", seconds = home })
    end
    local wake = getWakeRemainingSeconds(bartererId)
    if wake then
        table.insert(rows, { label = "Awake In:", seconds = wake })
    end
    local refresh = getStockRefreshRemainingSeconds(bartererId)
    if refresh then
        table.insert(rows, { label = "Stock Refreshes In:", seconds = refresh })
    end
    return rows
end

local function buildStockRows(player, bartererId, barterer)
    local stock = getCachedStock(bartererId)
    if not stock then
        return nil, "No stock data"
    end

    local barterLevel = player and Bartering.getBarterSkillLevel(player) or 0
    if barterLevel < barterer.requiredLevel then
        return nil, "Requires Level " .. tostring(barterer.requiredLevel) .. " Bartering"
    end

    if Bartering.getBartererStockRefreshRemainingHours(bartererId) <= 0 then
        return nil, "No stock data"
    end

    local requirementByItem = Bartering.getItemRequirementMap(bartererId)
    local rows = {}
    for itemName, qty in pairs(stock) do
        local info = getItemInfo(itemName)
        local label = info.displayName
        if qty > 1 then
            label = label .. " x" .. tostring(qty)
        end
        table.insert(rows, {
            texture = info.texture,
            label = label,
            valueText = Bartering.formatTradeValue(
                Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, player, bartererId)),
            levelText = requirementByItem[itemName]
                or ("Lvl " .. tostring(barterer.requiredLevel) .. " Bartering"),
            onSale = Bartering.isBartererItemOnSale(bartererId, itemName, player),
        })
    end

    if #rows == 0 then
        return nil, "No stock data"
    end

    table.sort(rows, function(a, b) return a.label < b.label end)
    return rows, nil
end

local STOCK_REBUILD_INTERVAL_TICKS = 30

local function buildSectionModel(bartererId, previous, tick)
    local player = getSpecificPlayer(0)
    local barterer = Bartering.Barterers[bartererId]
    local state, respawnSeconds, stateTimer, stateAge = getBartererState(bartererId)
    local hasTalkie = player and hasWalkieTalkie(player) or false

    local version = stockVersion[bartererId] or 0
    local stockRows, stockMessage
    if previous and previous.stockVersion == version
        and tick and tick - previous.stockBuiltAt < STOCK_REBUILD_INTERVAL_TICKS then
        stockRows, stockMessage = previous.stockRows, previous.stockMessage
        tick = previous.stockBuiltAt
    else
        stockRows, stockMessage = buildStockRows(player, bartererId, barterer)
    end

    local model = {
        displayName = Bartering.getBartererDisplayName(bartererId),
        state = state,
        respawnSeconds = respawnSeconds,
        stateTimer = stateTimer,
        stateAge = stateAge,
        isDeceased = state == "Deceased",
        showRelationships = Bartering.getSandboxBoolean("EnableRelationships", true),
        saleActive = Bartering.isBartererSaleActive(bartererId),
        timerRows = buildTimerRows(bartererId),
        stockRows = stockRows,
        stockMessage = stockMessage,
        stockVersion = version,
        stockBuiltAt = tick or 0,
        hasTalkie = hasTalkie,
        canCall = canCallBarterer(player, bartererId),
        callTooltip = getCallButtonTooltip(player, bartererId, hasTalkie),
        lowRelationship = player and Bartering.Relations.getStarCount(player, bartererId) < 1 or false,
    }

    local height = LINE_H + 4 + BTN_H + 4
    if model.showRelationships then
        height = height + LINE_H + 4
    end
    height = height + #model.timerRows * (LINE_H + ROW_GAP)
    height = height + SECTION_GAP
    height = height + LINE_H + ROW_GAP
    if stockRows then
        height = height + #stockRows * (LINE_H + ROW_GAP)
    end
    model.height = height + 4

    return model
end

local BarteringTabPanel = ISPanelJoypad:derive("BarteringTabPanel")

function BarteringTabPanel:onCallBarterer(_, bartererId)
    local player = getSpecificPlayer(0)
    if not player then
        return
    end
    if not hasWalkieTalkie(player) then
        player:Say("I need a walkie talkie to make a call.")
        return
    end
    if not canCallBarterer(player, bartererId) then
        return
    end
    BarteringDialogUI.open(player, bartererId, 0, 0, 0, nil, true)
end

local function applyCallButtonStyle(section, model)
    local button = section.callButton
    button.tooltip = model.callTooltip
    button.enable = model.canCall

    if not model.hasTalkie or model.lowRelationship then
        button.backgroundColor = { r = 0.5, g = 0.12, b = 0.12, a = 1 }
    elseif model.canCall then
        button.backgroundColor = { r = 0.12, g = 0.45, b = 0.12, a = 1 }
        button.backgroundColorMouseOver = { r = 0.18, g = 0.55, b = 0.18, a = 1 }
    else
        button.backgroundColor = { r = 0.22, g = 0.22, b = 0.22, a = 1 }
    end

    if not model.canCall then
        button.backgroundColorMouseOver = button.backgroundColor
    end
end

local function drawStateHeader(section, model)
    section:drawText(model.displayName, 6, 3, 0.9, 0.9, 0.9, 1, UIFont.Small)
    local nameW = getTextManager():MeasureStringX(UIFont.Small, model.displayName)

    local stateLabel = "Last Seen - " .. model.state
    if model.stateTimer then
        stateLabel = stateLabel .. " in " .. BarteringTiming.formatCountdown(model.stateTimer)
    end
    if model.stateAge and model.stateAge >= STALE_AGE_SECONDS then
        stateLabel = stateLabel .. " (" .. BarteringTiming.formatAge(model.stateAge) .. ")"
    end

    local sr, sg, sb = getStateColor(model.state)
    section:drawText(stateLabel, 6 + nameW + 12, 3, sr, sg, sb, 1, UIFont.Small)

    if model.isDeceased and model.respawnSeconds > 0 then
        local stateW = getTextManager():MeasureStringX(UIFont.Small, stateLabel)
        section:drawText(" - Replaced in " .. BarteringTiming.formatCountdown(model.respawnSeconds),
            6 + nameW + 12 + stateW, 3, 0.75, 0.75, 0.75, 1, UIFont.Small)
    end
end

local function drawRelationshipRow(section, model, player, bartererId, y, bgR, bgG, bgB)
    section:drawText("Relationship:", 6, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
    local labelW = getTextManager():MeasureStringX(UIFont.Small, "Relationship:")
    local starsX = 6 + labelW + 8

    local mx, my = section:getMouseX(), section:getMouseY()
    local mouseInside = mx >= 0 and mx < section.width
        and my >= 0 and my < section.height
        and section:getY() + my >= CONTENT_TOP

    local relationValue = Bartering.Relations.get(player, bartererId)
    local tipText = nil
    for i = 1, STAR_COUNT do
        local sx = starsX + (i - 1) * (STAR_SIZE + STAR_GAP) + STAR_SIZE / 2
        local sy = y + LINE_H / 2
        drawStar(section, sx, sy, Bartering.Relations.getStarFill(player, bartererId, i), STAR_SIZE, bgR, bgG, bgB)
        if mouseInside and not tipText
            and math.abs(mx - sx) <= STAR_SIZE / 2 and math.abs(my - sy) <= STAR_SIZE / 2 then
            local starStart = (i - 1) * Bartering.Relations.VALUE_PER_STAR
            local inStar = math.max(0, math.min(Bartering.Relations.VALUE_PER_STAR, relationValue - starStart))
            tipText = math.floor(inStar) .. "/" .. Bartering.Relations.VALUE_PER_STAR
            if i == 1 then
                tipText = tipText .. "\nUnlocks Walky Talkie features with this barterer"
            elseif i == 5 or i == 10 then
                tipText = tipText .. "\nUnlocks extra item slot"
            end
        end
    end

    if model.saleActive then
        local saleX = starsX + STAR_COUNT * STAR_SIZE + (STAR_COUNT - 1) * STAR_GAP + 8
        section:drawText("Weekly Sale!", saleX, y + 3, 0.2, 0.9, 0.2, 1, UIFont.Small)
    end

    return tipText
end

local function drawInfoRow(section, x, y, w, text, r, g, b)
    BarteringUIUtils.drawRow(section, x, y, w, LINE_H, 0.8)
    section:drawText(text, x + 4, y + 2, r, g, b, 1, UIFont.Small)
end

local function drawStockRows(section, model, x, y, w)
    local valueX = x + w * VALUE_COLUMN_FRACTION

    if not model.stockRows then
        drawInfoRow(section, x, y, w, model.stockMessage, 0.55, 0.55, 0.55)
        return
    end

    BarteringUIUtils.drawRow(section, x, y, w, LINE_H, 0.8)
    section:drawText("Items for Trade", x + 4, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
    section:drawTextCentre("Value", valueX, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
    section:drawTextRight("Level Requirement", x + w - 4, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
    y = y + LINE_H + ROW_GAP

    for _, row in ipairs(model.stockRows) do
        BarteringUIUtils.drawRow(section, x, y, w, LINE_H, 0.9, 0.08, 0.08, 0.08)
        if row.texture then
            section:drawTextureScaledAspect(row.texture, x + 3, y + 2, 14, 14, 1, 1, 1, 1)
        end
        section:drawText(row.label, x + 20, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        section:drawTextCentre(row.valueText, valueX, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        if row.onSale then
            local lvlW = getTextManager():MeasureStringX(UIFont.Small, row.levelText)
            section:drawTextRight("15% off!", x + w - 4 - lvlW - 8, y + 2, 0.2, 0.9, 0.2, 1, UIFont.Small)
        end
        section:drawTextRight(row.levelText, x + w - 4, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        y = y + LINE_H + ROW_GAP
    end
end

function BarteringTabPanel:createBartererSection(bartererId, y)
    local model = buildSectionModel(bartererId)
    local sectionW = self.width - PANEL_PAD * 2 - SCROLL_BAR_W

    local section = ISPanelJoypad:new(PANEL_PAD, y, sectionW, model.height)
    section.background = false
    section:initialise()
    section:instantiate()
    section.bartererId = bartererId
    section.model = model
    section.baseY = y

    section.callButton = ISButton:new(0, LINE_H + 4, math.floor(sectionW / 2) - 2, BTN_H, "Call", self, nil, nil)
    section.callButton:setOnClick(BarteringTabPanel.onCallBarterer, bartererId)
    section.callButton:initialise()
    section.callButton:instantiate()
    section.callButton.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    section:addChild(section.callButton)
    applyCallButtonStyle(section, model)

    section.resizeTo = function(width)
        section:setWidth(width)
        section.callButton:setWidth(math.floor(width / 2) - 2)
    end

    section.showStarTooltip = function(text)
        if not text then
            if section.starTooltip and section.starTooltip:getIsVisible() then
                section.starTooltip:setVisible(false)
                section.starTooltip:removeFromUIManager()
            end
            return
        end
        if not section.starTooltip then
            section.starTooltip = ISToolTip:new()
            section.starTooltip:setOwner(section)
            section.starTooltip:setVisible(false)
            section.starTooltip:setAlwaysOnTop(true)
            section.starTooltip.maxLineWidth = 300
        end
        if not section.starTooltip:getIsVisible() then
            section.starTooltip:addToUIManager()
            section.starTooltip:setVisible(true)
        end
        section.starTooltip.description = text
        section.starTooltip:setDesiredPosition(getMouseX() + 12, getMouseY() + 12)
    end

    section.prerender = function()
        ISPanelJoypad.prerender(section)
        local current = section.model
        local player = getSpecificPlayer(0)

        local bgR, bgG, bgB = 0.15, 0.15, 0.15
        if current.isDeceased then
            bgR, bgG, bgB = 0.2, 0.1, 0.1
        end
        section:drawRect(0, 0, section.width, section.height, 0.9, bgR, bgG, bgB)
        section:drawRectBorder(0, 0, section.width, section.height, 1, 0.3, 0.3, 0.3)

        drawStateHeader(section, current)

        local rowY = LINE_H + 4 + BTN_H + 4
        local contentW = section.width - 12

        local tipText = nil
        if current.showRelationships then
            tipText = drawRelationshipRow(section, current, player, bartererId, rowY, bgR, bgG, bgB)
            rowY = rowY + LINE_H + 4
        end
        section.showStarTooltip(tipText)

        for _, row in ipairs(current.timerRows) do
            drawInfoRow(section, 6, rowY, contentW, row.label, 0.7, 0.7, 0.7)
            local labelW = getTextManager():MeasureStringX(UIFont.Small, row.label)
            section:drawText(BarteringTiming.formatCountdown(row.seconds),
                6 + 4 + labelW + 4, rowY + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
            rowY = rowY + LINE_H + ROW_GAP
        end

        drawStockRows(section, current, 6, rowY + SECTION_GAP, contentW)
    end

    self:addChild(section)
    self.bartererSections[bartererId] = section
    table.insert(self.sectionOrder, bartererId)
    return y + model.height
end

function BarteringTabPanel:getKnownBartererIds()
    local player = getSpecificPlayer(0)
    local ids = {}
    for bartererId in pairs(Bartering.Barterers) do
        if not player or Bartering.isBartererKnown(player, bartererId) then
            table.insert(ids, bartererId)
        end
    end
    table.sort(ids)
    return ids
end

function BarteringTabPanel:rebuildLayout()
    for _, section in pairs(self.bartererSections) do
        section.showStarTooltip(nil)
        self:removeChild(section)
    end
    if self.vscroll then
        self:removeChild(self.vscroll)
    end

    self.bartererSections = {}
    self.sectionOrder = {}

    local knownIds = self:getKnownBartererIds()
    self.knownCount = #knownIds

    local y = CONTENT_TOP + 4
    for _, bartererId in ipairs(knownIds) do
        y = self:createBartererSection(bartererId, y) + GAP_BETWEEN
    end

    self:addScrollBars()
    self:setScrollHeight(y + PANEL_PAD)
end

function BarteringTabPanel:repositionSections()
    local sectionW = self.width - PANEL_PAD * 2 - SCROLL_BAR_W
    local y = CONTENT_TOP + 4
    for _, bartererId in ipairs(self.sectionOrder) do
        local section = self.bartererSections[bartererId]
        section:setHeight(section.model.height)
        section.resizeTo(sectionW)
        section.baseY = y
        y = y + section.model.height + GAP_BETWEEN
    end
    self:setScrollHeight(y + PANEL_PAD)
end

function BarteringTabPanel:refreshStockCache()
    local changed = false
    for bartererId, request in pairs(pendingRefresh) do
        local current = Bartering.getBartererStockMap(bartererId)
        if request.immediate or stockChanged(current, request.baseline) then
            pendingRefresh[bartererId] = nil
            setCachedStock(bartererId, current)
            changed = true
        end
    end

    for _, bartererId in ipairs(self.sectionOrder) do
        if getCachedStock(bartererId)
            and Bartering.getBartererStockRefreshRemainingHours(bartererId) <= 0 then
            setCachedStock(bartererId, nil)
            changed = true
        end
    end
    return changed
end

function BarteringTabPanel:onMouseWheel(del)
    self:setYScroll(self:getYScroll() - (del * 18))
    return true
end

function BarteringTabPanel:createChildren()
    ISPanelJoypad.createChildren(self)
    self:addScrollBars()
    self:rebuildLayout()
end

function BarteringTabPanel:update()
    ISPanelJoypad.update(self)

    self.metCheckTimer = (self.metCheckTimer or 0) + 1
    if self.metCheckTimer >= MET_CHECK_INTERVAL_TICKS then
        self.metCheckTimer = 0
        if #self:getKnownBartererIds() ~= self.knownCount then
            self:rebuildLayout()
            return
        end
    end

    self:refreshStockCache()

    self.tick = (self.tick or 0) + 1
    local needReposition = false
    for _, bartererId in ipairs(self.sectionOrder) do
        local section = self.bartererSections[bartererId]
        local model = buildSectionModel(bartererId, section.model, self.tick)
        if model.height ~= section.model.height then
            needReposition = true
        end
        section.model = model
        applyCallButtonStyle(section, model)
    end

    if needReposition then
        self:repositionSections()
    end
end

function BarteringTabPanel:prerender()
    ISPanelJoypad.prerender(self)

    if self.parent and self.parent.viewList then
        if self.parent.width < MIN_PANEL_W then
            self:setWidthAndParentWidth(MIN_PANEL_W)
        elseif self.parent.width ~= self.width then
            self:setWidth(self.parent.width)
        end
        local newH = self.parent.height - self.parent.tabHeight
        if newH ~= self.height then
            self:setHeight(newH)
        end
        if self.width ~= self.lastLayoutW then
            self.lastLayoutW = self.width
            self:repositionSections()
        end
    end

    local scrollY = self:getYScroll()
    for _, bartererId in ipairs(self.sectionOrder) do
        local section = self.bartererSections[bartererId]
        section:setY(section.baseY + scrollY)
    end

    if self.knownCount == 0 then
        local msg = "No Known Barterers"
        local msgW = getTextManager():MeasureStringX(UIFont.Medium, msg)
        self:drawText(msg, self.width / 2 - msgW / 2, -scrollY + CONTENT_TOP + 20, 0.6, 0.6, 0.6, 1, UIFont.Medium)
    end

    if self.vscroll then
        self.vscroll:setY(CONTENT_TOP)
        self.vscroll:setHeight(self.height - CONTENT_TOP)
    end
    self:setStencilRect(0, CONTENT_TOP, self.width, self.height - CONTENT_TOP)
end

function BarteringTabPanel:render()
    ISPanelJoypad.render(self)
    self:clearStencilRect()
    local pinY = -self:getYScroll()
    self:drawRect(0, pinY, self.width, CONTENT_TOP, 1, 0, 0, 0)
    self:drawText("Barterers", PANEL_PAD + 2, pinY + PANEL_PAD, 0.9, 0.9, 0.9, 1, UIFont.Medium)
end

function BarteringTabPanel:new(x, y, width, height)
    local o = ISPanelJoypad:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.bartererSections = {}
    o.sectionOrder = {}
    o.knownCount = 0
    return o
end

local originalCreateChildren = ISCharacterInfoWindow.createChildren

function ISCharacterInfoWindow:createChildren()
    originalCreateChildren(self)

    local barteringView = BarteringTabPanel:new(0, 0, self.width, self.height - self.panel.tabHeight)
    barteringView:initialise()
    self.panel:addView(TAB_NAME, barteringView)
end
