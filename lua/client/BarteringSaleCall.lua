require "ISUI/ISPanel"
require "Bartering"

local events = _G["Events"]
local getCore = _G["getCore"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getPlayerMiniMap = _G["getPlayerMiniMap"]
local ISPanel = _G["ISPanel"]
local getTexture = _G["getTexture"]

local BarteringTiming = require "BarteringTiming"
local BarteringDialogUI = require "UI/BarteringDialogUI"
local BarteringUIUtils = require "UI/BarteringUIUtils"

local BarteringSaleCallUI = ISPanel:derive("BarteringSaleCallUI")

local TWIST_MAX = math.rad(15)
local TWIST_PERIOD_MS = 1300
local WAVE_PERIOD_MS = 1000
local WAVE_COUNT = 3
local WAVE_BASE = 16
local WAVE_TRAVEL = 44

local OUTLINE = { r = 0.70, g = 1.00, b = 0.80 }
local WAVE = { r = 0.55, g = 0.88, b = 1.00 }

local TEX_W = 360
local TEX_H = 520
local TIP_FX = 188.8 / 360
local TIP_FY = 110 / 520

local ICON_W = 96
local ICON_H = 132
local MARGIN = 20
local QUAD_W = 84

local WALKIE_TEX = getTexture("media/textures/walkie_outline.png")

local ui
local pendingCalls = {}

local function rotatedCorner(hw, hh, cosA, sinA, cx, cy)
    local rx = hw * cosA - hh * sinA
    local ry = hw * sinA + hh * cosA
    return cx + rx, cy + ry
end

function BarteringSaleCallUI:new(x, y, width, height)
    local element = ISPanel:new(x, y, width, height)
    setmetatable(element, self)
    self.__index = self
    element.background = false
    element.activeCall = nil
    return element
end

function BarteringSaleCallUI:initialise()
    ISPanel.initialise(self)
    self:setWidth(ICON_W)
    self:setHeight(ICON_H)
    self:setVisible(false)
    self:setX(getCore():getScreenWidth() - ICON_W - MARGIN)
    self:setY(getCore():getScreenHeight() - ICON_H - MARGIN)
end

function BarteringSaleCallUI:play(bartererId)
    Bartering.markBartererSaleCallAnnounced(bartererId)
    self.activeCall = {
        bartererId = bartererId,
        startedAtMs = BarteringTiming.now(),
    }
    BarteringUIUtils.playButtonClickSound(self)
    self:reposition()
    self:setVisible(true)
end

function BarteringSaleCallUI:onMouseDown(x, y)
    local call = self.activeCall
    if not call then
        return false
    end
    local player = getSpecificPlayer(0)
    if player then
        BarteringUIUtils.playButtonClickSound(self)
        BarteringDialogUI.open(player, call.bartererId, 0, 0, 0, nil, true, true)
    end
    self.activeCall = nil
    self:setVisible(false)
    return true
end

function BarteringSaleCallUI:reposition()
    local iconX = getCore():getScreenWidth() - self:getWidth() - MARGIN
    local iconY = getCore():getScreenHeight() - self:getHeight() - MARGIN

    local miniMap = getPlayerMiniMap(0)
    if miniMap and miniMap:isReallyVisible() then
        local mmX = miniMap:getX()
        local mmY = miniMap:getY()
        local mmW = miniMap:getWidth()
        local mmH = miniMap:getHeight()
        local overlaps = iconX < mmX + mmW
            and iconX + self:getWidth() > mmX
            and iconY < mmY + mmH
            and iconY + self:getHeight() > mmY
        if overlaps then
            local aboveY = mmY - self:getHeight() - MARGIN
            if aboveY < 0 then
                iconX = mmX - self:getWidth() - MARGIN
            else
                iconY = aboveY
            end
        end
    end

    self:setX(iconX)
    self:setY(iconY)
end

local function meetsSkillRequirement(player, bartererId)
    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return false
    end
    return Bartering.getBarterSkillLevel(player) >= barterer.requiredLevel
end

local function isBartererDead(bartererId)
    local lifeState = Bartering.getBartererLifeState(bartererId)
    return lifeState.permanentlyDead == true or BarteringTiming.remainingHours(lifeState.respawnAt) > 0
end

function BarteringSaleCallUI:update()
    local player = getSpecificPlayer(0)
    if player then
        for bartererId in pairs(Bartering.Barterers) do
            if not Bartering.isBartererSaleCallAnnounced(bartererId)
                and not isBartererDead(bartererId)
                and Bartering.hasWalkieTalkie(player)
                and Bartering.isBartererKnown(player, bartererId)
                and meetsSkillRequirement(player, bartererId)
                and (not Bartering.getSandboxBoolean("EnableRelationships", true)
                    or Bartering.Relations.getStarCount(player, bartererId) >= SandboxVars.Bartering.CallRelationshipStars)
                and Bartering.isBartererSaleActive(bartererId) then
                self:play(bartererId)
            end
        end
    end

    local call = self.activeCall
    if not call then
        return
    end
    if isBartererDead(call.bartererId) then
        self.activeCall = nil
        self:setVisible(false)
    end
end

function BarteringSaleCallUI:drawSegment(x1, y1, x2, y2, r, g, b, a, thickness)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then
        return
    end

    local half = thickness / 2
    local ux, uy = -dy / length, dx / length
    self:drawTextureAllPoint(nil,
        x1 + ux * half, y1 + uy * half,
        x2 + ux * half, y2 + uy * half,
        x2 - ux * half, y2 - uy * half,
        x1 - ux * half, y1 - uy * half,
        r, g, b, a)
end

function BarteringSaleCallUI:drawRing(cx, cy, radius, alpha, thickness)
    local segments = 24
    for i = 1, segments do
        local a0 = (i - 1) * 2 * math.pi / segments
        local a1 = i * 2 * math.pi / segments
        self:drawSegment(
            cx + radius * math.cos(a0), cy + radius * math.sin(a0),
            cx + radius * math.cos(a1), cy + radius * math.sin(a1),
            WAVE.r, WAVE.g, WAVE.b, alpha, thickness)
    end
end

function BarteringSaleCallUI:drawWalkie(cx, cy, quadW, quadH, angle, alpha)
    local cosA, sinA = math.cos(angle), math.sin(angle)
    local hw, hh = quadW / 2, quadH / 2
    local tlx, tly = rotatedCorner(-hw, -hh, cosA, sinA, cx, cy)
    local trx, try = rotatedCorner(hw, -hh, cosA, sinA, cx, cy)
    local brx, bry = rotatedCorner(hw, hh, cosA, sinA, cx, cy)
    local blx, bly = rotatedCorner(-hw, hh, cosA, sinA, cx, cy)
    self:drawTextureAllPoint(WALKIE_TEX, tlx, tly, trx, try, brx, bry, blx, bly,
        OUTLINE.r, OUTLINE.g, OUTLINE.b, alpha)
end

function BarteringSaleCallUI:drawWaves(cx, cy, quadW, quadH, angle, elapsed, alpha, scale)
    local cosA, sinA = math.cos(angle), math.sin(angle)
    local ox = quadW * (TIP_FX - 0.5)
    local oy = quadH * (TIP_FY - 0.5)
    local wx = ox * cosA - oy * sinA + cx
    local wy = ox * sinA + oy * cosA + cy

    local thickness = 2
    for i = 0, WAVE_COUNT - 1 do
        local phase = ((elapsed / WAVE_PERIOD_MS) + i / WAVE_COUNT) % 1
        local radius = (WAVE_BASE + phase * WAVE_TRAVEL) * scale
        local ringAlpha = alpha * (1 - phase) * 0.9
        self:drawRing(wx, wy, radius, ringAlpha, thickness)
    end
end

function BarteringSaleCallUI:prerender()
    local call = self.activeCall
    if not call then
        return
    end

    local elapsed = BarteringTiming.elapsedSince(call.startedAtMs)
    local alpha = math.min(elapsed / 350, 1)

    local quadH = QUAD_W * TEX_H / TEX_W
    local cx = self:getX() + self:getWidth() / 2
    local cy = self:getY() + self:getHeight() / 2 - 8
    local angle = TWIST_MAX * math.sin(2 * math.pi * elapsed / TWIST_PERIOD_MS)

    self:drawWalkie(cx, cy, QUAD_W, quadH, angle, alpha)
    self:drawWaves(cx, cy, QUAD_W, quadH, angle, elapsed, alpha, QUAD_W / 240)
end

BarteringSaleCall = {}

function BarteringSaleCall.show(bartererId)
    if ui then
        ui:play(bartererId)
    else
        pendingCalls[#pendingCalls + 1] = bartererId
    end
end

local function ensureUI()
    if ui then
        return
    end
    ui = BarteringSaleCallUI:new(0, 0, ICON_W, ICON_H)
    ui:initialise()
    ui:addToUIManager()
    for _, bartererId in ipairs(pendingCalls) do
        ui:play(bartererId)
    end
    pendingCalls = {}
end

events.OnGameStart.Add(ensureUI)

events.OnServerCommand.Add(function(module, command, args)
    if module ~= "Bartering" or command ~= "saleCall" then
        return
    end
    if getSpecificPlayer(0) then
        BarteringSaleCall.show(args.bartererId)
    end
end)

return BarteringSaleCall