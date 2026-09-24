Bartering = Bartering or {}

local ModData = _G["ModData"]
local getGameTime = _G["getGameTime"]
local BarteringDialogue = require "BarteringDialogue"
local BarteringTiming = require "BarteringTiming"

BarteringHire = {}

BarteringHire.HIRE_WARNING_SECONDS = 60
BarteringHire.HIRE_REGISTRY = "BarteringHireState"

local function getRegistry()
    return ModData.getOrCreate(BarteringHire.HIRE_REGISTRY)
end

function BarteringHire.isAllowed()
    return Bartering.getSandboxBoolean("AllowHiring", true)
end

function BarteringHire.getCostPerHour()
    return Bartering.getSandboxNumber("HireCostPerHour", 15)
end

function BarteringHire.isHired(bartererId)
    return getRegistry()[tostring(bartererId)] ~= nil
end

function BarteringHire.getHiredState(bartererId)
    return getRegistry()[tostring(bartererId)]
end

function BarteringHire.isHiredBy(player, bartererId)
    if not player then
        return false
    end
    local state = BarteringHire.getHiredState(bartererId)
    if not state then
        return false
    end
    return player:getUsername() == state.hiredBy
end

function BarteringHire.setHiredState(bartererId, state)
    getRegistry()[tostring(bartererId)] = state
    Bartering.markGlobalDirty(BarteringHire.HIRE_REGISTRY)
end

function BarteringHire.clearHiredState(bartererId)
    getRegistry()[tostring(bartererId)] = nil
    Bartering.markGlobalDirty(BarteringHire.HIRE_REGISTRY)
end

function BarteringHire.getRemainingHours(bartererId)
    local state = BarteringHire.getHiredState(bartererId)
    if not state then
        return 0
    end
    local worldAge = getGameTime():getWorldAgeHours()
    return math.max(0, state.hiredAtWorldHours + state.durationHours - worldAge)
end

function BarteringHire.getHireWarningHours()
    return BarteringHire.HIRE_WARNING_SECONDS / BarteringTiming.realSecondsPerGameHour()
end

function BarteringHire.computeHoursFromValue(tradeValue)
    local hours = tradeValue / BarteringHire.getCostPerHour()
    if hours < 1 then
        return 0
    end
    return hours
end

function BarteringHire.computeValueFromHours(hours)
    return hours * BarteringHire.getCostPerHour()
end

function BarteringHire.formatHours(hours)
    return BarteringTiming.formatCountdown(hours * 3600)
end

function BarteringHire.canHire(player, bartererId, bartererZombie)
    if not BarteringHire.isAllowed() then
        return false, BarteringDialogue.Hire.disabled
    end

    if BarteringHire.isHired(bartererId) then
        if not BarteringHire.isHiredBy(player, bartererId) then
            return false, BarteringDialogue.Hire.alreadyHired
        end
    end

    if not Bartering.hasMetBarterer(player, bartererId) then
        return false, "Introduce yourself first"
    end

    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return false, "Unknown barterer"
    end

    if Bartering.isBartererPermanentlyDead(bartererId) then
        return false, "Barterer is dead"
    end

    if Bartering.isBartererDeathHidden(bartererId) then
        return false, "Barterer is unavailable"
    end

    local missing = {}
    if Bartering.getBarterSkillLevel(player) < barterer.requiredLevel then
        table.insert(missing, "Bartering level " .. tostring(barterer.requiredLevel))
    end

    if Bartering.getSandboxBoolean("EnableRelationships", true) then
        if Bartering.Relations.getStarCount(player, bartererId) < SandboxVars.Bartering.HireRelationshipStars then
            table.insert(missing, tostring(SandboxVars.Bartering.HireRelationshipStars) .. " relationship stars")
        end
    end

    if #missing > 0 then
        return false, "Requires " .. table.concat(missing, " and ")
    end

    return true, nil
end

return BarteringHire
