local getCore = _G["getCore"]

local BarteringUIUtils = {}

BarteringUIUtils.ROW_FILL = { 0.10, 0.10, 0.10 }
BarteringUIUtils.ROW_BORDER = { 0.25, 0.25, 0.25 }

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
    local dx = player:getX() - anchorX
    local dy = player:getY() - anchorY
    return (dx * dx + dy * dy) > (maxDistance * maxDistance)
end

function BarteringUIUtils.makeDraggable(class, headerHeight)
    function class:onMouseDown(x, y)
        if y <= headerHeight then
            self.dragging = true
            return true
        end
        return _G["ISPanel"].onMouseDown(self, x, y)
    end

    function class:onMouseMove(dx, dy)
        if self.dragging then
            self:setX(self:getX() + dx)
            self:setY(self:getY() + dy)
            return true
        end
        return _G["ISPanel"].onMouseMove(self, dx, dy)
    end

    function class:onMouseMoveOutside(dx, dy)
        if self.dragging then
            self:setX(self:getX() + dx)
            self:setY(self:getY() + dy)
            return true
        end
        return _G["ISPanel"].onMouseMoveOutside(self, dx, dy)
    end

    function class:onMouseUp(x, y)
        self.dragging = false
        return _G["ISPanel"].onMouseUp(self, x, y)
    end
end

return BarteringUIUtils
