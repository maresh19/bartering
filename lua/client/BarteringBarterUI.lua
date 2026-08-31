require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "Bartering"

local BarteringUIUtils = require "BarteringUIUtils"
local ISPanel = _G["ISPanel"]
local ISButton = _G["ISButton"]
local ISScrollingListBox = _G["ISScrollingListBox"]
local UIFont = _G["UIFont"]
local InventoryItemFactory = _G["InventoryItemFactory"]
local BarteringTiming = require "BarteringTiming"

BarteringBarterUI = ISPanel:derive("BarteringBarterUI")
local BarteringItemList = ISScrollingListBox:derive("BarteringItemList")

local getTextManager = _G["getTextManager"]
local sendClientCommand = _G["sendClientCommand"]
BarteringBarterUI.HeaderHeight = 28
BarteringBarterUI.MaxDistanceFromOpenTile = 3
BarteringBarterUI.ChildIndent = 14
BarteringBarterUI.ColQtyWidth = 64
BarteringBarterUI.ColPriceWidth = 42

function BarteringItemList:doDrawItem(y, item, alt)
    local entry = item.item
    local qty = entry.qty or 0
    local w = self:getWidth()
    local qtyColX = w - BarteringBarterUI.ColQtyWidth
    local priceColX = qtyColX - BarteringBarterUI.ColPriceWidth

    if qty > 0 then
        self:drawRect(0, y, w, item.height - 1, 0.3, 0.12, 0.55, 0.12)
    end
    self:drawRectBorder(0, y, w, item.height, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)

    local indent = entry.indent or 0
    self:drawTextureScaledAspect(entry.item:getTex(), 3 + indent, y + 3, 16, 16, 1, 1, 1, 1)
    self:drawText(item.text, 24 + indent, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    if qty > 0 then
        self:drawRect(priceColX, y, w - priceColX, item.height - 1, 1, 0.12, 0.55, 0.12)
    else
        self:drawRect(priceColX, y, w - priceColX, item.height - 1, 1, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b, self.backgroundColor.a)
    end

    local priceStr = ""
    if entry.perUnitValue then
        priceStr = Bartering.formatTradeValue(entry.perUnitValue)
    elseif entry.value then
        priceStr = Bartering.formatTradeValue(entry.value)
    end
    if priceStr ~= "" then
        self:drawTextCentre(priceStr, priceColX + BarteringBarterUI.ColPriceWidth / 2, y + 3, 0.7, 0.7, 0.5, 1, UIFont.Small)
    end

    local btnW = 14
    local numW = 36
    local maxQty = entry.maxQty or 1
    local plusX = qtyColX + btnW + numW

    self:drawRect(qtyColX, y + 2, btnW, 16, 1, 0.30, 0.14, 0.14)
    self:drawRectBorder(qtyColX, y + 2, btnW, 16, 0.5, 0.5, 0.5, 0.5)
    self:drawText("-", qtyColX + 4, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawTextCentre(tostring(qty) .. "/" .. tostring(maxQty), qtyColX + btnW + numW / 2, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawRect(plusX, y + 2, btnW, 16, 1, 0.14, 0.30, 0.14)
    self:drawRectBorder(plusX, y + 2, btnW, 16, 0.5, 0.5, 0.5, 0.5)
    self:drawText("+", plusX + 4, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawRect(priceColX, y, 1, item.height, 1, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawRect(qtyColX, y, 1, item.height, 1, self.borderColor.r, self.borderColor.g, self.borderColor.b)

    return y + item.height
end

function BarteringItemList:addItem(name, item)
    local row = ISScrollingListBox.addItem(self, name, item)
    local indent = item.indent or 0
    local available = self:getWidth() - BarteringBarterUI.ColQtyWidth - BarteringBarterUI.ColPriceWidth - (24 + indent) - 3
    if available > 0 and getTextManager():MeasureStringX(UIFont.Small, name) > available then
        row.tooltip = name
    end
    return row
end

function BarteringItemList:onMouseDown(x, y)
    local rowH = self.itemheight or 20
    local scrollOffset = 0
    if self.javaObject and self.javaObject.getScrollArea then
        local sa = self.javaObject:getScrollArea()
        if sa then
            scrollOffset = sa:getScrollY()
        end
    end
    local contentY = y + scrollOffset
    local rowIndex = math.floor(contentY / rowH) + 1

    if rowIndex >= 1 and rowIndex <= #self.items then
        local row = self.items[rowIndex]
        local entry = row.item
        local w = self:getWidth()
        local qtyColX = w - BarteringBarterUI.ColQtyWidth
        local btnW = 14
        local numW = 36
        local plusX = qtyColX + btnW + numW
        if x >= qtyColX and x < qtyColX + btnW then
            entry.qty = math.max(0, (entry.qty or 0) - 1)
            if self.onQtyChanged then
                self.onQtyChanged(self.target, entry)
            end
            return true
        elseif x >= plusX and x < plusX + btnW then
            entry.qty = math.min(entry.maxQty or 1, (entry.qty or 0) + 1)
            if self.onQtyChanged then
                self.onQtyChanged(self.target, entry)
            end
            return true
        end
    end
    return ISScrollingListBox.onMouseDown(self, x, y)
end

function BarteringItemList:new(x, y, width, height)
    local list = ISScrollingListBox:new(x, y, width, height)
    setmetatable(list, self)
    self.__index = self
    list.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    list.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    list.drawBorder = true
    list:setFont(UIFont.Small, 3)
    list.onQtyChanged = nil
    list.target = nil
    return list
end

function BarteringBarterUI:updateSelectionValues()
    self.offeredValue = 0
    self.relationValue = 0
    self.receivedValue = 0
    self.selectedOffers = {}
    self.selectedStock = {}
    self.selectedStockDetails = {}

    for _, row in ipairs(self.offerList.items) do
        local entry = row.item
        local qty = entry.qty or 0
        if qty > 0 then
            local items = entry.items or { entry.item }
            for j = 1, qty do
                local item = items[j]
                if item then
                    self.offeredValue = self.offeredValue + entry.perUnitValue
                    if not Bartering.Quests.getCouponBarterer(item) then
                        self.relationValue = self.relationValue + entry.perUnitValue
                    end
                    table.insert(self.selectedOffers, {
                        id = item:getID(),
                        itemName = item:getFullType(),
                        unitCount = Bartering.getDrainableUnitCount(item),
                        displayName = item:getDisplayName(),
                        value = entry.perUnitValue,
                    })
                end
            end
        end
    end

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

    self.closeButton = ISButton:new(self.width - 30, 4, 22, 20, "X", self, BarteringBarterUI.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    self.closeButton.backgroundColor = { r = 0.25, g = 0.12, b = 0.12, a = 1 }
    self.closeButton.backgroundColorMouseOver = { r = 0.45, g = 0.18, b = 0.18, a = 1 }
    self:addChild(self.closeButton)

    self.tradeButton = ISButton:new(self.width - 102, self.height - 36, 90, 25, "Trade", self, BarteringBarterUI.onTrade)
    self.tradeButton:initialise()
    self.tradeButton:instantiate()
    self:addChild(self.tradeButton)

    self.offerList = BarteringItemList:new(12, 70, 230, 192)
    self.offerList:initialise()
    self.offerList:instantiate()
    self.offerList.onQtyChanged = BarteringBarterUI.onOfferQtyChanged
    self.offerList.target = self
    self:addChild(self.offerList)

    self.stockList = BarteringItemList:new(253, 70, 245, 192)
    self.stockList:initialise()
    self.stockList:instantiate()
    self.stockList.onQtyChanged = BarteringBarterUI.onStockQtyChanged
    self.stockList.target = self
    self:addChild(self.stockList)

    self.refreshButton = ISButton:new(12, self.height - 36, 90, 25, "Refresh Stock", self, BarteringBarterUI.onRefreshStock)
    self.refreshButton:initialise()
    self.refreshButton:instantiate()
    self:addChild(self.refreshButton)

    self:populateItems()
end

function BarteringBarterUI:onOfferQtyChanged(entry)
    self:updateSelectionValues()
end

function BarteringBarterUI:onStockQtyChanged(entry)
    self:updateSelectionValues()
end

function BarteringBarterUI:onRefreshStock()
    local barterer = Bartering.Barterers[self.bartererId]
    if barterer then
        self.stockMap = Bartering.generateBartererStock(Bartering.Stock.getEffectiveCapacity(), barterer.stockCount)
    end
    self.stockList:clear()
    self.selectedStock = {}
    self.selectedStockDetails = {}
    self.receivedValue = 0
    for itemName, stockQty in pairs(self.stockMap) do
        if Bartering.isBarterableItem(itemName) then
            local item = InventoryItemFactory.CreateItem(itemName)
            local perUnitValue = Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, self.player, self.bartererId)
            local label = item:getDisplayName()
            self.stockList:addItem(label, {
                item = item,
                itemName = itemName,
                perUnitValue = perUnitValue,
                maxQty = stockQty,
                qty = 0,
                selected = false,
            })
        end
    end
    self:updateSelectionValues()
end

BarteringUIUtils.makeDraggable(BarteringBarterUI, BarteringBarterUI.HeaderHeight)

function BarteringBarterUI:isOutOfTradeRange()
    return BarteringUIUtils.isPlayerOutOfRange(self.player, self.anchorX, self.anchorY, self.anchorZ,
        BarteringBarterUI.MaxDistanceFromOpenTile)
end

function BarteringBarterUI:update()
    ISPanel.update(self)
    if self:isOutOfTradeRange() then
        if self.confirmUI then
            self.confirmUI:close()
        end
        self:close()
    end
end

function BarteringBarterUI:populateItems()
    local inventoryItems = self.player:getInventory():getItems()
    local grouped = {}
    for i = 0, inventoryItems:size() - 1 do
        local item = inventoryItems:get(i)
        if Bartering.isBarterableItem(item) and Bartering.Quests.acceptsCoupon(item, self.bartererId)
            and not self.player:isEquippedClothing(item) and item:getCategory() ~= "Wound" then
            local key = item:getFullType()
            if not grouped[key] then
                grouped[key] = { item = item, items = {} }
            end
            table.insert(grouped[key].items, item)
        end
    end

    for _, group in pairs(grouped) do
        local count = #group.items
        local value = Bartering.getTradeValue(group.item, Bartering.ValueSide.Player, self.player, self.bartererId)
        local label = group.item:getDisplayName()
        self.offerList:addItem(label, {
            item = group.item,
            items = group.items,
            value = value,
            perUnitValue = value,
            maxQty = count,
            qty = 0,
            selected = false,
            indent = 0,
        })
    end

    for itemName, stockQty in pairs(self.stockMap) do
        if Bartering.isBarterableItem(itemName) then
            local item = InventoryItemFactory.CreateItem(itemName)
            local perUnitValue = Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, self.player, self.bartererId)
            local label = item:getDisplayName()
            self.stockList:addItem(label, {
                item = item,
                itemName = itemName,
                perUnitValue = perUnitValue,
                maxQty = stockQty,
                qty = 0,
                selected = false,
            })
        end
    end
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

function BarteringBarterUI:onClose()
    if self.confirmUI then
        self.confirmUI:close()
    end
    self:close()
end

function BarteringBarterUI:prerender()
    ISPanel.prerender(self)
    local refreshRemainingHours = Bartering.getBartererStockRefreshRemainingHours(self.bartererId)
    local isCalledIn = self.bartererZombie:getVariableBoolean("BartererCalledIn")
    self:drawRect(0, 0, self.width, BarteringBarterUI.HeaderHeight, 0.18, 0.16, 0.16, 0.16)
    self:drawText(Bartering.getBartererDisplayName(self.bartererId), 12, 8, 1, 1, 1, 1, UIFont.Large)
    self:drawTextRight("Stock Refreshes In: " .. BarteringTiming.formatDuration(refreshRemainingHours * 60), self.width - 38, 10, 0.85, 0.85, 0.85, 1, UIFont.Small)
    if isCalledIn then
        local departureAtMs = tonumber(self.bartererZombie:getVariableString("BartererDepartureAtMs")) or 0
        local leaveRemainingSeconds = 0
        if departureAtMs > 0 then
            leaveRemainingSeconds = math.max(0, (departureAtMs - getTimeInMillis()) / 1000)
        end
        self:drawTextRight("Leaves In: " .. BarteringTiming.formatDuration(leaveRemainingSeconds), self.width - 38, 24, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
    if refreshRemainingHours <= 0 then
        self:drawTextRight("Close window to reset stock", self.width - 38, isCalledIn and 38 or 24, 0.85, 0.20, 0.20, 1, UIFont.Small)
    end
    self:drawText("Your offer", 12, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:drawText("Barterer stock", 253, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    local nameW = 230 - BarteringBarterUI.ColQtyWidth - BarteringBarterUI.ColPriceWidth
    self:drawTextCentre("Item", 12 + nameW / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Value", 12 + nameW + BarteringBarterUI.ColPriceWidth / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Qty", 12 + nameW + BarteringBarterUI.ColPriceWidth + BarteringBarterUI.ColQtyWidth / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Item", 253 + nameW / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Value", 253 + nameW + BarteringBarterUI.ColPriceWidth / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self:drawTextCentre("Qty", 253 + nameW + BarteringBarterUI.ColPriceWidth + BarteringBarterUI.ColQtyWidth / 2, 58, 0.7, 0.7, 0.7, 1, UIFont.Small)
    self.tradeButton.enable = #self.selectedOffers > 0 and #self.selectedStock > 0 and self.offeredValue >= self.receivedValue
    self:drawText("Offering: " .. tostring(#self.selectedOffers) .. " item(s) [" .. Bartering.formatTradeValue(self.offeredValue) .. "]", 12, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("Receiving: " .. tostring(#self.selectedStock) .. " item(s) [" .. Bartering.formatTradeValue(self.receivedValue) .. "]", 253, self.height - 64, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function BarteringBarterUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    local width = 510
    local height = 350
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
    ui.stockMap = Bartering.getBartererStockMap(bartererId, player)
    ui.selectedOffers = {}
    ui.selectedStock = {}
    ui.selectedStockDetails = {}
    ui.offeredValue = 0
    ui.relationValue = 0
    ui.receivedValue = 0
    ui.dragging = false
    return ui
end

function BarteringBarterUI.open(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    Bartering.queuePlayerUIStockRefresh(bartererId)
    local ui = BarteringBarterUI:new(player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    ui:initialise()
    ui:addToUIManager()
end

BarteringTradeConfirmUI = ISPanel:derive("BarteringTradeConfirmUI")
local BarteringConfirmItemList = ISScrollingListBox:derive("BarteringConfirmItemList")

BarteringTradeConfirmUI.HeaderHeight = 28
BarteringTradeConfirmUI.ListHeight = 160

function BarteringConfirmItemList:doDrawItem(y, item, alt)
    self:drawRectBorder(0, y, self:getWidth(), item.height, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawText(item.text, 8, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)
    return y + item.height
end

function BarteringConfirmItemList:new(x, y, width, height)
    local list = ISScrollingListBox:new(x, y, width, height)
    setmetatable(list, self)
    self.__index = self
    list.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    list.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    list.drawBorder = true
    list:setFont(UIFont.Small, 3)
    return list
end

function BarteringTradeConfirmUI:initialise()
    ISPanel.initialise(self)

    self.closeButton = ISButton:new(self.width - 30, 4, 22, 20, "X", self, BarteringTradeConfirmUI.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    self.closeButton.backgroundColor = { r = 0.25, g = 0.12, b = 0.12, a = 1 }
    self.closeButton.backgroundColorMouseOver = { r = 0.45, g = 0.18, b = 0.18, a = 1 }
    self:addChild(self.closeButton)

    self.cancelButton = ISButton:new(self.width - 202, self.height - 36, 90, 25, "Cancel", self, BarteringTradeConfirmUI.onClose)
    self.cancelButton:initialise()
    self.cancelButton:instantiate()
    self.cancelButton.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    self.cancelButton.backgroundColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 }
    self.cancelButton.backgroundColorMouseOver = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    self:addChild(self.cancelButton)

    self.confirmButton = ISButton:new(self.width - 102, self.height - 36, 90, 25, "Confirm", self, BarteringTradeConfirmUI.onConfirm)
    self.confirmButton:initialise()
    self.confirmButton:instantiate()
    self.confirmButton.borderColor = { r = 0.20, g = 0.55, b = 0.20, a = 1 }
    self.confirmButton.backgroundColor = { r = 0.12, g = 0.55, b = 0.12, a = 1 }
    self.confirmButton.backgroundColorMouseOver = { r = 0.18, g = 0.70, b = 0.18, a = 1 }
    self:addChild(self.confirmButton)

    self.giveList = BarteringConfirmItemList:new(12, 70, 185, BarteringTradeConfirmUI.ListHeight)
    self.giveList:initialise()
    self.giveList:instantiate()
    self:addChild(self.giveList)

    self.receiveList = BarteringConfirmItemList:new(213, 70, 185, BarteringTradeConfirmUI.ListHeight)
    self.receiveList:initialise()
    self.receiveList:instantiate()
    self:addChild(self.receiveList)

    self:populateLists()
end

function BarteringTradeConfirmUI:populateLists()
    for _, offer in ipairs(self.parentUI.selectedOffers) do
        self.giveList:addItem(offer.displayName .. " [" .. Bartering.formatTradeValue(offer.value) .. "]", offer)
    end

    for _, detail in ipairs(self.parentUI.selectedStockDetails) do
        self.receiveList:addItem(detail.displayName .. " [" .. Bartering.formatTradeValue(detail.value) .. "]", detail)
    end
end

function BarteringTradeConfirmUI:onConfirm()
    local parentUI = self.parentUI
    parentUI.confirmUI = nil
    self:close()
    parentUI:sendTrade()
end

function BarteringTradeConfirmUI:onClose()
    self.parentUI.confirmUI = nil
    self:close()
end

function BarteringTradeConfirmUI:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, BarteringTradeConfirmUI.HeaderHeight, 0.18, 0.16, 0.16, 0.16)
    self:drawText("Confirm Trade", 12, 8, 1, 1, 1, 1, UIFont.Large)
    self:drawText("You give", 12, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:drawText("You receive", 213, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    self:drawText("Offering: " .. tostring(#self.parentUI.selectedOffers) .. " item(s) [" .. Bartering.formatTradeValue(self.offeredValue) .. "]", 12, 238, 0.8, 0.8, 0.8, 1, UIFont.Small)
    self:drawText("Receiving: " .. tostring(#self.parentUI.selectedStockDetails) .. " item(s) [" .. Bartering.formatTradeValue(self.receivedValue) .. "]", 213, 238, 0.8, 0.8, 0.8, 1, UIFont.Small)
    if self.offeredValue > self.receivedValue then
        self:drawText("Overpaying by [" .. Bartering.formatTradeValue(self.offeredValue - self.receivedValue) .. "]", 12, 252, 0.85, 0.65, 0.20, 1, UIFont.Small)
    end
    local player = self.parentUI.player
    local bonus = Bartering.getBonusPerLevel(player)
    local xpGain = self.offeredValue + self.receivedValue + bonus
    self:drawText("XP Gain: " .. Bartering.formatTradeValue(xpGain), 12, 266, 0.50, 0.75, 0.50, 1, UIFont.Small)
    local infoY = 280
    if Bartering.getSandboxBoolean("EnableRelationships", true) then
        self:drawText("Relation Gain: " .. Bartering.formatTradeValue(self.relationValue), 12, infoY, 0.50, 0.75, 0.50, 1, UIFont.Small)
        infoY = infoY + 14
    end
end

function BarteringTradeConfirmUI:new(parentUI)
    local width = 410
    local height = 330
    local x, y = BarteringUIUtils.centreOnScreen(width, height)
    local ui = ISPanel:new(x, y, width, height)
    setmetatable(ui, self)
    self.__index = self
    ui.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    ui.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    ui.parentUI = parentUI
    ui.offeredValue = parentUI.offeredValue
    ui.relationValue = parentUI.relationValue
    ui.receivedValue = parentUI.receivedValue
    ui:setCapture(true)
    ui:setAlwaysOnTop(true)
    return ui
end

function BarteringTradeConfirmUI.open(parentUI)
    local ui = BarteringTradeConfirmUI:new(parentUI)
    ui:initialise()
    ui:addToUIManager()
    return ui
end

return BarteringBarterUI
