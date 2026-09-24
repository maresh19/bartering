require "ISUI/ISPanel"
require "Bartering"
require "BarteringHire"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local ISPanel = _G["ISPanel"]
local UIFont = _G["UIFont"]
local sendClientCommand = _G["sendClientCommand"]

BarteringHireUI = ISPanel:derive("BarteringHireUI")

BarteringHireUI.ListY = 46
BarteringHireUI.ListHeight = 196
BarteringHireUI.ListX = 12
BarteringHireUI.ListWidth = 516

BarteringUIUtils.addOpenRegistry(BarteringHireUI)
BarteringUIUtils.addOfferWindow(BarteringHireUI)

function BarteringHireUI:updateSelectionValues()
    self.selectedOffers, self.offeredValue = BarteringUIUtils.collectSelectedOffers(self.offerList)
    self.hours = BarteringHire.computeHoursFromValue(self.offeredValue)
    self.hireValue = BarteringHire.computeValueFromHours(self.hours)
end

function BarteringHireUI:initialise()
    ISPanel.initialise(self)
    self.closeButton = BarteringUIUtils.addCloseButton(self, BarteringHireUI.onClose)
    self.hireButton = BarteringUIUtils.addButton(self, self.width - 102, self.height - 36, 90, 25, "Hire", BarteringHireUI.onHire)
    self.offerList = BarteringUIUtils.addQtyList(self, BarteringHireUI.ListX, BarteringHireUI.ListY,
        BarteringHireUI.ListWidth, BarteringHireUI.ListHeight, BarteringHireUI.onOfferQtyChanged)
    self:populateItems()
end

function BarteringHireUI:onHire()
    if #self.selectedOffers == 0 or self.hours <= 0 then
        return
    end

    self.confirmUI = BarteringHireConfirmUI.open(self)
end

function BarteringHireUI:sendHire()
    Bartering.queuePlayerUIStockRefresh(self.bartererId, true)
    sendClientCommand(self.player, "Bartering", "hireBarterer", {
        bartererId = self.bartererId,
        offeredItems = self.selectedOffers,
        hours = self.hours,
    })
    self:close()
end

function BarteringHireUI:close()
    BarteringUIUtils.closeWindow(self)
    sendClientCommand(self.player, "Bartering", "hireWindowClosed", { bartererId = self.bartererId })
end

function BarteringHireUI:prerender()
    ISPanel.prerender(self)
    BarteringUIUtils.drawHeader(self, "Hire " .. Bartering.getBartererDisplayName(self.bartererId))
    self:drawText("Your inventory", BarteringHireUI.ListX, 32, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self.hireButton.enable = #self.selectedOffers > 0 and self.hours > 0
    self:drawText("Offering: " .. tostring(#self.selectedOffers) .. " item(s) [" .. Bartering.formatTradeValue(self.offeredValue) .. "]", 12, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("Hire Duration: " .. BarteringHire.formatHours(self.hours) .. " [" .. Bartering.formatTradeValue(self.hireValue) .. "]", 240, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function BarteringHireUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local ui = BarteringUIUtils.newBartererWindow(self, 540, 350, player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    ui.callMode = callMode == true
    ui.selectedOffers = {}
    ui.offeredValue = 0
    ui.hours = 0
    ui.hireValue = 0
    ui.offerSignature = nil
    return ui
end

function BarteringHireUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local ui = BarteringHireUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    ui:initialise()
    ui:addToUIManager()
    ui:registerOpen()
    sendClientCommand(player, "Bartering", "hireWindowOpen", { bartererId = bartererId })
end

BarteringHireConfirmUI = ISPanel:derive("BarteringHireConfirmUI")
BarteringUIUtils.makeConfirmWindow(BarteringHireConfirmUI, "sendHire")

function BarteringHireConfirmUI:populateLists()
    for _, offer in ipairs(self.parentUI.selectedOffers) do
        self.giveList:addItem(offer.displayName .. " [" .. Bartering.formatTradeValue(offer.value) .. "]", offer)
    end
    self.receiveList:addItem("Follow you for " .. BarteringHire.formatHours(self.hours), self)
end

function BarteringHireConfirmUI:prerender()
    ISPanel.prerender(self)
    BarteringUIUtils.drawConfirmSummary(self, "Confirm Hire")
    self:drawText("Hire Duration: " .. BarteringHire.formatHours(self.hours) .. " [" .. Bartering.formatTradeValue(self.hireValue) .. "]", 213, 238, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("No XP or relationship gain from hiring.", 12, 252, 0.55, 0.55, 0.55, 1, UIFont.Small)
end

function BarteringHireConfirmUI:new(parentUI)
    local ui = BarteringUIUtils.newConfirmWindow(self, parentUI)
    ui.hours = parentUI.hours
    ui.hireValue = parentUI.hireValue
    return ui
end

return BarteringHireUI
