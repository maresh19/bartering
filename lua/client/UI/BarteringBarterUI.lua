require "ISUI/ISPanel"
require "Bartering"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local BarteringTiming = require "BarteringTiming"
local ISPanel = _G["ISPanel"]
local UIFont = _G["UIFont"]
local instanceItem = _G["instanceItem"]
local sendClientCommand = _G["sendClientCommand"]

BarteringBarterUI = ISPanel:derive("BarteringBarterUI")

BarteringBarterUI.ListY = 70
BarteringBarterUI.ListHeight = 192
BarteringBarterUI.OfferListX = 12
BarteringBarterUI.OfferListWidth = 250
BarteringBarterUI.StockListX = 273
BarteringBarterUI.StockListWidth = 255

local openBarterUIs = BarteringUIUtils.addOpenRegistry(BarteringBarterUI)
BarteringUIUtils.addOfferWindow(BarteringBarterUI)

function BarteringBarterUI.refreshOpen(bartererId)
    local ui = openBarterUIs[bartererId]
    if ui then
        ui:refreshStock()
    end
end

function BarteringBarterUI:rebuildStockList()
    self.stockList:clear()
    self.selectedStock = {}
    self.selectedStockDetails = {}
    self.receivedValue = 0

    for itemName, stockQty in pairs(self.stockMap) do
        if Bartering.isBarterableItem(itemName) then
            local item = instanceItem(itemName)
            self.stockList:addItem(item:getDisplayName(), {
                item = item,
                itemName = itemName,
                perUnitValue = Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, self.player, self.bartererId),
                maxQty = stockQty,
                qty = 0,
                selected = false,
            })
        end
    end

    self:updateSelectionValues()
end

function BarteringBarterUI:refreshStock()
    if self.confirmUI then
        self.confirmUI:close()
    end
    self.stockMap = Bartering.getBartererStockMap(self.bartererId, self.player)
    self.stockInterval = Bartering.getStockRefreshInterval()
    self:rebuildStockList()
end

function BarteringBarterUI:updateSelectionValues()
    self.selectedOffers, self.offeredValue, self.relationValue = BarteringUIUtils.collectSelectedOffers(self.offerList)
    self.receivedValue = 0
    self.selectedStock = {}
    self.selectedStockDetails = {}

    for _, row in ipairs(self.stockList.items) do
        local entry = row.item
        local qty = entry.qty or 0
        if qty > 0 then
            local totalValue = entry.perUnitValue * qty
            self.receivedValue = self.receivedValue + totalValue
            table.insert(self.selectedStock, { itemName = entry.itemName, qty = qty })
            local displayName = entry.item:getDisplayName()
            if qty > 1 then
                displayName = displayName .. " x" .. tostring(qty)
            end
            table.insert(self.selectedStockDetails, {
                itemName = entry.itemName,
                displayName = displayName,
                value = totalValue,
                qty = qty,
            })
        end
    end
end

function BarteringBarterUI:initialise()
    ISPanel.initialise(self)
    self.closeButton = BarteringUIUtils.addCloseButton(self, BarteringBarterUI.onClose)
    self.tradeButton = BarteringUIUtils.addButton(self, self.width - 102, self.height - 36, 90, 25, "Trade", BarteringBarterUI.onTrade)
    self.offerList = BarteringUIUtils.addQtyList(self, BarteringBarterUI.OfferListX, BarteringBarterUI.ListY,
        BarteringBarterUI.OfferListWidth, BarteringBarterUI.ListHeight, BarteringBarterUI.onOfferQtyChanged, true)
    self.stockList = BarteringUIUtils.addQtyList(self, BarteringBarterUI.StockListX, BarteringBarterUI.ListY,
        BarteringBarterUI.StockListWidth, BarteringBarterUI.ListHeight, BarteringBarterUI.onStockQtyChanged, true)
    self.refreshButton = BarteringUIUtils.addButton(self, 12, self.height - 36, 90, 25, "Refresh Stock", BarteringBarterUI.onRefreshStock)
    self:populateItems()
end

function BarteringBarterUI:onStockQtyChanged(entry)
    self:updateSelectionValues()
end

function BarteringBarterUI:onRefreshStock()
    local barterer = Bartering.Barterers[self.bartererId]
    self.stockMap = Bartering.generateBartererStock(Bartering.Stock.getEffectiveCapacity(), Bartering.getVisibleSlotCount(barterer, self.player))
    self.stockInterval = Bartering.getStockRefreshInterval()
    self:rebuildStockList()
end

function BarteringBarterUI:onTrade()
    if #self.selectedOffers == 0 or #self.selectedStock == 0 or self.offeredValue < self.receivedValue then
        return
    end

    self.confirmUI = BarteringTradeConfirmUI.open(self)
end

function BarteringBarterUI:sendTrade()
    Bartering.queuePlayerUIStockRefresh(self.bartererId, true)
    sendClientCommand(self.player, "Bartering", "trade", {
        bartererId = self.bartererId,
        offeredItems = self.selectedOffers,
        receivedItems = self.selectedStock,
    })
    self:close()
end

function BarteringBarterUI:close()
    BarteringUIUtils.closeWindow(self)
end

local function drawListHeaders(self, list, headerY)
    local listX = list:getX()
    local qtyColX = listX + BarteringUIUtils.getListContentWidth(list) - BarteringUIUtils.COL_QTY_WIDTH
    local priceColX = qtyColX - BarteringUIUtils.COL_PRICE_WIDTH
    self:drawTextCentre("Item", (listX + BarteringUIUtils.NAME_START + priceColX) / 2, headerY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Value", priceColX + BarteringUIUtils.COL_PRICE_WIDTH / 2, headerY, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Qty", qtyColX + BarteringUIUtils.COL_QTY_WIDTH / 2, headerY, 0.7, 0.7, 0.7, 1, UIFont.Small)
end

function BarteringBarterUI:prerender()
    ISPanel.prerender(self)
    local refreshRemainingHours = Bartering.getBartererStockRefreshRemainingHours(self.bartererId)
    local isCalledIn = self.bartererZombie:getVariableBoolean("BartererCalledIn")
    BarteringUIUtils.drawHeader(self, Bartering.getBartererDisplayName(self.bartererId))
    self:drawTextRight("Stock Refreshes In: " .. BarteringTiming.formatDuration(
        BarteringTiming.gameHoursToRealSeconds(refreshRemainingHours)), self.width - 38, 10, 0.85, 0.85, 0.85, 1, UIFont.Small)
    if isCalledIn then
        local leaveRemainingSeconds = Bartering.getBartererDepartureRemainingSeconds(self.bartererId) or 0
        self:drawTextRight("Leaves In: " .. BarteringTiming.formatDuration(leaveRemainingSeconds), self.width - 38, 24, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
    if Bartering.getStockRefreshInterval() > self.stockInterval then
        self:drawTextRight("Close window to reset stock", self.width - 38, isCalledIn and 38 or 24, 0.85, 0.20, 0.20, 1, UIFont.Small)
    end
    self:drawText("Your offer", BarteringBarterUI.OfferListX, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:drawText("Barterer stock", BarteringBarterUI.StockListX, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    drawListHeaders(self, self.offerList, 58)
    drawListHeaders(self, self.stockList, 58)
    self.tradeButton.enable = #self.selectedOffers > 0 and #self.selectedStock > 0 and self.offeredValue >= self.receivedValue
    self:drawText("Offering: " .. tostring(#self.selectedOffers) .. " item(s) [" .. Bartering.formatTradeValue(self.offeredValue) .. "]", 12, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("Receiving: " .. tostring(#self.selectedStock) .. " item(s) [" .. Bartering.formatTradeValue(self.receivedValue) .. "]", BarteringBarterUI.StockListX, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function BarteringBarterUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    local ui = BarteringUIUtils.newBartererWindow(self, 540, 350, player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    ui.callMode = callMode == true
    ui.stockMap = Bartering.getBartererStockMap(bartererId, player)
    ui.stockInterval = Bartering.getStockRefreshInterval()
    ui.selectedOffers = {}
    ui.selectedStock = {}
    ui.selectedStockDetails = {}
    ui.offeredValue = 0
    ui.relationValue = 0
    ui.receivedValue = 0
    ui.offerSignature = nil
    return ui
end

function BarteringBarterUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    Bartering.queuePlayerUIStockRefresh(bartererId)
    local ui = BarteringBarterUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie, callMode)
    ui:initialise()
    ui:rebuildStockList()
    ui:addToUIManager()
    ui:registerOpen()
end

BarteringTradeConfirmUI = ISPanel:derive("BarteringTradeConfirmUI")
BarteringUIUtils.makeConfirmWindow(BarteringTradeConfirmUI, "sendTrade")

function BarteringTradeConfirmUI:populateLists()
    for _, offer in ipairs(self.parentUI.selectedOffers) do
        self.giveList:addItem(offer.displayName .. " [" .. Bartering.formatTradeValue(offer.value) .. "]", offer)
    end

    for _, detail in ipairs(self.parentUI.selectedStockDetails) do
        self.receiveList:addItem(detail.displayName .. " [" .. Bartering.formatTradeValue(detail.value) .. "]", detail)
    end
end

function BarteringTradeConfirmUI:prerender()
    ISPanel.prerender(self)
    BarteringUIUtils.drawConfirmSummary(self, "Confirm Trade")
    self:drawText("Receiving: " .. tostring(#self.parentUI.selectedStockDetails) .. " item(s) [" .. Bartering.formatTradeValue(self.receivedValue) .. "]", 213, 238, 0.8, 0.8, 0.8, 1, UIFont.Small)
    if self.offeredValue > self.receivedValue then
        self:drawText("Overpaying by [" .. Bartering.formatTradeValue(self.offeredValue - self.receivedValue) .. "]", 12, 252, 0.85, 0.65, 0.20, 1, UIFont.Small)
    end
    local xpGain = self.offeredValue + self.receivedValue + Bartering.getBonusPerLevel(self.parentUI.player)
    self:drawText("XP Gain: " .. Bartering.formatTradeValue(xpGain), 12, 266, 0.50, 0.75, 0.50, 1, UIFont.Small)
    if Bartering.getSandboxBoolean("EnableRelationships", true) then
        self:drawText("Relation Gain: " .. Bartering.formatTradeValue(self.relationValue), 12, 280, 0.50, 0.75, 0.50, 1, UIFont.Small)
    end
end

function BarteringTradeConfirmUI:new(parentUI)
    local ui = BarteringUIUtils.newConfirmWindow(self, parentUI)
    ui.relationValue = parentUI.relationValue
    ui.receivedValue = parentUI.receivedValue
    return ui
end

return BarteringBarterUI
