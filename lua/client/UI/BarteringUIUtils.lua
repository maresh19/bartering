require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISToolTip"

local getCore = _G["getCore"]
local getTextManager = _G["getTextManager"]
local ISPanel = _G["ISPanel"]
local ISButton = _G["ISButton"]
local ISScrollingListBox = _G["ISScrollingListBox"]
local UIFont = _G["UIFont"]
local ISToolTip = _G["ISToolTip"]
local print = require("BarteringPathTrace").log

local BarteringUIUtils = {}

BarteringUIUtils.ROW_FILL = { 0.10, 0.10, 0.10 }
BarteringUIUtils.ROW_BORDER = { 0.25, 0.25, 0.25 }
BarteringUIUtils.HEADER_HEIGHT = 28
BarteringUIUtils.MAX_DISTANCE_FROM_OPEN_TILE = 3
BarteringUIUtils.OUT_OF_RANGE_CLOSE_TICKS = 10
BarteringUIUtils.COL_QTY_WIDTH = 64
BarteringUIUtils.COL_PRICE_WIDTH = 42
BarteringUIUtils.QTY_BUTTON_WIDTH = 14
BarteringUIUtils.QTY_NUMBER_WIDTH = 36
BarteringUIUtils.NAME_START = 24
BarteringUIUtils.SALE_TEXT = "15% off!"
BarteringUIUtils.CONFIRM_WIDTH = 410
BarteringUIUtils.CONFIRM_HEIGHT = 330
BarteringUIUtils.CONFIRM_LIST_HEIGHT = 160

BarteringUIUtils.ButtonStyles = {
    close = { border = { 0.35, 0.35, 0.35 }, background = { 0.25, 0.12, 0.12 }, hover = { 0.45, 0.18, 0.18 } },
    cancel = { border = { 0.35, 0.35, 0.35 }, background = { 0.20, 0.20, 0.20 }, hover = { 0.35, 0.35, 0.35 } },
    confirm = { border = { 0.20, 0.55, 0.20 }, background = { 0.12, 0.55, 0.12 }, hover = { 0.18, 0.70, 0.18 } },
}

local function rgba(rgb, a)
    return { r = rgb[1], g = rgb[2], b = rgb[3], a = a }
end

function BarteringUIUtils.addContextTooltip(option, description)
    option.toolTip = _G["ISInventoryPaneContextMenu"].addToolTip()
    option.toolTip.description = description
    return option.toolTip
end

function BarteringUIUtils.centreOnScreen(width, height)
    local core = getCore()
    return (core:getScreenWidth() - width) / 2, (core:getScreenHeight() - height) / 2
end

function BarteringUIUtils.drawRow(element, x, y, w, h, alpha, r, g, b)
    local fill = BarteringUIUtils.ROW_FILL
    local border = BarteringUIUtils.ROW_BORDER
    element:drawRect(x, y, w, h, alpha or 0.8, r or fill[1], g or fill[2], b or fill[3])
    element:drawRectBorder(x, y, w, h, 1, border[1], border[2], border[3])
end

function BarteringUIUtils.isPlayerOutOfRange(player, anchorX, anchorY, anchorZ, maxDistance)
    if player:getZ() ~= anchorZ then
        return true
    end
    local dx = math.floor(player:getX()) - anchorX
    local dy = math.floor(player:getY()) - anchorY
    return (dx * dx + dy * dy) > (maxDistance * maxDistance)
end

function BarteringUIUtils.makeDraggable(class, headerHeight)
    function class:onMouseDown(x, y)
        if y <= headerHeight then
            self.dragging = true
            return true
        end
        return ISPanel.onMouseDown(self, x, y)
    end

    function class:onMouseMove(dx, dy)
        if self.dragging then
            self:setX(self:getX() + dx)
            self:setY(self:getY() + dy)
            return true
        end
        return ISPanel.onMouseMove(self, dx, dy)
    end

    function class:onMouseMoveOutside(dx, dy)
        if self.dragging then
            self:setX(self:getX() + dx)
            self:setY(self:getY() + dy)
            return true
        end
        return ISPanel.onMouseMoveOutside(self, dx, dy)
    end

    function class:onMouseUp(x, y)
        self.dragging = false
        return ISPanel.onMouseUp(self, x, y)
    end
end

function BarteringUIUtils.ellipsize(text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(UIFont.Small, text) <= maxW then
        return text
    end
    local suffix = "..."
    while #text > 1 do
        text = text:sub(1, -2)
        if tm:MeasureStringX(UIFont.Small, text .. suffix) <= maxW then
            return text .. suffix
        end
    end
    return suffix
end

function BarteringUIUtils.showHoverTooltip(owner, key, text)
    local tooltip = owner[key]
    if not text then
        if tooltip and tooltip:getIsVisible() then
            tooltip:setVisible(false)
            tooltip:removeFromUIManager()
        end
        return
    end
    if not tooltip then
        tooltip = ISToolTip:new()
        tooltip:setOwner(owner)
        tooltip:setVisible(false)
        tooltip:setAlwaysOnTop(true)
        tooltip.maxLineWidth = 300
        owner[key] = tooltip
    end
    if not tooltip:getIsVisible() then
        tooltip:addToUIManager()
        tooltip:setVisible(true)
    end
    tooltip.description = text
    tooltip:setDesiredPosition(getMouseX() + 12, getMouseY() + 12)
end

function BarteringUIUtils.playButtonClickSound(ui)
    if not ui.staticSoundQueue then
        ui.staticSoundQueue = {}
        local baseUpdate = ui.update
        ui.update = function(self)
            baseUpdate(self)
            local queue = self.staticSoundQueue
            local now = getTimestamp()
            for i = #queue, 1, -1 do
                local entry = queue[i]
                if not entry.started and now >= entry.startAt then
                    entry.started = true
                    entry.instance = getSoundManager():playUISound("RadioStatic")
                    print("[Bartering][ClickSound] static in uid=" .. tostring(entry.instance) .. " now=" .. tostring(now))
                end
                if entry.started and now >= entry.stopAt then
                    getSoundManager():stopUISound(entry.instance)
                    print("[Bartering][ClickSound] static out uid=" .. tostring(entry.instance) .. " now=" .. tostring(now))
                    table.remove(queue, i)
                end
            end
        end
    end
    for _, entry in ipairs(ui.staticSoundQueue) do
        if entry.started then
            getSoundManager():stopUISound(entry.instance)
            print("[Bartering][ClickSound] retrigger stopped uid=" .. tostring(entry.instance))
        end
    end
    ui.staticSoundQueue = {}
    local zapId = getSoundManager():playUISound("RadioZap")
    print("[Bartering][ClickSound] click zap uid=" .. tostring(zapId) .. " now=" .. tostring(getTimestamp()))
    local startAt = getTimestamp() + 250
    table.insert(ui.staticSoundQueue, {
        startAt = startAt,
        stopAt = startAt + 1000,
        started = false,
        instance = 0,
    })
end

function BarteringUIUtils.addButton(ui, x, y, w, h, title, onClick, style)
    local handler = onClick
    if ui.callMode then
        handler = function(target, btn, ...)
            BarteringUIUtils.playButtonClickSound(ui)
            return onClick(target, btn, ...)
        end
    end
    local button = ISButton:new(x, y, w, h, title, ui, handler)
    button:initialise()
    button:instantiate()
    if ui.callMode then
        button:setSound("activate", nil)
    end
    if style then
        button.borderColor = rgba(style.border, 1)
        button.backgroundColor = rgba(style.background, 1)
        button.backgroundColorMouseOver = rgba(style.hover, 1)
    end
    ui:addChild(button)
    return button
end

function BarteringUIUtils.addCloseButton(ui, onClick)
    return BarteringUIUtils.addButton(ui, ui.width - 30, 4, 22, 20, "X", onClick, BarteringUIUtils.ButtonStyles.close)
end

function BarteringUIUtils.newPanel(class, width, height)
    local x, y = BarteringUIUtils.centreOnScreen(width, height)
    local ui = ISPanel:new(x, y, width, height)
    setmetatable(ui, class)
    class.__index = class
    ui.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    ui.borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    return ui
end

function BarteringUIUtils.newBartererWindow(class, width, height, player, bartererId, anchorX, anchorY, anchorZ, bartererZombie)
    local ui = BarteringUIUtils.newPanel(class, width, height)
    ui.player = player
    ui.bartererId = bartererId
    ui.anchorX = anchorX
    ui.anchorY = anchorY
    ui.anchorZ = anchorZ
    ui.bartererZombie = bartererZombie
    ui.dragging = false
    return ui
end

function BarteringUIUtils.drawHeader(ui, title)
    ui:drawRect(0, 0, ui.width, BarteringUIUtils.HEADER_HEIGHT, 0.18, 0.16, 0.16, 0.16)
    ui:drawText(title, 12, 8, 1, 1, 1, 1, UIFont.Large)
end

function BarteringUIUtils.closeWindow(ui)
    ui:unregisterOpen()
    if ui.confirmUI then
        ui.confirmUI:onClose()
        ui.confirmUI = nil
    end
    ui:setVisible(false)
    ui:removeFromUIManager()
end

local function newStyledList(class, x, y, width, height)
    local list = ISScrollingListBox:new(x, y, width, height)
    setmetatable(list, class)
    class.__index = class
    list.backgroundColor = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
    list.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
    list.drawBorder = true
    list:setFont(UIFont.Small, 3)
    return list
end

function BarteringUIUtils.getListContentWidth(list)
    return list:getWidth() - list.vscroll:getWidth()
end

local QtyItemList = ISScrollingListBox:derive("BarteringQtyItemList")

local function isEntryOnSale(list, entry)
    return list.showSales and entry.itemName ~= nil
        and Bartering.isBartererItemOnSale(list.target.bartererId, entry.itemName, list.target.player)
end

local function getEntryNameMax(list, indent, onSale)
    local priceColX = BarteringUIUtils.getListContentWidth(list) - BarteringUIUtils.COL_QTY_WIDTH - BarteringUIUtils.COL_PRICE_WIDTH
    local nameMax = priceColX - 6 - BarteringUIUtils.NAME_START - indent
    if onSale then
        nameMax = nameMax - getTextManager():MeasureStringX(UIFont.Small, BarteringUIUtils.SALE_TEXT) - 4
    end
    return math.max(1, nameMax)
end

function QtyItemList:doDrawItem(y, item, alt)
    local entry = item.item
    local qty = entry.qty or 0
    local w = BarteringUIUtils.getListContentWidth(self)
    local qtyColX = w - BarteringUIUtils.COL_QTY_WIDTH
    local priceColX = qtyColX - BarteringUIUtils.COL_PRICE_WIDTH
    local indent = entry.indent or 0
    local onSale = isEntryOnSale(self, entry)

    if qty > 0 then
        self:drawRect(0, y, w, item.height - 1, 0.3, 0.12, 0.55, 0.12)
    end
    self:drawRectBorder(0, y, w, item.height, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)

    self:drawTextureScaledAspect(entry.item:getTex(), 3 + indent, y + 3, 16, 16, 1, 1, 1, 1)
    self:drawText(BarteringUIUtils.ellipsize(item.text, getEntryNameMax(self, indent, onSale)),
        BarteringUIUtils.NAME_START + indent, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    if qty > 0 then
        self:drawRect(priceColX, y, w - priceColX, item.height - 1, 1, 0.12, 0.55, 0.12)
    else
        self:drawRect(priceColX, y, w - priceColX, item.height - 1, 1, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b, self.backgroundColor.a)
    end

    local price = entry.perUnitValue or entry.value
    if price then
        self:drawTextCentre(Bartering.formatTradeValue(price), priceColX + BarteringUIUtils.COL_PRICE_WIDTH / 2, y + 3, 0.7, 0.7, 0.5, 1, UIFont.Small)
    end

    if onSale then
        self:drawTextRight(BarteringUIUtils.SALE_TEXT, priceColX - 6, y + 3, 0.2, 0.9, 0.2, 1, UIFont.Small)
    end

    local btnW = BarteringUIUtils.QTY_BUTTON_WIDTH
    local numW = BarteringUIUtils.QTY_NUMBER_WIDTH
    local plusX = qtyColX + btnW + numW

    self:drawRect(qtyColX, y + 2, btnW, 16, 1, 0.30, 0.14, 0.14)
    self:drawRectBorder(qtyColX, y + 2, btnW, 16, 0.5, 0.5, 0.5, 0.5)
    self:drawText("-", qtyColX + 4, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawTextCentre(tostring(qty) .. "/" .. tostring(entry.maxQty or 1), qtyColX + btnW + numW / 2, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawRect(plusX, y + 2, btnW, 16, 1, 0.14, 0.30, 0.14)
    self:drawRectBorder(plusX, y + 2, btnW, 16, 0.5, 0.5, 0.5, 0.5)
    self:drawText("+", plusX + 4, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)

    self:drawRect(priceColX, y, 1, item.height, 1, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawRect(qtyColX, y, 1, item.height, 1, self.borderColor.r, self.borderColor.g, self.borderColor.b)

    return y + item.height
end

function QtyItemList:addItem(name, item)
    local row = ISScrollingListBox.addItem(self, name, item)
    local maxW = getEntryNameMax(self, item.indent or 0, isEntryOnSale(self, item))
    if getTextManager():MeasureStringX(UIFont.Small, name) > maxW then
        row.tooltip = name
    end
    return row
end

function QtyItemList:onMouseDown(x, y)
    local rowIndex = math.floor(y / (self.itemheight or 20)) + 1

    if rowIndex >= 1 and rowIndex <= #self.items then
        local entry = self.items[rowIndex].item
        local qtyColX = BarteringUIUtils.getListContentWidth(self) - BarteringUIUtils.COL_QTY_WIDTH
        local btnW = BarteringUIUtils.QTY_BUTTON_WIDTH
        local plusX = qtyColX + btnW + BarteringUIUtils.QTY_NUMBER_WIDTH
        if x >= qtyColX and x < qtyColX + btnW then
            entry.qty = math.max(0, (entry.qty or 0) - 1)
            self.onQtyChanged(self.target, entry)
            return true
        elseif x >= plusX and x < plusX + btnW then
            entry.qty = math.min(entry.maxQty or 1, (entry.qty or 0) + 1)
            self.onQtyChanged(self.target, entry)
            return true
        end
    end
    return ISScrollingListBox.onMouseDown(self, x, y)
end

function BarteringUIUtils.addQtyList(ui, x, y, width, height, onQtyChanged, showSales)
    local list = newStyledList(QtyItemList, x, y, width, height)
    list.onQtyChanged = onQtyChanged
    list.target = ui
    list.showSales = showSales == true
    list:initialise()
    list:instantiate()
    ui:addChild(list)
    return list
end

local ConfirmItemList = ISScrollingListBox:derive("BarteringConfirmItemList")

function ConfirmItemList:doDrawItem(y, item, alt)
    self:drawRectBorder(0, y, self:getWidth(), item.height, 0.5, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawText(item.text, 8, y + 3, 0.9, 0.9, 0.9, 1, UIFont.Small)
    return y + item.height
end

function BarteringUIUtils.addConfirmList(ui, x, y, width, height)
    local list = newStyledList(ConfirmItemList, x, y, width, height)
    list:initialise()
    list:instantiate()
    ui:addChild(list)
    return list
end

function BarteringUIUtils.isOfferableItem(player, bartererId, item)
    return Bartering.isBarterableItem(item) and Bartering.Quests.acceptsCoupon(item, bartererId)
        and not player:isEquippedClothing(item) and item:getCategory() ~= "Wound"
end

function BarteringUIUtils.getOfferInventorySignature(player, bartererId)
    local inventoryItems = player:getInventory():getItems()
    local grouped = {}
    for i = 0, inventoryItems:size() - 1 do
        local item = inventoryItems:get(i)
        if BarteringUIUtils.isOfferableItem(player, bartererId, item) then
            local key = item:getFullType()
            grouped[key] = (grouped[key] or 0) + 1
        end
    end

    local keys = {}
    for key in pairs(grouped) do
        table.insert(keys, key)
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, key .. "=" .. tostring(grouped[key]))
    end
    return table.concat(parts, "|")
end

function BarteringUIUtils.populateOfferList(ui)
    ui.offerList:clear()
    local inventoryItems = ui.player:getInventory():getItems()
    local grouped = {}
    for i = 0, inventoryItems:size() - 1 do
        local item = inventoryItems:get(i)
        if BarteringUIUtils.isOfferableItem(ui.player, ui.bartererId, item) then
            local key = item:getFullType()
            if not grouped[key] then
                grouped[key] = { item = item, items = {} }
            end
            table.insert(grouped[key].items, item)
        end
    end

    for _, group in pairs(grouped) do
        local value = Bartering.getTradeValue(group.item, Bartering.ValueSide.Player, ui.player, ui.bartererId)
        ui.offerList:addItem(group.item:getDisplayName(), {
            item = group.item,
            items = group.items,
            value = value,
            perUnitValue = value,
            maxQty = #group.items,
            qty = 0,
            selected = false,
            indent = 0,
        })
    end

    ui.offerSignature = BarteringUIUtils.getOfferInventorySignature(ui.player, ui.bartererId)
    ui:updateSelectionValues()
end

function BarteringUIUtils.collectSelectedOffers(offerList)
    local offers = {}
    local offeredValue = 0
    local relationValue = 0
    for _, row in ipairs(offerList.items) do
        local entry = row.item
        local qty = entry.qty or 0
        if qty > 0 then
            for j = 1, qty do
                local item = entry.items[j]
                if item then
                    offeredValue = offeredValue + entry.perUnitValue
                    if not Bartering.Quests.getCouponBarterer(item) then
                        relationValue = relationValue + entry.perUnitValue
                    end
                    table.insert(offers, {
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
    return offers, offeredValue, relationValue
end

function BarteringUIUtils.addOpenRegistry(class)
    local open = {}

    function class:registerOpen()
        open[self.bartererId] = self
    end

    function class:unregisterOpen()
        if open[self.bartererId] == self then
            open[self.bartererId] = nil
        end
    end

    function class.closeAll()
        for _, ui in pairs(open) do
            ui:close()
        end
    end

    function class.refreshOpenOffers(character)
        for _, ui in pairs(open) do
            if ui.player == character then
                ui:refreshOffers()
            end
        end
    end

    return open
end

function BarteringUIUtils.addOfferWindow(class)
    function class:getOfferInventorySignature()
        return BarteringUIUtils.getOfferInventorySignature(self.player, self.bartererId)
    end

    function class:populateItems()
        BarteringUIUtils.populateOfferList(self)
    end

    function class:refreshOffers()
        self.offerList:clear()
        self:populateItems()
    end

    function class:onOfferQtyChanged(entry)
        self:updateSelectionValues()
    end

    function class:onClose()
        self:close()
    end

    function class:isOutOfTradeRange()
        return BarteringUIUtils.isPlayerOutOfRange(self.player, self.anchorX, self.anchorY, self.anchorZ,
            BarteringUIUtils.MAX_DISTANCE_FROM_OPEN_TILE)
    end

    function class:update()
        ISPanel.update(self)
        if self:isOutOfTradeRange() then
            self.outOfRangeTicks = (self.outOfRangeTicks or 0) + 1
            if self.outOfRangeTicks >= BarteringUIUtils.OUT_OF_RANGE_CLOSE_TICKS then
                self:close()
                return
            end
        else
            self.outOfRangeTicks = 0
        end

        if self:getOfferInventorySignature() ~= self.offerSignature then
            self:refreshOffers()
        end
    end

    BarteringUIUtils.makeDraggable(class, BarteringUIUtils.HEADER_HEIGHT)
end

function BarteringUIUtils.makeConfirmWindow(class, sendMethod)
    function class:initialise()
        ISPanel.initialise(self)
        local styles = BarteringUIUtils.ButtonStyles
        self.closeButton = BarteringUIUtils.addCloseButton(self, class.onClose)
        self.cancelButton = BarteringUIUtils.addButton(self, self.width - 202, self.height - 36, 90, 25, "Cancel", class.onClose, styles.cancel)
        self.confirmButton = BarteringUIUtils.addButton(self, self.width - 102, self.height - 36, 90, 25, "Confirm", class.onConfirm, styles.confirm)
        self.giveList = BarteringUIUtils.addConfirmList(self, 12, 70, 185, BarteringUIUtils.CONFIRM_LIST_HEIGHT)
        self.receiveList = BarteringUIUtils.addConfirmList(self, 213, 70, 185, BarteringUIUtils.CONFIRM_LIST_HEIGHT)
        self:populateLists()
    end

    function class:onConfirm()
        local parentUI = self.parentUI
        parentUI.confirmUI = nil
        self:close()
        parentUI[sendMethod](parentUI)
    end

    function class:onClose()
        self.parentUI.confirmUI = nil
        self:close()
    end

    function class.open(parentUI)
        local ui = class:new(parentUI)
        ui:initialise()
        ui:addToUIManager()
        return ui
    end
end

function BarteringUIUtils.newConfirmWindow(class, parentUI)
    local ui = BarteringUIUtils.newPanel(class, BarteringUIUtils.CONFIRM_WIDTH, BarteringUIUtils.CONFIRM_HEIGHT)
    ui.parentUI = parentUI
    ui.callMode = parentUI.callMode
    ui.offeredValue = parentUI.offeredValue
    ui:setCapture(true)
    ui:setAlwaysOnTop(true)
    return ui
end

function BarteringUIUtils.drawConfirmSummary(ui, title)
    BarteringUIUtils.drawHeader(ui, title)
    ui:drawText("You give", 12, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    ui:drawText("You receive", 213, 46, 0.9, 0.9, 0.9, 1, UIFont.Small)
    ui:drawText("Offering: " .. tostring(#ui.parentUI.selectedOffers) .. " item(s) ["
        .. Bartering.formatTradeValue(ui.offeredValue) .. "]", 12, 238, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

return BarteringUIUtils
