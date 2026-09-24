local BarteringAIUtils = require "BarteringAIUtils"

Bartering.Relations = {}

Bartering.Relations.STARS = 10
Bartering.Relations.VALUE_PER_STAR = 100
Bartering.Relations.BONUS_PER_STAR = 0.01
Bartering.Relations.STAR_SIZE = 16
Bartering.Relations.STAR_GAP = 2

function Bartering.Relations.drawStar(element, cx, cy, fillPct, starSize, bgR, bgG, bgB)
    local half = starSize / 2
    if fillPct > 0 then
        element:drawTextureScaledAspect(getTexture("media/textures/star_fill.png"), cx - half, cy - half, starSize, starSize, 1, 1, 1, 1)
        if fillPct < 1 then
            local eraseX = cx - half + math.floor(starSize * fillPct)
            local eraseW = starSize - math.floor(starSize * fillPct)
            element:drawRect(eraseX, cy - half, eraseW, starSize, 1, bgR, bgG, bgB)
        end
    end
    element:drawTextureScaledAspect(getTexture("media/textures/star_outline.png"), cx - half, cy - half, starSize, starSize, 1, 1, 1, 1)
end

function Bartering.Relations.get(player, bartererId)
    local md = player:getModData()
    md.BarteringRelations = md.BarteringRelations or {}
    return md.BarteringRelations[bartererId] or 0
end

function Bartering.Relations.add(player, bartererId, value)
    local md = player:getModData()
    md.BarteringRelations = md.BarteringRelations or {}
    md.BarteringRelations[bartererId] = (md.BarteringRelations[bartererId] or 0) + value
    player:transmitModData()
end

function Bartering.Relations.reset(player, bartererId)
    local md = player:getModData()
    md.BarteringRelations = md.BarteringRelations or {}
    md.BarteringRelations[bartererId] = nil
    player:transmitModData()
end

function Bartering.Relations.set(player, bartererId, value)
    local md = player:getModData()
    md.BarteringRelations = md.BarteringRelations or {}
    md.BarteringRelations[bartererId] = value > 0 and value or nil
    player:transmitModData()
end

function Bartering.Relations.resetAll(bartererId)
    BarteringAIUtils.forEachPlayer(function(player)
        Bartering.Relations.reset(player, bartererId)
    end)
end

function Bartering.Relations.getStarCount(player, bartererId)
    local value = Bartering.Relations.get(player, bartererId)
    return math.min(Bartering.Relations.STARS, math.floor(value / Bartering.Relations.VALUE_PER_STAR))
end

function Bartering.Relations.getStarFill(player, bartererId, starIndex)
    local value = Bartering.Relations.get(player, bartererId)
    local starStart = (starIndex - 1) * Bartering.Relations.VALUE_PER_STAR
    local remaining = value - starStart
    return math.min(1, math.max(0, remaining / Bartering.Relations.VALUE_PER_STAR))
end

function Bartering.Relations.getBonus(player, bartererId)
    if not Bartering.getSandboxBoolean("EnableRelationships", true) then
        return 0
    end
    local starCount = Bartering.Relations.getStarCount(player, bartererId)
    return starCount * Bartering.Relations.BONUS_PER_STAR
end
