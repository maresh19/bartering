require "ISUI/ISPanel"
require "ISUI/Maps/ISWorldMap"
require "ISUI/ISPanelJoypad"
require "ISUI/ISButton"
require "Bartering"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local BarteringDialogue = require "BarteringDialogue"
local BarteringHire = require "BarteringHire"
local ISPanelJoypad = _G["ISPanelJoypad"]
local ISButton = _G["ISButton"]
local UIFont = _G["UIFont"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local instanceItem = _G["instanceItem"]
local BarteringTiming = require "BarteringTiming"

local LINE_H = 18
local ROW_GAP = 2
local PANEL_PAD = 4
local BTN_H = 20
local GAP_BETWEEN = 4
local HEADER_H = 22
local TAB_NAME = "Bartering"
local VALUE_COLUMN_FRACTION = 0.5
local STAR_COUNT = 10
local STAR_GAP = 2
local STAR_SIZE = 16
local SCROLL_BAR_W = 17
local SHARED_WAKE_H = LINE_H + ROW_GAP + 6
local CONTENT_TOP = PANEL_PAD + HEADER_H
local NAV_STAR_SIZE = 16
local navStarTex = getTexture("media/textures/nav_star.png")
local MIN_PANEL_W = 420
local SECTION_GAP = 5
local MET_CHECK_INTERVAL_TICKS = 60
local STALE_AGE_SECONDS = 60

local drawStar = Bartering.Relations.drawStar

local STATE_INFO = {
    Waiting = { label = "At Home" },
    Approach = { label = "Heading to Meetup" },
    Return = { label = "Returning Home" },
    Retreat = { label = "In Combat" },
    DefendPistol = { label = "In Combat" },
    DefendKnife = { label = "In Combat" },
    BlockedByDoor = { label = "Waiting at locked door" },
    BlockedRoute = { label = "Cant find a way in" },
    Sleeping = { label = "Sleeping in", color = { 0.5, 0.5, 0.8 } },
    Deceased = { label = "Deceased", color = { 0.9, 0.25, 0.25 } },
    Hostile = { label = "Hostile", color = { 0.9, 0.15, 0.15 } },
    ["Arriving to make amends"] = { label = "Arriving to make amends in", color = { 0.9, 0.15, 0.15 } },
    Hired = { label = "Hired for", color = { 0.85, 0.75, 0.3 } },
    ["Waiting for repayment"] = { label = "Waiting for repayment", color = { 0.95, 0.55, 0.1 } },
    Working = { label = "Working", color = { 0.85, 0.75, 0.3 } },
    ["Heading to Meetup"] = { label = "Heading to Meetup in", color = { 0.3, 0.8, 1.0 } },
    ["Returning Home"] = { label = "Returning Home in", color = { 1.0, 0.8, 0.2 } },
    ["Arrived at Meetup"] = { label = "Arrived at Meetup", color = { 0.35, 0.95, 0.75 } },
    ["Waiting at Meetup"] = { label = "Waiting at Meetup for", color = { 0.35, 0.95, 0.75 } },
    ["Waiting at locked door"] = { label = "Waiting at locked door", color = { 1.0, 0.45, 0.35 } },
    ["Cant find a way in"] = { label = "Cant find a way in", color = { 1.0, 0.45, 0.35 } },
}

local DEFAULT_STATE_COLOR = { 0.4, 0.9, 0.4 }

local function resolveStateLabel(snapshot)
    if snapshot.state == "Waiting" and snapshot.calledIn then
        return "Arrived at Meetup"
    end
    return STATE_INFO[snapshot.state] and STATE_INFO[snapshot.state].label or snapshot.state
end

local itemInfoCache = {}

local function getItemInfo(itemName)
    local info = itemInfoCache[itemName]
    if info then
        return info
    end
    local item = instanceItem(itemName)
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
    return Bartering.getPlayerTable(player, "BarteringStockIntel")
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

function Bartering.refreshBartererStockCache(bartererId)
    setCachedStock(bartererId, Bartering.getBartererStockMap(bartererId))
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

local function getHomeRemainingSeconds(bartererId)
    if BarteringHire.isHired(bartererId) then
        return nil
    end

    local returningHours = Bartering.getBartererReturningHomeRemainingHours(bartererId, getSpecificPlayer(0))
    if returningHours > 0 then
        return BarteringTiming.gameHoursToRealSeconds(returningHours)
    end

    local snapshot = Bartering.getLiveBartererSnapshot(bartererId)
    if not snapshot then
        return nil
    end

    local pendingDeparture = snapshot.departureAtHours ~= nil
    if not pendingDeparture and snapshot.state ~= "Return" then
        return nil
    end

    local waiting = 0
    if pendingDeparture then
        waiting = BarteringTiming.remainingRealSeconds(snapshot.departureAtHours)
    end
    local travel = BarteringTiming.travelSecondsTo(Bartering.Barterers[bartererId],
        snapshot.x, snapshot.y)
    if waiting + travel <= 0 then
        return nil
    end
    return waiting + travel
end

local function resolveBartererState(bartererId)
    local player = getSpecificPlayer(0)
    local lifeState = Bartering.getBartererLifeState(bartererId)
    if not Bartering.isBartererDeathHidden(bartererId) then
        if lifeState.permanentlyDead then
            return "Deceased", 0
        end

        local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
        if respawnRemainingHours > 0 then
            return "Deceased", BarteringTiming.gameHoursToRealSeconds(respawnRemainingHours)
        end
    end

    if BarteringHire.isHired(bartererId) and not BarteringHire.isHiredBy(player, bartererId) then
        return "Working", 0
    end

    if BarteringHire.isHiredBy(player, bartererId) then
        local hireHours = BarteringHire.getRemainingHours(bartererId)
        if hireHours <= 0 then
            return "Returning Home", 0
        end
        if hireHours <= BarteringHire.getHireWarningHours() then
            return "Waiting for repayment", 0
        end
        return "Hired", 0, BarteringTiming.gameHoursToRealSeconds(hireHours)
    end

    if Bartering.Hostility.isHostileTo(bartererId, player) then
        if Bartering.Hostility.isAmendsCalledFor(bartererId, player) then
            local amendsArrival = Bartering.getBartererArrivalRemainingSeconds(bartererId)
            if amendsArrival then
                return "Arriving to make amends", 0, amendsArrival
            end
        end
        return "Hostile", 0
    end

    if not BarteringHire.isHired(bartererId) then
        local returningRemainingHours = Bartering.getBartererReturningHomeRemainingHours(bartererId, player)
        if returningRemainingHours > 0 then
            return "Returning Home", 0
        end
    end

    local live = Bartering.getLiveBartererSnapshot(bartererId)
    if live then
        return resolveStateLabel(live), 0, nil, 0
    end

    local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(bartererId)
    if arrivalRemaining then
        if Bartering.isBartererWaitingAtMeetup(bartererId) then
            return "Waiting at Meetup", 0, arrivalRemaining
        end
        return "Heading to Meetup", 0, arrivalRemaining
    end

    local snapshot = Bartering.getBartererSnapshot(bartererId)
    local lastLabel = snapshot and resolveStateLabel(snapshot)

    if lastLabel == "Returning Home"
        and BarteringTiming.remainingHours(lifeState.returningHomeAt) <= 0 then
        return "At Home", 0
    end

    if lastLabel and lastLabel ~= "At Home" then
        return lastLabel, 0, nil, getSnapshotAgeSeconds(snapshot)
    end

    if not Bartering.isBartererCallOpenNow(bartererId) then
        return "Sleeping", 0
    end

    if lastLabel then
        return lastLabel, 0, nil, getSnapshotAgeSeconds(snapshot)
    end

    return "At Home", 0
end

local function getBartererState(bartererId)
    local state, respawnSeconds, stateTimer, stateAge = resolveBartererState(bartererId)
    if state == "Returning Home" and not stateTimer then
        stateTimer = getHomeRemainingSeconds(bartererId)
    end
    return state, respawnSeconds, stateTimer, stateAge
end

local function buildQuestRow(player, bartererId)
    local quest = player and Bartering.Quests.getActive(player, bartererId)
    if not quest then
        return nil
    end
    return {
        bartererId = bartererId,
        label = string.format("Active Quests - Recover %s from %s",
            tostring(quest.itemName), Bartering.Quests.getPlaceReference(quest, player)),
        x = quest.x,
        y = quest.y,
    }
end

local function getStateColor(state)
    local info = STATE_INFO[state]
    local color = info and info.color or DEFAULT_STATE_COLOR
    return color[1], color[2], color[3]
end

local function formatRealCountdown(hours)
    return BarteringTiming.formatCountdown(BarteringTiming.gameHoursToRealSeconds(hours))
end

local function canCallBarterer(player, bartererId)
    return player ~= nil and Bartering.hasWalkieTalkie(player)
        and Bartering.getCallBlockReason(player, bartererId, formatRealCountdown) == nil
end

local function getCallButtonTooltip(player, bartererId, hasTalkie)
    if not hasTalkie then
        return "Requires Walkie Talkie"
    end

    local blockReason = Bartering.getCallBlockReason(player, bartererId, formatRealCountdown)
    if blockReason then
        return blockReason
    end

    local displayName = Bartering.getBartererDisplayName(bartererId)
    if Bartering.Hostility.isHostileTo(bartererId, player) then
        return "Call " .. displayName .. " over to make amends"
    end

    if not Bartering.isBartererCallOpenNow(bartererId) then
        local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(bartererId)
        return string.format("%s is asleep and accepts calls between %02d:00 and %02d:00 - awake in %s",
            displayName, callStartHour, callEndHour,
            formatRealCountdown(BarteringTiming.hoursUntilTimeOfDay(callStartHour)))
    end

    return "Call " .. displayName .. " for stock, errands and meetings"
end

local function getWakeRemainingSeconds(bartererId)
    if Bartering.isBartererCallOpenNow(bartererId) then
        return nil
    end
    local startHour = Bartering.getBartererCallWindowHours(bartererId)
    return BarteringTiming.gameHoursToRealSeconds(BarteringTiming.hoursUntilTimeOfDay(startHour))
end

local function buildTimerRows(bartererId)
    local rows = {}
    local wake = getWakeRemainingSeconds(bartererId)
    if wake and not Bartering.areCallWindowsIdentical() then
        table.insert(rows, { label = "Awake In:", seconds = wake })
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

    if Bartering.isBartererStockRefreshPending(bartererId) then
        return nil, "No stock data"
    end

    local requirementByItem, orderByItem = Bartering.getItemRequirementMap(bartererId)
    local rows = {}
    for itemName, qty in pairs(stock) do
        local info = getItemInfo(itemName)
        local label = info.displayName
        if qty > 1 then
            label = label .. " x" .. tostring(qty)
        end
        table.insert(rows, {
            order = orderByItem[itemName] or math.huge,
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

    table.sort(rows, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.label < b.label
    end)
    return rows, nil
end

local STOCK_REBUILD_INTERVAL_TICKS = 30

local function buildSectionModel(bartererId, previous, tick)
    local player = getSpecificPlayer(0)
    local barterer = Bartering.Barterers[bartererId]
    local state, respawnSeconds, stateTimer, stateAge = getBartererState(bartererId)
    local hasTalkie = player and Bartering.hasWalkieTalkie(player) or false

    local version = stockVersion[bartererId] or 0
    local stockRows, stockMessage
    if previous and previous.stockVersion == version
        and tick and tick - previous.stockBuiltAt < STOCK_REBUILD_INTERVAL_TICKS then
        stockRows, stockMessage = previous.stockRows, previous.stockMessage
        tick = previous.stockBuiltAt
    else
        stockRows, stockMessage = buildStockRows(player, bartererId, barterer)
    end

    local hostile = player and Bartering.Hostility.isHostileTo(bartererId, player) or false

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
        lowRelationship = player and Bartering.getSandboxBoolean("EnableRelationships", true)
            and Bartering.Relations.getStarCount(player, bartererId) < SandboxVars.Bartering.CallRelationshipStars
            and not hostile or false,
        quest = buildQuestRow(player, bartererId),
    }

    local height = LINE_H + 4 + BTN_H + 4
    if model.showRelationships then
        height = height + LINE_H + 4
    end
    if model.quest then
        height = height + LINE_H + ROW_GAP
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
    if not Bartering.hasWalkieTalkie(player) then
        player:Say("I need a walkie talkie to make a call.")
        return
    end
    if not canCallBarterer(player, bartererId) then
        return
    end
    BarteringDialogUI.open(player, bartererId, 0, 0, 0, nil, true)
    if not Bartering.isBartererCallOpenNow(bartererId) then
        sendClientCommand(player, "Bartering", "callBarterer", { bartererId = bartererId })
    end
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
    if model.stateTimer and model.stateTimer > 0 then
        local info = STATE_INFO[model.state]
        stateLabel = "Last Seen - " .. (info and info.label or model.state) .. " " .. BarteringTiming.formatCountdown(model.stateTimer)
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
            elseif i == 8 then
                tipText = tipText .. "\nUnlocks Hire Barterer"
            end
        end
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

    local labelMaxW = valueX - x - 20 - 4
    local mouseX = getMouseX() - section:getAbsoluteX()
    local mouseY = getMouseY() - section:getAbsoluteY()
    local hoveredRow = nil

    for _, row in ipairs(model.stockRows) do
        BarteringUIUtils.drawRow(section, x, y, w, LINE_H, 0.9, 0.08, 0.08, 0.08)
        if row.texture then
            section:drawTextureScaledAspect(row.texture, x + 3, y + 2, 14, 14, 1, 1, 1, 1)
        end
        local displayLabel = BarteringUIUtils.ellipsize(row.label, labelMaxW)
        section:drawText(displayLabel, x + 20, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        section:drawTextCentre(row.valueText, valueX, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        if row.onSale then
            local lvlW = getTextManager():MeasureStringX(UIFont.Small, row.levelText)
            section:drawTextRight("15% off!", x + w - 4 - lvlW - 8, y + 2, 0.2, 0.9, 0.2, 1, UIFont.Small)
        end
        section:drawTextRight(row.levelText, x + w - 4, y + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
        if mouseX >= x and mouseX <= x + w and mouseY >= y and mouseY < y + LINE_H then
            hoveredRow = row
        end
        y = y + LINE_H + ROW_GAP
    end

    local tipText = nil
    if hoveredRow and hoveredRow.label ~= BarteringUIUtils.ellipsize(hoveredRow.label, labelMaxW) then
        tipText = hoveredRow.label
    end
    BarteringUIUtils.showHoverTooltip(section, "stockTooltip", tipText)
end

local function createMapButton(panel, parentW, rowY, target)
    local button = ISButton:new(parentW - NAV_STAR_SIZE - 6, rowY,
        NAV_STAR_SIZE, NAV_STAR_SIZE, "", panel, nil, nil)
    button:setOnClick(BarteringTabPanel.onShowOnMap, target)
    button:initialise()
    button:instantiate()
    button:setImage(navStarTex)
    button.tooltip = "Show on Map"
    button.displayBackground = false
    return button
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

    section.mapButton = createMapButton(self, sectionW,
        LINE_H + 4 + math.floor((BTN_H - NAV_STAR_SIZE) / 2), { bartererId = bartererId })
    section:addChild(section.mapButton)

    section.questButton = createMapButton(self, sectionW, 0, model.quest)
    section.questButton:setVisible(model.quest ~= nil)
    section:addChild(section.questButton)

    section.resizeTo = function(width)
        section:setWidth(width)
        section.callButton:setWidth(math.floor(width / 2) - 2)
        section.mapButton:setX(width - NAV_STAR_SIZE - 6)
        section.questButton:setX(width - NAV_STAR_SIZE - 6)
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
        BarteringUIUtils.showHoverTooltip(section, "starTooltip", tipText)

        if current.saleActive then
            drawInfoRow(section, 6, rowY, contentW, "Weekly Sale!", 0.2, 0.9, 0.2)
            rowY = rowY + LINE_H + ROW_GAP
        end

        if current.quest then
            section.questButton:setVisible(true)
            section.questButton.onClickArgs = { current.quest }
            section.questButton:setY(rowY + math.floor((LINE_H - NAV_STAR_SIZE) / 2))
            local questMaxW = contentW - NAV_STAR_SIZE - 10
            local truncated = BarteringUIUtils.ellipsize(current.quest.label, questMaxW)
            drawInfoRow(section, 6, rowY, contentW, truncated, 0.85, 0.8, 0.45)
            local mx = section:getMouseX()
            local my = section:getMouseY()
            local questTip = nil
            if truncated ~= current.quest.label
                and mx >= 6 and mx <= 6 + contentW
                and my >= rowY and my <= rowY + LINE_H then
                questTip = current.quest.label
            end
            BarteringUIUtils.showHoverTooltip(section, "questTooltip", questTip)
            rowY = rowY + LINE_H + ROW_GAP
        else
            section.questButton:setVisible(false)
        end

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

function BarteringTabPanel:onShowOnMap(_, target)
    local x, y = target.x, target.y
    if not x and target.bartererId then
        x, y = Bartering.getBartererMapPosition(target.bartererId)
    end

    ISWorldMap.ShowWorldMap(0)
    ISWorldMap_instance.mapAPI:centerOn(x, y)
    ISWorldMap_instance.mapAPI:setZoom(50.0)
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

function BarteringTabPanel:rebuildSharedStatusRow(knownIds)
    if #knownIds == 0 or not Bartering.areCallWindowsIdentical() then
        self.sharedStatusRow = nil
        self.sharedStatusH = 0
        return
    end
    for _, id in ipairs(knownIds) do
        if not Bartering.isBartererAwakeNow(id) then
            local startHour = Bartering.getBartererCallWindowHours(id)
            self.sharedStatusRow = {
                label = "Barterers wake up in:",
                seconds = BarteringTiming.gameHoursToRealSeconds(
                    BarteringTiming.hoursUntilTimeOfDay(startHour)),
            }
            self.sharedStatusH = SHARED_WAKE_H
            return
        end
    end
    local refreshSeconds = BarteringTiming.gameHoursToRealSeconds(
        Bartering.getBartererStockRefreshRemainingHours("Barterer1"))
    self.sharedStatusRow = {
        label = "Stock refreshes in:",
        seconds = refreshSeconds,
    }
    self.sharedStatusH = SHARED_WAKE_H
end

function BarteringTabPanel:rebuildLayout()
    for _, section in pairs(self.bartererSections) do
        BarteringUIUtils.showHoverTooltip(section, "starTooltip", nil)
        BarteringUIUtils.showHoverTooltip(section, "stockTooltip", nil)
        BarteringUIUtils.showHoverTooltip(section, "questTooltip", nil)
        self:removeChild(section)
    end
    if self.vscroll then
        self:removeChild(self.vscroll)
    end

    self.bartererSections = {}
    self.sectionOrder = {}

    local knownIds = self:getKnownBartererIds()
    self.knownCount = #knownIds

    self:rebuildSharedStatusRow(knownIds)
    local y = CONTENT_TOP + 4 + self.sharedStatusH
    for _, bartererId in ipairs(knownIds) do
        y = self:createBartererSection(bartererId, y) + GAP_BETWEEN
    end

    self:addScrollBars()
    self:setScrollHeight(y + PANEL_PAD)
end

function BarteringTabPanel:repositionSections()
    local sectionW = self.width - PANEL_PAD * 2 - SCROLL_BAR_W
    local y = CONTENT_TOP + 4 + self.sharedStatusH
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
            and Bartering.isBartererStockRefreshPending(bartererId) then
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

    local prevSharedStatusH = self.sharedStatusH or 0
    self:rebuildSharedStatusRow(self.sectionOrder)
    if self.sharedStatusH ~= prevSharedStatusH then
        self:repositionSections()
    end

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

    self:setStencilRect(0, CONTENT_TOP, self.width, self.height - CONTENT_TOP)

    local scrollY = self:getYScroll()
    for _, bartererId in ipairs(self.sectionOrder) do
        local section = self.bartererSections[bartererId]
        section:setY(section.baseY + scrollY)
    end

    if self.sharedStatusRow then
        local wakeY = CONTENT_TOP + 4 + scrollY
        local contentW = self.width - PANEL_PAD * 2 - SCROLL_BAR_W
        local fullText = self.sharedStatusRow.label .. " " .. BarteringTiming.formatCountdown(self.sharedStatusRow.seconds)
        local fullW = getTextManager():MeasureStringX(UIFont.Medium, fullText)
        local textX = PANEL_PAD + math.max(0, math.floor((contentW - fullW) / 2))
        BarteringUIUtils.drawRow(self, PANEL_PAD, wakeY, contentW, LINE_H, 0.8)
        self:drawText(fullText, textX, wakeY + 1, 0.85, 0.85, 0.85, 1, UIFont.Medium)
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
end

local function drawStickyHeader(panel, pin, top, title)
    panel:drawRect(0, pin + top, panel.width, CONTENT_TOP, 1, 0, 0, 0)
    panel:drawText(title, PANEL_PAD + 2, pin + top + PANEL_PAD, 0.9, 0.9, 0.9, 1, UIFont.Medium)
end

function BarteringTabPanel:render()
    ISPanelJoypad.render(self)
    self:clearStencilRect()

    drawStickyHeader(self, -self:getYScroll(), 0, "Barterers")
end

function BarteringTabPanel:new(x, y, width, height)
    local o = ISPanelJoypad:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.bartererSections = {}
    o.sectionOrder = {}
    o.knownCount = 0
    o.sharedStatusRow = nil
    o.sharedStatusH = 0
    return o
end

local originalCreateChildren = ISCharacterInfoWindow.createChildren

function ISCharacterInfoWindow:createChildren()
    originalCreateChildren(self)

    local barteringView = BarteringTabPanel:new(0, 0, self.width, self.height - self.panel.tabHeight)
    barteringView:initialise()
    self.panel:addView(TAB_NAME, barteringView)
end
