Bartering = Bartering or {}
Bartering.MOD_ID = "Bartering"

local Perks = _G["Perks"]
local SandboxVars = _G["SandboxVars"]
local getSandboxOptions = _G["getSandboxOptions"]
local ModData = _G["ModData"]
local ZombRand = _G["ZombRand"]
local IsoLightSource = _G["IsoLightSource"]
local getCell = _G["getCell"]
local BarteringAIUtils = require "BarteringAIUtils"

Bartering.Registries = {
    Call = "BarteringCallRegistry",
    ActiveCalledIn = "BarteringActiveCalledIn",
    ReturningHome = "BarteringReturningHome",
}

Bartering.MuzzleFlash = {
    r = 0.95,
    g = 0.82,
    b = 0.55,
    radius = 8,
}

require "BarteringValues"
require "BarteringStock"
require "BarteringPerk"
require "BarteringBarterers"
require "BarteringSync"
require "BarteringIdentity"
require "BarteringCalls"
require "BarteringRelations"
require "BarteringNamedPlaces"
require "BarteringQuests"

function Bartering.getRegistryRecord(registry, id)
    return ModData.getOrCreate(registry)[tostring(id or "")]
end

function Bartering.setRegistryRecord(registry, id, record)
    local key = tostring(id or "")
    if key == "" then
        return
    end

    ModData.getOrCreate(registry)[key] = record
end

function Bartering.getBartererLifeState(bartererId)
    return ModData.getOrCreate("BarteringLife_" .. bartererId)
end

function Bartering.pickRandomListItem(items)
    if #items == 0 then
        return nil
    end
    return items[ZombRand(#items) + 1]
end

function Bartering.setBartererHome(barterer, x, y, z)
    barterer.x, barterer.y, barterer.z = x, y, z
    local state = Bartering.getBartererLifeState(barterer.id)
    state.homeX, state.homeY, state.homeZ = x, y, z
    Bartering.markBartererDataDirty(barterer.id)
end

function Bartering.restoreBartererHome(barterer)
    local state = Bartering.getBartererLifeState(barterer.id)
    if state.homeX == nil then
        return
    end
    barterer.x, barterer.y, barterer.z = state.homeX, state.homeY, state.homeZ
end

function Bartering.pickSpawnLocationNear(barterer, player, maxDistSq)
    local candidates = {}
    for _, loc in ipairs(barterer.spawnLocations) do
        if BarteringAIUtils.distanceSqToTile(player:getX(), player:getY(), loc.x, loc.y) <= maxDistSq then
            table.insert(candidates, loc)
        end
    end

    local loc = Bartering.pickRandomListItem(candidates)
    Bartering.setBartererHome(barterer, loc.x, loc.y, loc.z)
    return loc.x, loc.y, loc.z
end


function Bartering.isNearAnySpawnLocation(barterer, x, y, maxDistSq)
    for _, loc in ipairs(barterer.spawnLocations) do
        if BarteringAIUtils.distanceSqToTile(x, y, loc.x, loc.y) <= maxDistSq then
            return true
        end
    end
    return false
end

function Bartering.copyList(items)
    local copied = {}
    for _, item in ipairs(items) do
        table.insert(copied, item)
    end
    return copied
end

function Bartering.spawnMuzzleFlashLight(zombie)
    local square = zombie:getSquare()
    if not square then
        return
    end

    getCell():addLamppost(IsoLightSource.new(square:getX(), square:getY(), square:getZ(),
        Bartering.MuzzleFlash.r, Bartering.MuzzleFlash.g, Bartering.MuzzleFlash.b, Bartering.MuzzleFlash.radius))
end

function Bartering.getSandboxNumber(key, default)
    local value = SandboxVars.Bartering[key]
    if value == nil then
        return default
    end
    return tonumber(value) or default
end

function Bartering.getSandboxBoolean(key, default)
    local value = SandboxVars.Bartering[key]
    if value == nil then
        return default
    end
    return value
end

function Bartering.getBarterSkillLevel(player)
    if not Bartering.getSandboxBoolean("EnableSkill", true) then
        return 10
    end

    local perk = Perks.Bartering
    return player:getPerkLevel(perk)
end

function Bartering.isBartererPermanentlyDead(bartererId)
    return Bartering.getBartererLifeState(bartererId).permanentlyDead == true
end

function Bartering.getMetBarterers(player)
    local modData = player:getModData()
    if not modData.BarteringMetBarterers then
        modData.BarteringMetBarterers = {}
    end
    return modData.BarteringMetBarterers
end

function Bartering.hasMetBarterer(player, bartererId)
    return Bartering.getMetBarterers(player)[bartererId] == true
end

function Bartering.isBartererKnown(player, bartererId)
    if not Bartering.getSandboxBoolean("RequireMeetingBeforeCalling", true) then
        return true
    end
    return Bartering.hasMetBarterer(player, bartererId)
end

function Bartering.meetBarterer(player, bartererId)
    local metBarterers = Bartering.getMetBarterers(player)
    if metBarterers[bartererId] then
        return
    end

    metBarterers[bartererId] = true
    player:transmitModData()
end

function Bartering.getBonusPerLevel(player)
    local level = Bartering.getBarterSkillLevel(player)
    return Bartering.getSandboxNumber("BarterValueBonusPerLevel", 0.1) * level
end

function Bartering.awardTradeXp(player, offeredItemOrValue, receivedItemOrValue)
    local offeredValue = Bartering.getTradeValue(offeredItemOrValue, Bartering.ValueSide.Player, player)
    local receivedValue = Bartering.getTradeValue(receivedItemOrValue, Bartering.ValueSide.Barterer, player)
    local bonus = Bartering.getBonusPerLevel(player)
    local xpGain = offeredValue + receivedValue + bonus

    if xpGain <= 0 then
        return
    end

    Bartering.addBarteringXp(player, xpGain)
    print("[Bartering] XP +" .. tostring(xpGain) .. " (bartering level " .. tostring(Bartering.getBarterSkillLevel(player)) .. ")")
end

function Bartering.isWaterShutOff()
    return getGameTime():getNightsSurvived() >= getSandboxOptions():getOptionByName("WaterShutModifier"):getValue()
end

function Bartering.clearEngineTarget(zombie)
    zombie:clearAggroList()
    zombie:setTarget(nil)
    zombie:setTargetSeenTime(0)
    zombie:setAttackedBy(nil)
    zombie:setAttackTargetSquare(nil)
end
