require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISUI3DModel"
require "Bartering"
require "BarteringQuests"
require "BarteringTiming"
require "BarteringHire"
local print = require("BarteringPathTrace").log

local BarteringUIUtils = require "UI/BarteringUIUtils"
local BarteringIntercept = require "Movement/BarteringIntercept"
local BarteringDialogue = require "BarteringDialogue"
local BarteringAIUtils = require "BarteringAIUtils"
local ISPanel = _G["ISPanel"]
local ISButton = _G["ISButton"]
local ISUI3DModel = _G["ISUI3DModel"]
local IsoDirections = _G["IsoDirections"]
local UIFont = _G["UIFont"]
local getTextManager = _G["getTextManager"]
local sendClientCommand = _G["sendClientCommand"]
local instanceItem = _G["instanceItem"]
local radioTexture
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
BarteringDialogUI.InterceptHeartbeatMs = 1500
BarteringDialogUI.InterceptMeetupCutoffSq = 10 * 10

local activeDialogs = {}

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

function BarteringDialogUI:isKnown()
    if self.callMode then
        return Bartering.isBartererKnown(self.player, self.bartererId)
    end
    return Bartering.hasMetBarterer(self.player, self.bartererId)
end

function BarteringDialogUI:getTradeBlockReason()
    local refusal = self:getInterceptRefusal()
    if refusal then
        return refusal
    end

    local bartererState = self.bartererZombie:getVariableString("BartererState") or ""
    if bartererState == "DefendKnife" or bartererState == "DefendPistol" then
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
    if self.askedNothingNeeded
            and Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId) > 0 then
        return "He has nothing for you right now"
    end
    return nil
end

function BarteringDialogUI:isIntercepted()
    return not self.callMode
        and BarteringIntercept.isInterceptedBy(self.bartererZombie, self.player)
end

function BarteringDialogUI:isBusyWorking()
    return self.hireRefusedReply
        or (BarteringHire.isHired(self.bartererId)
            and not BarteringHire.isHiredBy(self.player, self.bartererId))
end

function BarteringDialogUI:isNearMeetupPoint()
    if not self.bartererZombie then
        return false
    end
    return BarteringAIUtils.distanceSqBetween(self.player, self.bartererZombie) <= BarteringDialogUI.InterceptMeetupCutoffSq
end

function BarteringDialogUI:getInterceptRefusal()
    if not self:isIntercepted() then
        return nil
    end
    return BarteringIntercept.getRefusal(self.player, self.bartererZombie)
end

function BarteringDialogUI:isAskingStayHere()
    return self:isIntercepted()
        and not self.interceptAnswered
        and self:getInterceptRefusal() == nil
end

function BarteringDialogUI:questLine(quest)
    if quest.id ~= self.openedWithQuestId and not self.hasQuestItem then
        return Bartering.Quests.getFlavorLine(quest, self.player)
    end
    return Bartering.Quests.getReminderLine(quest, self.hasQuestItem, self.player)
end

function BarteringDialogUI:getCallReplyText()
    if not self.showCallReply then
        return nil
    end
    if self.callReplyLive == "eta" then
        local remaining = Bartering.getBartererArrivalRemainingSeconds(self.bartererId)
        if not remaining then
            return nil
        end
        return string.format(BarteringDialogue.Call[self.callReplyTemplate],
            BarteringTiming.formatArrivalEstimateHumanized(remaining))
    end
    if self.callReplyLive == "respawn" then
        local remaining = BarteringTiming.remainingHours(Bartering.getBartererLifeState(self.bartererId).respawnAt)
        if remaining <= 0 then
            return nil
        end
        return string.format(BarteringDialogue.Call[self.callReplyTemplate],
            BarteringTiming.formatDurationHours(remaining))
    end
    return self.callReply
end

function BarteringDialogUI:getDialogueText()
    if self.confirmingSendHome then
        if BarteringHire.isHiredBy(self.player, self.bartererId) then
            local remaining = BarteringHire.getRemainingHours(self.bartererId)
            local hours = math.floor(remaining)
            return string.format(BarteringDialogue.Hire.sendHomeConfirm, hours, math.floor((remaining - hours) * 60))
        end
        return BarteringDialogue.SendHome.confirm
    end

    if self.nearbyBlocked then
        return BarteringDialogue.Call.nearbyBlocked
    end

    if self.sleepingRefusedReply then
        return BarteringDialogue.Call.sleepingNoAnswer
    end

    local amendsStage = self:getAmendsStage()
    if amendsStage == "closing" then
        return (self.showCallReply and self.callReply)
            or self:amendsLine(BarteringDialogue.Hostility.amendsResponse)
    elseif amendsStage == "offer" then
        return self:amendsLine(self:isAmendsCalled()
            and BarteringDialogue.Hostility.readyToForgive
            or BarteringDialogue.Hostility.amendsResponse)
    elseif amendsStage == "callOver" then
        return self:amendsLine(BarteringDialogue.Hostility.amendsResponse)
    elseif amendsStage == "prompt" then
        return BarteringDialogue.Hostility.greeting
    end

    if self:isBusyWorking() then
        return BarteringDialogue.Hire.workingRefusal
    end

    if self:isAskingStayHere() then
        return BarteringDialogue.Intercept.askStayHere
    end

    local refusal = self:getInterceptRefusal()
    if refusal then
        return refusal
    end

    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    local cooldown = Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId)

    if self.callMode then
        local radio = BarteringDialogue.Radio
        if self.noAnswer then
            return BarteringDialogue.Call.noAnswer
        end
        local reply = self:getCallReplyText()
        if reply then
            return reply
        end
        if self.showNothingNeeded and cooldown > 0 then
            return string.format(radio.nothingNeeded, BarteringTiming.formatGameHours(cooldown))
        end
        if self.saleCall and not self.saleLineDone then
            return string.format(BarteringDialogue.SaleCall.message, Bartering.getBartererDisplayName(self.bartererId))
        end
        local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(self.bartererId)
        if arrivalRemaining then
            if Bartering.isBartererWaitingAtMeetup(self.bartererId) then
                return string.format(radio.waitingAtMeetup, BarteringTiming.formatArrivalEstimateHumanized(arrivalRemaining))
            end
            local line = (self:isHostile() and self:isAmendsPending()) and radio.amendsOnTheWay or radio.onTheWay
            return string.format(line, BarteringTiming.formatArrivalEstimateHumanized(arrivalRemaining))
        end
        local statusLine = self:getRadioStatusLine()
        if statusLine and not self.stockRequested and not quest then
            return statusLine
        end
        if self:isBartererApproaching() then
            return radio.arriving
        end
        if self.stockRequested then
            return radio.stockList
        end
        if quest then
            return self:questLine(quest)
        end
        return radio.prompt
    end

    local face = BarteringDialogue.FaceToFace
    if not self:isKnown() then
        return face.unknown
    end
    if self.showThanks then
        return face.thanks
    end
    if self.showNothingNeeded and cooldown > 0 then
        return string.format(face.nothingNeeded, BarteringTiming.formatGameHours(cooldown))
    end
    if quest then
        return self:questLine(quest)
    end
    if self.justIntroduced then
        return string.format(face.introduced, Bartering.getBartererDisplayName(self.bartererId))
    end
    if BarteringHire.isHiredBy(self.player, self.bartererId) then
        return face.hired
    end
    return face.greeting
end

function BarteringDialogUI:onIntroduce()
    Bartering.meetBarterer(self.player, self.bartererId)
    sendClientCommand(self.player, "Bartering", "meetBarterer", { bartererId = self.bartererId })
    self.justIntroduced = true
end

function BarteringDialogUI:onStayHere()
    self.interceptAnswered = true
    sendClientCommand(self.player, "Bartering", "stayHere", { bartererId = self.bartererId })
end

function BarteringDialogUI:onContinueToMeetup()
    self.interceptAnswered = true
    sendClientCommand(self.player, "Bartering", "continueToMeetup", { bartererId = self.bartererId })
    self:close()
end

function BarteringDialogUI:handOffTo(windowClass)
    self:close()
    windowClass.open(self.player, self.bartererId, self.anchorX, self.anchorY, self.anchorZ, self.bartererZombie, self.callMode)
end

function BarteringDialogUI:onTrade()
    self:handOffTo(BarteringBarterUI)
end

function BarteringDialogUI:onHire()
    self:handOffTo(BarteringHireUI)
end

function BarteringDialogUI:canSendHome()
    if self.callMode then
        return self:isBartererApproaching()
            or Bartering.isBartererArrivedAtCall(self.bartererId)
            or Bartering.isBartererWaitingAtMeetup(self.bartererId)
    end
    return self.bartererZombie:getVariableBoolean("BartererCalledIn")
        or BarteringHire.isHiredBy(self.player, self.bartererId)
end

function BarteringDialogUI:onSendHome()
    self.confirmingSendHome = true
end

function BarteringDialogUI:onConfirmSendHome()
    sendClientCommand(self.player, "Bartering", "sendBartererHome", { bartererId = self.bartererId })
    self:close()
end

function BarteringDialogUI:onCancelSendHome()
    self.confirmingSendHome = false
end

function BarteringDialogUI:onMakeAmends()
    self.amendsStage = "opened"
    sendClientCommand(self.player, "Bartering", "openAmends", { bartererId = self.bartererId })
end

function BarteringDialogUI:onCallOverToMakeAmends()
    self.amendsStage = "called"
    sendClientCommand(self.player, "Bartering", "callOverToMakeAmends", { bartererId = self.bartererId })
end

function BarteringDialogUI:onMakeOffer()
    self:handOffTo(BarteringAmendsUI)
end

function BarteringDialogUI:onRequestQuest()
    self.stockRequested = false
    if Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId) > 0 then
        self.showNothingNeeded = true
        self.askedNothingNeeded = true
        return
    end
    sendClientCommand(self.player, "Bartering", "requestQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:onTurnInQuest()
    self.turningIn = true
    sendClientCommand(self.player, "Bartering", "turnInQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:onRefreshQuest()
    sendClientCommand(self.player, "Bartering", "debugRefreshQuest", { bartererId = self.bartererId })
end

function BarteringDialogUI:buildStockRows()
    local player = self.player
    local rows = {}
    local requirementByItem, orderByItem = Bartering.getItemRequirementMap(self.bartererId)
    for itemName, qty in pairs(self.callStock) do
        local item = instanceItem(itemName)
        local label = item and item:getDisplayName() or itemName
        if qty > 1 then
            label = label .. " x" .. tostring(qty)
        end
        table.insert(rows, {
            order = orderByItem[itemName] or math.huge,
            label = label,
            texture = item and item:getTex(),
            valueText = Bartering.formatTradeValue(
                Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, player, self.bartererId)),
            reqText = requirementByItem[itemName]
                or ("Lvl " .. tostring(Bartering.Barterers[self.bartererId].requiredLevel) .. " Bartering"),
        })
    end
    table.sort(rows, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.label < b.label
    end)
    if #rows == 0 then
        table.insert(rows, { label = "Nothing in stock right now.", valueText = "", reqText = "" })
    end
    return rows
end

function BarteringDialogUI:rebuildStock()
    self.stockDirty = false
    self.callStock = Bartering.getBartererStockMap(self.bartererId)
    self.stockRows = self:buildStockRows()
    Bartering.queuePlayerUIStockRefresh(self.bartererId)
end

function BarteringDialogUI:onUpdateStock()
    self.stockRequested = true
    self:rebuildStock()
    sendClientCommand(self.player, "Bartering", "requestStock", { bartererId = self.bartererId })
end

function BarteringDialogUI:onCallMeetup()
    local player = self.player
    local barterer = Bartering.Barterers[self.bartererId]
    if player and barterer
        and BarteringAIUtils.distanceSq(player:getX(), player:getY(), barterer.x, barterer.y) <= 900 then
        self.nearbyBlocked = true
        return
    end
    sendClientCommand(self.player, "Bartering", "callBarterer", { bartererId = self.bartererId })
end

function BarteringDialogUI:onCancelMeetup()
    if self:isHostile() then
        self.amendsStage = "canceled"
    else
        self.awaitingReply = true
    end
    sendClientCommand(self.player, "Bartering", "cancelBartererMeeting", { bartererId = self.bartererId })
end

function BarteringDialogUI:onUpdateLocation()
    self.awaitingReply = true
    sendClientCommand(self.player, "Bartering", "updateBartererLocation", { bartererId = self.bartererId })
end

function BarteringDialogUI:getRadioStatusLine()
    local radio = BarteringDialogue.Radio
    if self.radioStatus == "home" then
        return radio.headingHome
    end
    if self.radioStatus == "meetup" then
        return radio.otherMeetup
    end
    if self.radioStatus == "waiting" then
        local remaining = math.max(0, (self.radioStatusEndsAtMs - BarteringTiming.now()) / 1000)
        return string.format(radio.busyAtMeetup, BarteringTiming.formatArrivalEstimateHumanized(remaining))
    end
    return nil
end

function BarteringDialogUI:isBartererApproaching()
    local tracked = Bartering.TrackedBarterers and Bartering.TrackedBarterers[self.bartererId]
    return tracked ~= nil and tracked.state == "Approach"
end

function BarteringDialogUI:isHostile()
    return Bartering.Hostility.isHostileTo(self.bartererId, self.player)
end

function BarteringDialogUI:isAmendsPending()
    return self.amendsStage == "opened"
        or Bartering.Hostility.isAmendsPendingFor(self.bartererId, self.player)
end

function BarteringDialogUI:isAmendsCalled()
    return self.amendsStage == "called"
        or Bartering.Hostility.isAmendsCalledFor(self.bartererId, self.player)
end

function BarteringDialogUI:amendsLine(lead)
    return lead .. " " .. string.format(
        BarteringDialogue.Hostility.costNote,
        Bartering.formatTradeValue(Bartering.Hostility.getAmendsCost(self.bartererId, self.player)))
end

function BarteringDialogUI:getAmendsStage()
    local enRoute = self.callMode and Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil
    if self.amendsStage == "canceled" or (self.amendsStage == "called" and not enRoute) then
        return "closing"
    end
    if not self:isHostile() then
        return nil
    end
    if not self.callMode then
        return "offer"
    end
    if enRoute then
        return "eta"
    end
    if self:isAmendsPending() and not self:isAmendsCalled() then
        return "callOver"
    end
    return "prompt"
end

function BarteringDialogUI:getCallMeetupBlockReason()
    local blockReason = Bartering.getCallBlockReason(self.player, self.bartererId, BarteringTiming.formatDurationHours)
    if blockReason then
        return blockReason
    end
    local displayName = Bartering.getBartererDisplayName(self.bartererId)
    local arrivalRemaining = Bartering.getBartererArrivalRemainingSeconds(self.bartererId)
    if arrivalRemaining then
        return displayName .. " is already on his way. ETA " .. BarteringTiming.formatDuration(arrivalRemaining)
    end
    if self.radioStatus == "home" or self.radioStatus == "meetup" then
        return nil
    end
    if self:isBartererApproaching() then
        return displayName .. " is already heading to the meetup"
    end
    if not Bartering.isBartererCallOpenNow(self.bartererId) then
        local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(self.bartererId)
        return string.format("%s accepts calls between %02d:00 and %02d:00", displayName, callStartHour, callEndHour)
    end
    return nil
end

function BarteringDialogUI:createButton(label, callback, width)
    local button = ISButton:new(0, self.height - 36, width or self.buttonW, BarteringDialogUI.ButtonH, label, self, function(dialog, ...)
        if dialog.callMode then
            BarteringUIUtils.playButtonClickSound(dialog)
        end
        dialog.showThanks = false
        dialog.saleLineDone = true
        dialog.showNothingNeeded = false
        dialog.showCallReply = false
        dialog.awaitingReply = false
        dialog.viewDirty = true
        return callback(dialog, ...)
    end)
    button:initialise()
    button:instantiate()
    if self.callMode then
        button:setSound("activate", nil)
    end
    button.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    self:addChild(button)
    return button
end

function BarteringDialogUI:initialise()
    ISPanel.initialise(self)

    self.closeButton = BarteringUIUtils.addCloseButton(self, BarteringDialogUI.onClose)

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
    self.hireButton = self:createButton("Hire", BarteringDialogUI.onHire)
    self.questButton = self:createButton("Retrieve Quest", BarteringDialogUI.onRequestQuest)
    self.turnInButton = self:createButton("Turn in Quest", BarteringDialogUI.onTurnInQuest)
    self.refreshQuestButton = self:createButton("Refresh Quest", BarteringDialogUI.onRefreshQuest)
    self.updateStockButton = self:createButton("Update Stock", BarteringDialogUI.onUpdateStock)
    self.callMeetupButton = self:createButton("Call for a Meet Up", BarteringDialogUI.onCallMeetup)
    self.cancelMeetupButton = self:createButton("Cancel Meetup", BarteringDialogUI.onCancelMeetup)
    self.updateLocationButton = self:createButton("Update Location", BarteringDialogUI.onUpdateLocation)
    self.stayHereButton = self:createButton("Stay Here", BarteringDialogUI.onStayHere)
    self.continueButton = self:createButton("Continue", BarteringDialogUI.onContinueToMeetup)
    self.closeDialogButton = self:createButton("Close", BarteringDialogUI.onClose)
    self.makeAmendsButton = self:createButton("Make Amends", BarteringDialogUI.onMakeAmends)
    self.amendsCallOverButton = self:createButton("Call over to make amends", BarteringDialogUI.onCallOverToMakeAmends, 178)
    self.makeOfferButton = self:createButton("Make Offer", BarteringDialogUI.onMakeOffer)
    self.sendHomeButton = self:createButton("Send Home", BarteringDialogUI.onSendHome)
    self.confirmSendHomeButton = self:createButton("Yes", BarteringDialogUI.onConfirmSendHome)
    self.cancelSendHomeButton = self:createButton("No", BarteringDialogUI.onCancelSendHome)
    self.buttons = { self.introduceButton, self.tradeButton, self.hireButton, self.questButton, self.turnInButton,
        self.refreshQuestButton, self.updateStockButton, self.callMeetupButton, self.closeDialogButton,
        self.cancelMeetupButton, self.updateLocationButton, self.stayHereButton, self.continueButton,
        self.makeAmendsButton, self.amendsCallOverButton, self.makeOfferButton, self.sendHomeButton,
        self.confirmSendHomeButton, self.cancelSendHomeButton }

    if not self.callMode and self:isHostile() and not self:isAmendsPending() then
        self:onMakeAmends()
    end
end

function BarteringDialogUI:hideAllButtons()
    for _, button in ipairs(self.buttons) do
        button:setVisible(false)
    end
end

function BarteringDialogUI:layoutButtons()
    local x = BarteringDialogUI.PortraitX
    for _, button in ipairs(self.buttons) do
        if button:getIsVisible() then
            button:setY(self.height - 36)
            button:setX(x)
            x = x + button:getWidth() + BarteringDialogUI.ButtonGap
        end
    end
end

function BarteringDialogUI:refreshButtons()
    local known = self:isKnown()
    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    local confirming = self:isAskingStayHere()

    self.closeDialogButton:setVisible(false)

    if self.confirmingSendHome then
        self:hideAllButtons()
        self.confirmSendHomeButton:setVisible(true)
        self.cancelSendHomeButton:setVisible(true)
        self:layoutButtons()
        return
    end
    self.confirmSendHomeButton:setVisible(false)
    self.cancelSendHomeButton:setVisible(false)

    if self.nearbyBlocked or self.noAnswer or self:isBusyWorking() or self.sleepingRefusedReply then
        self:hideAllButtons()
        self.closeDialogButton:setVisible(true)
        self:layoutButtons()
        return
    end

    self.stayHereButton:setVisible(confirming)
    self.continueButton:setVisible(confirming)
    self.stayHereButton.tooltip = "He stops here instead of heading to the meetup spot."
    self.continueButton.tooltip = "He carries on to the meetup spot you called him to."

    self.makeAmendsButton:setVisible(false)
    self.amendsCallOverButton:setVisible(false)
    self.makeOfferButton:setVisible(false)

    local amendsStage = self:getAmendsStage()
    if amendsStage then
        self:hideAllButtons()
        if amendsStage == "closing" then
            self.closeDialogButton:setVisible(true)
        elseif amendsStage == "eta" then
            self.cancelMeetupButton:setVisible(true)
            self.closeDialogButton:setVisible(true)
        elseif amendsStage == "offer" then
            self.makeOfferButton:setVisible(true)
        elseif amendsStage == "callOver" then
            self.amendsCallOverButton:setVisible(true)
        else
            self.makeAmendsButton:setVisible(true)
        end
    elseif self.callMode then
        self.sendHomeButton:setVisible(self:canSendHome())
        self.introduceButton:setVisible(false)
        self.tradeButton:setVisible(false)
        self.hireButton:setVisible(false)
        self.turnInButton:setVisible(false)
        self.questButton:setVisible(quest == nil)
        self.updateStockButton:setVisible(true)
        self.refreshQuestButton:setVisible(quest ~= nil and Bartering.getSandboxBoolean("DebugMode", false))

        local displayName = Bartering.getBartererDisplayName(self.bartererId)

        self.updateStockButton.enable = true
        self.updateStockButton.tooltip = "Fetch the current stock list from " .. displayName

        local redirecting = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 2
            and (Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil or self:isBartererApproaching())
        local callActive = Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil
        self.updateLocationButton:setVisible(redirecting)
        self.callMeetupButton:setVisible(not callActive and not redirecting and self.radioStatus ~= "waiting"
            and (self.radioStatus == "meetup" or not self:isBartererApproaching()))
        self.cancelMeetupButton:setVisible(callActive)
        self.closeDialogButton:setVisible(callActive or self.saleCall)

        local callBlock = self:getCallMeetupBlockReason()
        self.callMeetupButton.enable = callBlock == nil
        self.callMeetupButton.tooltip = callBlock or ("Arrange a meeting with " .. displayName)

        self.updateLocationButton.enable = true
        self.updateLocationButton.tooltip = "Tells the barterer where you are now, (changes arrival point to this location)."

        local questBlock = self:getQuestBlockReason()
        self.questButton.enable = questBlock == nil
        self.questButton.tooltip = questBlock or "Ask if there is anything he needs help with"

        self.refreshQuestButton.enable = quest ~= nil
        self.refreshQuestButton.tooltip = "Debug only: re-roll this quest and its dialogue"
    else
        self.sendHomeButton:setVisible(self:canSendHome())
        self.introduceButton:setVisible(not known and not confirming)
        self.tradeButton:setVisible(known and not confirming)
        self.hireButton:setVisible(known and not confirming and BarteringHire.isAllowed())
        if BarteringHire.isHiredBy(self.player, self.bartererId) then
            self.hireButton:setTitle("Extend Hiring Time")
        else
            self.hireButton:setTitle("Hire")
        end
        self.questButton:setVisible(known and quest == nil and not confirming)
        self.turnInButton:setVisible(known and quest ~= nil and not confirming)
        self.refreshQuestButton:setVisible(known and quest ~= nil and not confirming
            and Bartering.getSandboxBoolean("DebugMode", false))
        self.tradeButton:setTitle("Trade")

        self.updateStockButton:setVisible(false)
        self.callMeetupButton:setVisible(false)
        self.cancelMeetupButton:setVisible(false)
        self.updateLocationButton:setVisible(false)

        local tradeBlock = self:getTradeBlockReason()
        self.tradeButton.enable = tradeBlock == nil
        self.tradeButton.tooltip = tradeBlock or "Open the trade window"

        local hireCan, hireBlock = BarteringHire.canHire(self.player, self.bartererId, self.bartererZombie)
        self.hireButton.enable = hireCan
        if hireCan then
            self.hireButton.tooltip = "Hire " .. Bartering.getBartererDisplayName(self.bartererId) .. " to follow you ("
                .. tostring(BarteringHire.getCostPerHour()) .. " trade value per in-game hour)"
        else
            self.hireButton.tooltip = hireBlock
        end

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

        if quest then
            local remaining = Bartering.Quests.getRemainingHours(quest)
            if remaining then
                self.turnInButton.tooltip = self.turnInButton.tooltip
                    .. " (" .. BarteringTiming.formatGameHours(remaining) .. " left)"
            end
        end

        self.refreshQuestButton.enable = quest ~= nil
        self.refreshQuestButton.tooltip = "Debug only: re-roll this quest and its dialogue"
    end

    self:layoutButtons()
end

function BarteringDialogUI:refreshView()
    self.viewDirty = false
    if self.awaitingReply then
        return
    end
    self.known = self:isKnown()
    self.dialogueText = self:getDialogueText()
    self:refreshButtons()
end

function BarteringDialogUI:refreshQuestItem()
    self.questItemDirty = false
    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    self.hasQuestItem = quest ~= nil and Bartering.Quests.findQuestItem(self.player, quest) ~= nil
end

function BarteringDialogUI:getViewSignature()
    local blockReason
    if self.callMode then
        blockReason = self:getCallMeetupBlockReason()
    else
        blockReason = self:getTradeBlockReason()
    end
    return table.concat({
        tostring(self:isKnown()),
        tostring(self.questId),
        tostring(self.hasQuestItem),
        tostring(Bartering.Quests.getCooldownRemainingHours(self.player, self.bartererId) > 0),
        tostring(self:getAmendsStage()),
        tostring(self:isBusyWorking()),
        tostring(BarteringHire.isHiredBy(self.player, self.bartererId)),
        tostring(self:isAskingStayHere()),
        tostring(blockReason),
        tostring(Bartering.getBartererArrivalRemainingSeconds(self.bartererId) ~= nil),
        tostring(self:isBartererApproaching()),
        self:getDialogueText(),
    }, "|")
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

        if BarteringAIUtils.distanceSqBetween(self.player, self.bartererZombie)
            > BarteringDialogUI.MaxDistanceFromOpenTile * BarteringDialogUI.MaxDistanceFromOpenTile then
            self:close()
            return
        end

        if self:isIntercepted() then
            local now = BarteringTiming.now()
            if BarteringTiming.hasElapsed(self.interceptHeartbeatAtMs, BarteringDialogUI.InterceptHeartbeatMs) then
                self.interceptHeartbeatAtMs = now
                sendClientCommand(self.player, "Bartering", "interceptDialogOpen",
                    { bartererId = self.bartererId })
            end
        end
    end

    local quest = Bartering.Quests.getActive(self.player, self.bartererId)
    local questId = quest and quest.id or nil
    if questId ~= self.questId then
        if self.questId and not questId and self.turningIn then
            self.showThanks = true
        end
        self.turningIn = false
        self.questId = questId
        self.questItemDirty = true
    end

    if self.questItemDirty then
        self:refreshQuestItem()
        self.viewDirty = true
    end

    if self.stockDirty and self.stockRequested then
        self:rebuildStock()
    end

    local signature = self:getViewSignature()
    if signature ~= self.viewSignature then
        self.viewSignature = signature
        self.viewDirty = true
    end
end

function BarteringDialogUI:prerender()
    ISPanel.prerender(self)

    if self.viewDirty then
        self:refreshView()
    end

    local known = self.known

    local stockRows
    if self.callMode and self.stockRequested then
        stockRows = self.stockRows
        local textTop = BarteringDialogUI.PortraitY
        if known and Bartering.getSandboxBoolean("EnableRelationships", true) then
            textTop = textTop + Bartering.Relations.STAR_SIZE + 10
        end
        local contentH = math.max(
            BarteringDialogUI.PortraitY + BarteringDialogUI.PortraitH - textTop,
            6 + 16 + 6 + (1 + #stockRows) * 18)
        local targetH = math.max(240, textTop + contentH + 46)
        if targetH ~= self.height then
            self:setHeight(targetH)
            self:refreshButtons()
        end
    end
    local displayName = known and Bartering.getBartererDisplayName(self.bartererId) or "Stranger"

    self:drawRect(0, 0, self.width, BarteringDialogUI.HeaderHeight, 0.18, 0.16, 0.16, 0.16)
    self:drawText(displayName, 12, 6, 1, 1, 1, 1, UIFont.Large)

    self:drawRect(
        BarteringDialogUI.PortraitX, BarteringDialogUI.PortraitY,
        BarteringDialogUI.PortraitW, BarteringDialogUI.PortraitH, 1, 0.05, 0.05, 0.06)
    self:drawRectBorder(
        BarteringDialogUI.PortraitX - 1, BarteringDialogUI.PortraitY - 1,
        BarteringDialogUI.PortraitW + 2, BarteringDialogUI.PortraitH + 2, 1, 0.35, 0.35, 0.35)

    if self.callMode then
        radioTexture = radioTexture or instanceItem("Base.WalkieTalkie1"):getTex()
        local iconSize = 44
        self:drawTextureScaledAspect(
            radioTexture,
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

    if known and Bartering.getSandboxBoolean("EnableRelationships", true) then
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
        if self.wrappedText ~= self.dialogueText or self.wrappedWidth ~= contentW then
            self.wrappedText = self.dialogueText
            self.wrappedWidth = contentW
            self.dialogueLines = wrapText(self.dialogueText, contentW - 16)
        end
        lines = self.dialogueLines
    end
    if stockRows then
        textH = math.max(textH, 6 + 16 + 6 + (1 + #stockRows) * 18)
    else
        local redLineExtra = (self.callReplyRed and self.showCallReply) and 16 or 0
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
        local mouseX, mouseY = self:getMouseX(), self:getMouseY()
        local tipText = nil
        for _, row in ipairs(stockRows) do
            self:drawRect(contentX, rowY, contentW, 18, 0.9, 0.10, 0.10, 0.10)
            self:drawRectBorder(contentX, rowY, contentW, 18, 1, 0.25, 0.25, 0.25)
            if row.texture then
                self:drawTextureScaledAspect(row.texture, contentX + 3, rowY + 2, 14, 14, 1, 1, 1, 1)
            end
            local labelMaxW = contentW - 24
            if row.valueText ~= "" then
                labelMaxW = valueX - getTextManager():MeasureStringX(UIFont.Small, row.valueText) / 2 - 8 - (contentX + 20)
            end
            local displayLabel = BarteringUIUtils.ellipsize(row.label, labelMaxW)
            self:drawText(displayLabel, contentX + 20, rowY + 2, 0.88, 0.86, 0.78, 1, UIFont.Small)
            if row.valueText ~= "" then
                self:drawTextCentre(row.valueText, valueX, rowY + 2, 0.85, 0.85, 0.85, 1, UIFont.Small)
                self:drawTextRight(row.reqText, contentX + contentW - 4, rowY + 2, 0.7, 0.7, 0.7, 1, UIFont.Small)
            end
            if displayLabel ~= row.label and mouseX >= contentX and mouseX <= contentX + contentW
                and mouseY >= rowY and mouseY < rowY + 18 then
                tipText = row.label
            end
            rowY = rowY + 18
        end
        BarteringUIUtils.showHoverTooltip(self, "stockTooltip", tipText)
    else
        BarteringUIUtils.showHoverTooltip(self, "stockTooltip", nil)
        local lineY = y + 8
        for _, line in ipairs(lines) do
            self:drawText(line, contentX + 8, lineY, 0.88, 0.86, 0.78, 1, UIFont.Small)
            lineY = lineY + 16
        end
        if self.callReplyRed and self.showCallReply then
            self:drawText(self.callReplyRed, contentX + 8, lineY, 1, 0.30, 0.30, 1, UIFont.Small)
        end
    end
end

BarteringUIUtils.makeDraggable(BarteringDialogUI, BarteringDialogUI.HeaderHeight)

function BarteringDialogUI:onClose()
    self:close()
end

function BarteringDialogUI:close()
    BarteringUIUtils.showHoverTooltip(self, "stockTooltip", nil)
    activeDialogs[self.bartererId] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

function BarteringDialogUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode, sale)
    local ui = BarteringUIUtils.newBartererWindow(self, 560, 240, player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    ui.callMode = callMode == true
    ui.saleCall = sale == true
    ui.callStock = nil
    ui.stockRequested = false
    ui.callReply = nil
    ui.showCallReply = false
    ui.awaitingReply = false
    ui.noAnswer = false
    ui.hireRefusedReply = false
    ui.sleepingRefusedReply = false
    ui.buttonW = ui.callMode and BarteringDialogUI.CallButtonW or BarteringDialogUI.ButtonW
    ui.dragging = false
    ui.justIntroduced = false
    ui.hasQuestItem = false
    ui.questItemDirty = true
    ui.viewSignature = nil
    ui.showThanks = false
    ui.turningIn = false
    ui.saleLineDone = false
    ui.showNothingNeeded = false
    ui.askedNothingNeeded = false
    ui.amendsStage = nil
    ui.nearbyBlocked = false
    ui.confirmingSendHome = false
    ui.viewDirty = true
    local existing = Bartering.Quests.getActive(player, bartererId)
    ui.openedWithQuestId = existing and existing.id or nil
    ui.questId = existing and existing.id or nil
    return ui
end

function BarteringDialogUI.notifyQuestUpdated(bartererId)
    local dialog = activeDialogs[bartererId]
    if dialog then
        dialog.questItemDirty = true
        dialog.viewDirty = true
    end
end

function BarteringDialogUI.notifyStockChanged(bartererId)
    local dialog = activeDialogs[bartererId]
    if dialog then
        dialog.stockDirty = true
    end
end

function BarteringDialogUI.notifyInventoryChanged(character)
    for _, dialog in pairs(activeDialogs) do
        if dialog.player == character then
            dialog.questItemDirty = true
            dialog.viewDirty = true
        end
    end
end

local function showCallReply(dialog, message, template, live, red)
    dialog.awaitingReply = false
    dialog.callReply = message
    dialog.callReplyTemplate = template
    dialog.callReplyLive = live
    dialog.showCallReply = true
    dialog.callReplyRed = red
    dialog.stockRequested = false
    dialog.viewDirty = true
end

function BarteringDialogUI.notifyCallReply(bartererId, message, template, live)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        if template == "working" then
            dialog.hireRefusedReply = true
        elseif template == "sleeping" then
            dialog.sleepingRefusedReply = true
        end
        dialog.radioStatus = nil
        showCallReply(dialog, message, template, live, nil)
    end
end

function BarteringDialogUI.notifyRadioStatus(bartererId, status, seconds)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        dialog.radioStatus = status
        dialog.radioStatusEndsAtMs = seconds and (BarteringTiming.now() + seconds * 1000)
        dialog.viewDirty = true
    end
end

function BarteringDialogUI.notifyCallNoAnswer(bartererId, message)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        dialog.noAnswer = true
        showCallReply(dialog, message, nil, nil, nil)
    end
end

function BarteringDialogUI.notifyMeetupCanceled(bartererId, message, relationsDelta)
    local dialog = activeDialogs[bartererId]
    if dialog and dialog.callMode then
        showCallReply(dialog, message, nil, nil,
            (relationsDelta and relationsDelta < 0) and ("(" .. tostring(relationsDelta) .. " Relations)") or nil)
    end
end

function BarteringDialogUI.closeAll()
    for _, dialog in pairs(activeDialogs) do
        dialog:close()
    end
end

function BarteringDialogUI.closeAllExceptHostileCancel(bartererId)
    for id, dialog in pairs(activeDialogs) do
        if id ~= bartererId
            or (dialog.amendsStage ~= "canceled" and dialog.amendsStage ~= "called") then
            dialog:close()
        end
    end
end

function BarteringDialogUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode, sale)
    print(string.format("[Bartering][Hostility] dialog open %s | callMode=%s hostile=%s amendsPending=%s amendsCalled=%s",
        tostring(bartererId), tostring(callMode == true),
        tostring(Bartering.Hostility.isHostileTo(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsPendingFor(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsCalledFor(bartererId, player))))
    BarteringDialogUI.closeAll()
    local ui = BarteringDialogUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode, sale)
    ui:initialise()
    ui:addToUIManager()
    activeDialogs[bartererId] = ui
    if ui.callMode then
        sendClientCommand(player, "Bartering", "radioStatus", { bartererId = bartererId })
    end
    return ui
end

return BarteringDialogUI
