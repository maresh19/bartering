require "ISUI/ISPanel"
require "Bartering"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local ISPanel = _G["ISPanel"]
local UIFont = _G["UIFont"]
local sendClientCommand = _G["sendClientCommand"]

BarteringAmendsUI = ISPanel:derive("BarteringAmendsUI")

BarteringAmendsUI.ListY = 46
BarteringAmendsUI.ListHeight = 196
BarteringAmendsUI.ListX = 12
BarteringAmendsUI.ListWidth = 516

BarteringUIUtils.addOpenRegistry(BarteringAmendsUI)
BarteringUIUtils.addOfferWindow(BarteringAmendsUI)

function BarteringAmendsUI:updateSelectionValues()
    self.selectedOffers, self.offeredValue = BarteringUIUtils.collectSelectedOffers(self.offerList)
end

function BarteringAmendsUI:initialise()
    ISPanel.initialise(self)
    self.closeButton = BarteringUIUtils.addCloseButton(self, BarteringAmendsUI.onClose)
    self.offerButton = BarteringUIUtils.addButton(self, self.width - 102, self.height - 36, 90, 25, "Make Offer", BarteringAmendsUI.onOffer)
    self.offerList = BarteringUIUtils.addQtyList(self, BarteringAmendsUI.ListX, BarteringAmendsUI.ListY,
        BarteringAmendsUI.ListWidth, BarteringAmendsUI.ListHeight, BarteringAmendsUI.onOfferQtyChanged)
    self:populateItems()
end

function BarteringAmendsUI:onOffer()
    if self.offeredValue < Bartering.Hostility.getAmendsCost(self.bartererId, self.player) then
        return
    end
    sendClientCommand(self.player, "Bartering", "amendsOffer", {
        bartererId = self.bartererId,
        offeredItems = self.selectedOffers,
    })
    self:close()
end

function BarteringAmendsUI:close()
    BarteringUIUtils.closeWindow(self)
end

function BarteringAmendsUI:prerender()
    ISPanel.prerender(self)
    BarteringUIUtils.drawHeader(self, "Make Amends with " .. Bartering.getBartererDisplayName(self.bartererId))
    self:drawText("Your inventory", BarteringAmendsUI.ListX, 32, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:drawText("Required: " .. Bartering.formatTradeValue(Bartering.Hostility.getAmendsCost(self.bartererId, self.player))
        .. " trade value", 12, self.height - 64, 0.95, 0.55, 0.35, 1, UIFont.Small)
    self:drawText("Offering: " .. tostring(#self.selectedOffers) .. " item(s) ["
        .. Bartering.formatTradeValue(self.offeredValue) .. "]", BarteringAmendsUI.ListX + 230, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function BarteringAmendsUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local ui = BarteringUIUtils.newBartererWindow(self, 540, 350, player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    ui.callMode = callMode == true
    ui.selectedOffers = {}
    ui.offeredValue = 0
    ui.offerSignature = nil
    return ui
end

function BarteringAmendsUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local ui = BarteringAmendsUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    ui:initialise()
    ui:addToUIManager()
    ui:registerOpen()
end

return BarteringAmendsUI
