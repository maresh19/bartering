require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISUI3DModel"
require "Bartering"
require "BarteringQuests"
require "BarteringTiming"

local BarteringUIUtils = require "BarteringUIUtils"
local ISPanel = _G["ISPanel"]
local ISButton = _G["ISButton"]
local ISUI3DModel = _G["ISUI3DModel"]
local IsoDirections = _G["IsoDirections"]
local UIFont = _G["UIFont"]
local getTextManager = _G["getTextManager"]
local getTimeInMillis = _G["getTimeInMillis"]
local sendClientCommand = _G["sendClientCommand"]
local InventoryItemFactory = _G["InventoryItemFactory"]
local BarteringTiming = require "BarteringTiming"

BarteringDialogUI = ISPanel:derive("BarteringDialogUI")

BarteringDialogUI.HeaderHeight = 28
BarteringDialogUI.MaxDistanceFromOpenTile = 3
BarteringDialogUI.PortraitX = 12
BarteringDialogUI.PortraitY = 40
BarteringDialogUI.PortraitW = 112
BarteringDialogUI.PortraitH = 148
BarteringDialogUI.ButtonH = 25
BarteringDialogUI.ButtonW = 118
BarteringDialogUI.ButtonGap = 8
BarteringDialogUI.CallButtonW = 96
BarteringDialogUI.QuestItemCheckTicks = 20
BarteringDialogUI.ThanksDurationMs = 10000
BarteringDialogUI.ReplyDurationMs = 8000

local activeDialogs = {}

local function formatCooldown(hours)
    local days = math.floor(hours / 24)
    local remainingHours = math.floor(hours % 24)
    if days > 0 then
        return string.format("%d day(s) %d hour(s)", days, remainingHours)
    end
    return string.format("%d hour(s)", math.max(1, remainingHours))
end

local function wrapText(text, maxWidth)
    local lines = {}
    local line = ""
    for word in string.gmatch(text, "%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if getTextManager():MeasureStringX(UIFont.Small, candidate) > maxWidth and line ~= "" then
            table.insert(lines, line)
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then
        table.insert(lines, line)
    end
    return lines
end

function BarteringDialogUI:isMet()
    return Bartering.hasMetBarterer(self.player, self.bartererId)
end

function BarteringDialogUI:getTradeBlockReason()
    local bartererState = self.bartererZombie:getVariableString("BartererState") or ""
    if bartererState == "DefendKnife" or bartererState == "DefendPistol" or bartererState == "DefendRifle" then
        return "Barterer is in combat"
    end
    local requiredLevel = Bartering.Barterers[self.bartererId].requiredLevel
    local barterLevel = Bartering.getBarterSkillLevel(self.player)
    if barterLevel < requiredLevel then
        return "Requires Bartering level " .. tostring(requiredLevel) .. " (current: " .. tostring(barterLevel) .. ")"
    end
    return nil
end

function BarteringDialogUI:getQuestBlockReason()
    if Bartering.Quests.getActive(self.player, self.bartererId) then
        return "You are already running an errand for this barterer"
    end
    local remaining = Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId)
    if remaining > 0 then
        return "Nothing needs fetching for another " .. formatCooldown(remaining)
    end
    return nil
end

function BarteringDialogUI:getDialogueText()
    if self.callMode then
        if not self:isMet() then
            return "Static. Whoever this is isn't picking up."
        end
        if getTimeInMillis() < self.callReplyUntil then
            return self.callReply
        end
        local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(self.bartererId)
        if arrivalRemaining then
            return "*tzzt* I'm on my way.*tzzt* I'll be there in about " .. BarteringTiming.formatArrivalEstimateHumanized(arrivalRemaining)
        end
        if self:isBartererApproaching() then
            return "*tzzt* I can see the meetup spot now. *tzzt* Just a second. *tzzt*"
        end
        if self.stockRequested then
            return "*tzzt* Here's what I've got. *tzzt*"
        end
        local quest = Bartering.Quests.getActive(self.player, self.bartererId)
        if quest then
            if quest.id ~= self.openedWithQuestId and not self.hasQuestItem then
                return Bartering.Quests.getFlavorLine(quest)
            end
            return Bartering.Quests.getReminderLine(quest, self.hasQuestItem)
        end
        local remaining = Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId)
        if remaining > 0 then
            return "Nothing I need right now. Ask me again in " .. formatCooldown(remaining) .. "."
        end
        return "*tzzt* What do you need? *tzzt*"
    end

    if not self:isMet() then
        return "The barterer watches you in silence."
    end

    if getTimeInMillis() < self.thanksUntil then
        return "Much obliged. That means something to me - I won't forget it."
    end

    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    if quest then
        if quest.id ~= self.openedWithQuestId and not self.hasQuestItem then
            return Bartering.Quests.getFlavorLine(quest)
        end
        return Bartering.Quests.getReminderLine(quest, self.hasQuestItem)
    end

    local remaining = Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId)
    if remaining > 0 then
        return "Nothing I need right now. Ask me again in " .. formatCooldown(remaining) .. "."
    end

    if self.justIntroduced then
        return "Name's " .. Bartering.getBartererDisplayName(self.bartererId)
            .. ". Im always looking to trade, and now and then I could use an extra hand. Talk to me."
    end

    return "Good to see you still breathing. Got something for me?"
end

function BarteringDialogUI:onIntroduce()
    Bartering.meetBarterer(self.player, self.bartererId)
    sendClientCommand(self.player, "Bartering", "meetBarterer", { bartererId = self.bartererId })
    self.justIntroduced = true
end

function BarteringDialogUI:onTrade()
    local bartererId = self.bartererId
    local player = self.player
    local anchorX, anchorY, anchorZ = self.anchorX, self.anchorY, self.anchorZ
    local zombie = self.bartererZombie
    self:close()
    BarteringBarterUI.open(player, bartererId, anchorX, anchorY, anchorZ, zombie)
end

function BarteringDialogUI:onRequestQuest()
    self.stockRequested = false
    self.callReplyUntil = 0
    sendClientCommand(self.player, "Bartering", "requestQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:onTurnInQuest()
    sendClientCommand(self.player, "Bartering", "turnInQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:onRefreshQuest()
    sendClientCommand(self.player, "Bartering", "debugRefreshQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:onUpdateStock()
    self.callReplyUntil = 0
    self.callStock = Bartering.getBartererStockMap(self.bartererId)
    self.stockRequested = true
    self.thanksUntil = 0
    Bartering.queuePlayerUIStockRefresh(self.bartererId)
end

function BarteringDialogUI:onCallMeetup()
    self.callReplyUntil = 0
    local player = self.player
    local barterer = Bartering.Barterers[self.bartererId]
    if player and barterer then
        local travelSeconds = BarteringTiming.calculateTravelSeconds(
            player:getX(), player:getY(),
            barterer.x, barterer.y,
            barterer.travelSecondsPerTile,
            Bartering.getSandboxNumber("TravelTimeMultiplier", 1))
        Bartering.optimisticCallETA(self.bartererId, getTimeInMillis() + travelSeconds * 1000)
    end
    sendClientCommand(self.player, "Bartering", "callBarterer", { bartererId = self.bartererId })
end

function BarteringDialogUI:onCancelMeetup()
    sendClientCommand(self.player, "Bartering", "cancelBartererMeeting", { bartererId = self.bartererId })
end

function BarteringDialogUI:onUpdateLocation()
    self.callReplyUntil = 0
    sendClientCommand(self.player, "Bartering", "updateBartererLocation", { bartererId = self.bartererId })
end

function BarteringDialogUI:isBartererApproaching()
    local tracked = Bartering.TrackedBarterers and Bartering.TrackedBarterers[self.bartererId]
    return tracked ~= nil and tracked.state == "Approach"
end

function BarteringDialogUI:getCallMeetupBlockReason()
    local displayName = Bartering.getBartererDisplayName(self.bartererId)
    if Bartering.Relations.getStarCount(self.player, self.bartererId) < 1 then
        return "Requires Level 1 Relationship With This Barterer"
    end
    local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(self.bartererId)
    if arrivalRemaining then
        return displayName .. " is already on his way. ETA " .. BarteringTiming.formatDuration(arrivalRemaining)
    end
    if self:isBartererApproaching() then
        return displayName .. " is already heading to the meetup"
    end
    if Bartering.isBartererPermanentlyDead(self.bartererId) then
        return displayName .. " is dead and cannot respawn with the current sandbox settings"
    end
    local lifeState = Bartering.getBartererLifeState(self.bartererId)
    local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
    if respawnRemainingHours > 0 then
        return displayName .. " is dead and will be replaced with a new barterer in "
            .. BarteringTiming.formatDuration(respawnRemainingHours * 3600)
    end
    local callCooldownRemainingHours = BarteringTiming.remainingHours(lifeState.calledInCooldownAt)
    if callCooldownRemainingHours > 0 then
        return displayName .. " call cooldown: " .. BarteringTiming.formatDuration(callCooldownRemainingHours * 3600)
    end
    if not Bartering.isBartererCallOpenNow(self.bartererId) then
        local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(self.bartererId)
        return string.format("%s accepts calls between %02d:00 and %02d:00", displayName, callStartHour, callEndHour)
    end
    return nil
end

function BarteringDialogUI:createButton(label, callback)
    local button = ISButton:new(0, self.height - 36, self.buttonW, BarteringDialogUI.ButtonH, label, self, callback)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    self:addChild(button)
    return button
end

function BarteringDialogUI:initialise()
    ISPanel.initialise(self)

    self.closeButton = ISButton:new(self.width - 30, 4, 22, 20, "X", self, BarteringDialogUI.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    self.closeButton.backgroundColor = { r = 0.25, g = 0.12, b = 0.12, a = 1 }
    self.closeButton.backgroundColorMouseOver = { r = 0.45, g = 0.18, b = 0.18, a = 1 }
    self:addChild(self.closeButton)

    self.avatarPanel = ISUI3DModel:new(
        BarteringDialogUI.PortraitX,
        BarteringDialogUI.PortraitY,
        BarteringDialogUI.PortraitW,
        BarteringDialogUI.PortraitH)
    self:addChild(self.avatarPanel)
    self.avatarPanel:setState("idle")
    self.avatarPanel:setDirection(IsoDirections.S)
    self.avatarPanel:setIsometric(false)
    self.avatarPanel:setZoom(14)
    self.avatarPanel:setYOffset(-0.85)
    self.avatarPanel:setVisible(not self.callMode)
    if self.bartererZombie then
        self.avatarPanel:setCharacter(self.bartererZombie)
    end

    self.introduceButton = self:createButton("Introduce", BarteringDialogUI.onIntroduce)
    self.tradeButton = self:createButton("Trade", BarteringDialogUI.onTrade)
    self.questButton = self:createButton("Retrieve Quest", BarteringDialogUI.onRequestQuest)
    self.turnInButton = self:createButton("Turn in Quest", BarteringDialogUI.onTurnInQuest)
    self.refreshQuestButton = self:createButton("Refresh Quest", BarteringDialogUI.onRefreshQuest)
    self.updateStockButton = self:createButton("Update Stock", BarteringDialogUI.onUpdateStock)
    self.callMeetupButton = self:createButton("Call for a Meet Up", BarteringDialogUI.onCallMeetup)
    self.cancelMeetupButton = self:createButton("Cancel Meetup", BarteringDialogUI.onCancelMeetup)
    self.updateLocationButton = self:createButton("Update Location", BarteringDialogUI.onUpdateLocation)
end

function BarteringDialogUI:refreshButtons()
    local met = self:isMet()
    local quest = Bartering.Quests.getActive(self.player, self.bartererId)

    if self.callMode then
        self.introduceButton:setVisible(false)
        self.tradeButton:setVisible(false)
        self.turnInButton:setVisible(false)
        self.questButton:setVisible(true)
        self.updateStockButton:setVisible(true)
        self.refreshQuestButton:setVisible(met and quest ~= nil and Bartering.getSandboxBoolean("DebugMode", false))

        local displayName = Bartering.getBartererDisplayName(self.bartererId)
        local notMetTooltip = "Meet " .. displayName .. " in person first"

        self.updateStockButton.enable = met
        if met then
            self.updateStockButton.tooltip = "Fetch the current stock list from " .. displayName
        else
            self.updateStockButton.tooltip = notMetTooltip
        end

        local redirecting = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 2
            and (Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil or self:isBartererApproaching())
        local callActive = Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil
        self.updateLocationButton:setVisible(redirecting)
        self.callMeetupButton:setVisible(not callActive and not redirecting)
        self.cancelMeetupButton:setVisible(callActive)

        local callBlock
        if not met then
            callBlock = notMetTooltip
        elseif Bartering.Relations.getStarCount(self.player, self.bartererId) < 1 then
            callBlock = "Requires Level 1 Relationship With This Barterer"
        else
            callBlock = self:getCallMeetupBlockReason()
        end
        self.callMeetupButton.enable = callBlock == nil
        self.callMeetupButton.tooltip = callBlock or "Arrange a meeting with " .. displayName

        self.updateLocationButton.enable = met
        if met then
            self.updateLocationButton.tooltip = "Tells the barterer where you are now, (changes arrival point to this location)."
        else
            self.updateLocationButton.tooltip = notMetTooltip
        end

        local questBlock
        if met then
            questBlock = self:getQuestBlockReason()
        else
            questBlock = notMetTooltip
        end
        self.questButton.enable = met and questBlock == nil
        self.questButton.tooltip = questBlock or "Ask if there is anything he needs help with"

        self.refreshQuestButton.enable = quest ~= nil
        self.refreshQuestButton.tooltip = "Debug only: re-roll this quest and its dialogue"
    else
        self.introduceButton:setVisible(not met)
        self.tradeButton:setVisible(met)
        self.questButton:setVisible(met)
        self.turnInButton:setVisible(met and quest ~= nil)
        self.refreshQuestButton:setVisible(met and quest ~= nil and Bartering.getSandboxBoolean("DebugMode", false))

        self.updateStockButton:setVisible(false)
        self.callMeetupButton:setVisible(false)
        self.cancelMeetupButton:setVisible(false)
        self.updateLocationButton:setVisible(false)

        local tradeBlock = self:getTradeBlockReason()
        self.tradeButton.enable = tradeBlock == nil
        self.tradeButton.tooltip = tradeBlock or "Open the trade window"

        local questBlock = self:getQuestBlockReason()
        self.questButton.enable = questBlock == nil
        self.questButton.tooltip = questBlock or "Ask if there is anything he needs help with"

        local canTurnIn = quest ~= nil and self.hasQuestItem
        self.turnInButton.enable = canTurnIn
        if canTurnIn then
            self.turnInButton.tooltip = "Hand over " .. quest.itemName .. " for "
                .. tostring(Bartering.Quests.REWARD) .. " relations"
        else
            self.turnInButton.tooltip = "You are not carrying the item he asked for"
        end

        self.refreshQuestButton.enable = quest ~= nil
        self.refreshQuestButton.tooltip = "Debug only: re-roll this quest and its dialogue"
    end

    local x = BarteringDialogUI.PortraitX
    for _, button in ipairs({ self.introduceButton, self.tradeButton, self.questButton, self.turnInButton,
        self.refreshQuestButton, self.updateStockButton, self.callMeetupButton, self.cancelMeetupButton, self.updateLocationButton }) do
        if button:getIsVisible() then
            button:setY(self.height - 36)
            button:setX(x)
            x = x + self.buttonW + BarteringDialogUI.ButtonGap
        end
    end
end

function BarteringDialogUI:isOutOfRange()
    return BarteringUIUtils.isPlayerOutOfRange(self.player, self.anchorX, self.anchorY, self.anchorZ,
        BarteringDialogUI.MaxDistanceFromOpenTile)
end

function BarteringDialogUI:update()
    ISPanel.update(self)

    if not self.callMode then
        if self:isOutOfRange() or self.bartererZombie:isDead() then
            self:close()
            return
        end
    end

    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    if not quest then
        if self.hadQuest then
            self.hadQuest = false
            self.hasQuestItem = false
            self.thanksUntil = getTimeInMillis() + BarteringDialogUI.ThanksDurationMs
        end
        return
    end

    self.hadQuest = true
    self.questItemTicks = self.questItemTicks + 1
    if self.questItemTicks >= BarteringDialogUI.QuestItemCheckTicks then
        self.questItemTicks = 0
        self.hasQuestItem = Bartering.Quests.findQuestItem(self.player, quest) ~= nil
    end
end

function BarteringDialogUI:prerender()
    ISPanel.prerender(self)

    local stockRows
    if self.callMode and self.stockRequested then
        local any = false
        stockRows = {}
        if self.callStock then
            local player = self.player
            local requirementByItem = Bartering.getItemRequirementMap(self.bartererId)
            for itemName, qty in pairs(self.callStock) do
                any = true
                local item = InventoryItemFactory.CreateItem(itemName)
                local label = item and item:getDisplayName() or itemName
                if qty > 1 then
                    label = label .. " x" .. tostring(qty)
                end
                table.insert(stockRows, {
                    label = label,
                    texture = item and item:getTex(),
                    valueText = Bartering.formatTradeValue(
                        Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, player, self.bartererId)),
                    reqText = requirementByItem[itemName]
                        or ("Lvl " .. tostring(Bartering.Barterers[self.bartererId].requiredLevel) .. " Bartering"),
                })
            end
        end
        if not any then
            table.insert(stockRows, { label = "Nothing in stock right now.", valueText = "", reqText = "" })
        end
        local textTop = BarteringDialogUI.PortraitY
        if self:isMet() and Bartering.getSandboxBoolean("EnableRelationships", true) then
            textTop = textTop + Bartering.Relations.STAR_SIZE + 10
        end
        local contentH = math.max(
            BarteringDialogUI.PortraitY + BarteringDialogUI.PortraitH - textTop,
            6 + 16 + 6 + (1 + #stockRows) * 18)
        local targetH = math.max(240, textTop + contentH + 46)
        if targetH ~= self.height then
            self:setHeight(targetH)
        end
    end

    self:refreshButtons()

    local met = self:isMet()
    local displayName = met and Bartering.getBartererDisplayName(self.bartererId) or "Stranger"

    self:drawRect(0, 0, self.width, BarteringDialogUI.HeaderHeight, 0.18, 0.16, 0.16, 0.16)
    self:drawText(displayName, 12, 6, 1, 1, 1, 1, UIFont.Large)

    self:drawRect(
        BarteringDialogUI.PortraitX, BarteringDialogUI.PortraitY,
        BarteringDialogUI.PortraitW, BarteringDialogUI.PortraitH, 1, 0.05, 0.05, 0.06)
    self:drawRectBorder(
        BarteringDialogUI.PortraitX - 1, BarteringDialogUI.PortraitY - 1,
        BarteringDialogUI.PortraitW + 2, BarteringDialogUI.PortraitH + 2, 1, 0.35, 0.35, 0.35)

    if self.callMode then
        local radioItem = InventoryItemFactory.CreateItem("Radio.WalkieTalkie1")
        local iconSize = 44
        self:drawTextureScaledAspect(
            radioItem:getTex(),
            BarteringDialogUI.PortraitX + (BarteringDialogUI.PortraitW - iconSize) / 2,
            BarteringDialogUI.PortraitY + 32,
            iconSize, iconSize, 1, 1, 1, 1)
        self:drawTextCentre("Radio Call",
            BarteringDialogUI.PortraitX + BarteringDialogUI.PortraitW / 2,
            BarteringDialogUI.PortraitY + 92, 0.7, 0.7, 0.7, 1, UIFont.Small)
    end

    local contentX = BarteringDialogUI.PortraitX + BarteringDialogUI.PortraitW + 14
    local contentW = self.width - contentX - 12
    local y = BarteringDialogUI.PortraitY

    if met and Bartering.getSandboxBoolean("EnableRelationships", true) then
        self:drawText("Relationship", contentX, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
        local labelW = getTextManager():MeasureStringX(UIFont.Small, "Relationship")
        local starSize = Bartering.Relations.STAR_SIZE
        local starGap = Bartering.Relations.STAR_GAP
        local starsX = contentX + labelW + 10
        for i = 1, Bartering.Relations.STARS do
            Bartering.Relations.drawStar(
                self,
                starsX + (i - 1) * (starSize + starGap) + starSize / 2,
                y + starSize / 2 - 1,
                Bartering.Relations.getStarFill(self.player, self.bartererId, i),
                starSize, 0.08, 0.08, 0.08)
        end
        y = y + starSize + 10
    end

    local textH = BarteringDialogUI.PortraitY + BarteringDialogUI.PortraitH - y
    local lines
    if not stockRows then
        lines = wrapText(self:getDialogueText(), contentW - 16)
    end
    if stockRows then
        textH = math.max(textH, 6 + 16 + 6 + (1 + #stockRows) * 18)
    else
        local redLineExtra = (self.callReplyRed and getTimeInMillis() < self.callReplyUntil) and 16 or 0
        textH = math.max(textH, #lines * 16 + 8 + redLineExtra)
    end
    self:drawRect(contentX, y, contentW, textH, 0.85, 0.10, 0.10, 0.10)
    self:drawRectBorder(contentX, y, contentW, textH, 1, 0.25, 0.25, 0.25)

    if stockRows then
        local valueX = contentX + contentW * 0.58
        local rowY = y + 6
        self:drawText("Here's what I've got.", contentX + 8, rowY, 0.88, 0.86, 0.78, 1, UIFont.Small)
        rowY = rowY + 22
        self:drawText("Item", contentX + 20, rowY, 0.7, 0.7, 0.7, 1, UIFont.Small)
        self:drawTextCentre("Value", valueX, rowY, 0.7, 0.7, 0.7, 1, UIFont.Small)
        self:drawTextRight("Level Requirement", contentX + contentW - 4, rowY, 0.7, 0.7, 0.7, 1, UIFont.Small)
        rowY = rowY + 18
        for _, row in ipairs(stockRows) do
            self:drawRect(contentX, rowY, contentW, 18, 0.9, 0.10, 0.10, 0.10)
            self:drawRectBorder(contentX, rowY, contentW, 18, 1, 0.25, 0.25, 0.25)
            if row.texture then
                self:drawTextureScaledAspect(row.texture, contentX + 3, rowY + 2, 14, 14, 1, 1, 1, 1)
            end
            self:drawText(row.label, contentX + 20, rowY + 2, 0.88, 0.86, 0.78, 1, UIFont.Small)
            if row.valueText ~= "" then
                self:drawTextCentre(row.valueText, valueX, rowY + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
                self:drawTextRight(row.reqText, contentX + contentW - 4, rowY + 2, 0.7, 0.7, 0.7, 1, UIFont.Small)
            end
            rowY = rowY + 18
        end
    else
        local lineY = y + 8
        for _, line in ipairs(lines) do
            self:drawText(line, contentX + 8, lineY, 0.88, 0.86, 0.78, 1, UIFont.Small)
            lineY = lineY + 16
        end
        if self.callReplyRed and getTimeInMillis() < self.callReplyUntil then
            self:drawText(self.callReplyRed, contentX + 8, lineY, 1, 0.30, 0.30, 1, UIFont.Small)
        end
    end
end

BarteringUIUtils.makeDraggable(BarteringDialogUI, BarteringDialogUI.HeaderHeight)

function BarteringDialogUI:onClose()
    self:close()
end

function BarteringDialogUI:close()
    activeDialogs[self.bartererId] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

function BarteringDialogUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local width = 560
    local height = 240
    local x, y = BarteringUIUtils.centreOnScreen(width, height)
    local ui = ISPanel:new(x, y, width, height)
    setmetatable(ui, self)
    self.__index = self
    ui.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    ui.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    ui.player = player
    ui.bartererId = bartererId
    ui.anchorX = anchorX
    ui.anchorY = anchorY
    ui.anchorZ = anchorZ
    ui.bartererZombie = bartererZombie
    ui.callMode = callMode == true
    ui.callStock = nil
    ui.stockRequested = false
    ui.callReply = nil
    ui.callReplyUntil = 0
    ui.buttonW = ui.callMode and BarteringDialogUI.CallButtonW or BarteringDialogUI.ButtonW
    ui.dragging = false
    ui.justIntroduced = false
    ui.hasQuestItem = false
    ui.questItemTicks = BarteringDialogUI.QuestItemCheckTicks
    ui.thanksUntil = 0
    local existing = Bartering.Quests.getActive(player, bartererId)
    ui.openedWithQuestId = existing and existing.id or nil
    ui.hadQuest = existing ~= nil
    return ui
end

function BarteringDialogUI.notifyQuestUpdated(bartererId)
    local dialog = activeDialogs[bartererId]
    if dialog then
        dialog.questItemTicks = BarteringDialogUI.QuestItemCheckTicks
    end
end

function BarteringDialogUI.notifyCallReply(bartererId, message)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        dialog.callReply = message
        dialog.callReplyUntil = getTimeInMillis() + BarteringDialogUI.ReplyDurationMs
        dialog.callReplyRed = nil
        dialog.stockRequested = false
    end
end

function BarteringDialogUI.notifyMeetupCanceled(bartererId, message, relationsDelta)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        dialog.callReply = message
        dialog.callReplyUntil = getTimeInMillis() + BarteringDialogUI.ReplyDurationMs
        dialog.callReplyRed = (relationsDelta and relationsDelta < 0) and ("(" .. tostring(relationsDelta) .. " Relations)") or nil
        dialog.stockRequested = false
    end
end

function BarteringDialogUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local existing = activeDialogs[bartererId]
    if existing then
        existing:close()
    end
    local ui = BarteringDialogUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    ui:initialise()
    ui:addToUIManager()
    activeDialogs[bartererId] = ui
    return ui
end

return BarteringDialogUI
