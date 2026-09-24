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
local BarteringTiming = require "BarteringTiming"
local print = require("BarteringPathTrace").log

Bartering.Registries = {
    Call = "BarteringCallRegistry",
    ReturningHome = "BarteringReturningHome",
    Live = "BarteringLive",
}

Bartering.MuzzleFlash = {
    r = 0.8,
    g = 0.8,
    b = 0.7,
    radius = 18,
    life = 1,
}

require "Inventory/BarteringValues"
require "Inventory/BarteringStock"
require "Inventory/BarteringSales"
require "Inventory/BarteringDeathbag"
require "BarteringPerk"
require "BarteringBarterers"
require "BarteringSync"
require "BarteringIdentity"
require "Map/BarteringRoadRoute"
require "BarteringCalls"
require "BarteringRelations"
require "BarteringHostility"
require "BarteringNamedPlaces"
require "BarteringQuests"
require "BarteringMuzzleFlash"

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

function Bartering.getLiveRecords()
    return ModData.getOrCreate(Bartering.Registries.Live)
end

function Bartering.getLiveRecord(bartererId)
    return Bartering.getLiveRecords()[bartererId]
end

function Bartering.markLiveDirty()
    Bartering.markGlobalDirty(Bartering.Registries.Live)
end

function Bartering.bumpLiveRev(record)
    record.rev = (record.rev or 0) + 1
    Bartering.markLiveDirty()
end

function Bartering.findOnlinePlayer(username)
    if not username then
        return nil
    end
    return BarteringAIUtils.findPlayer(function(player)
        return player:getUsername() == username
    end)
end

function Bartering.getBartererDepartureRemainingSeconds(bartererId)
    local record = Bartering.getLiveRecord(bartererId)
    if not record or not record.departureAtHours then
        return nil
    end
    return BarteringTiming.remainingRealSeconds(record.departureAtHours)
end

function Bartering.broadcastToClients(command, args)
    if isServer() then
        sendServerCommand("Bartering", command, args)
        return
    end
    triggerEvent("OnServerCommand", "Bartering", command, args)
end

function Bartering.removeZombieEverywhere(zombie)
    Bartering.clearBartererSighting(zombie:getVariableString("BartererId"))
    if isServer() then
        sendServerCommand("Bartering", "despawnZombie", { zid = zombie:getOnlineID() })
    elseif isClient() then
        sendClientCommand(getSpecificPlayer(0), "Bartering", "removeZombie", { zid = zombie:getOnlineID() })
    end
    zombie:removeFromWorld()
    zombie:removeFromSquare()
end

function Bartering.logBartererSound(zombie, kind, sound, result)
    if not Bartering.getSandboxBoolean("LogBartererSounds", false) then
        return
    end
    print(string.format("[Bartering][Sound] %s | kind=%s sound=%s result=%s action=%s pos=%.1f,%.1f,%.0f",
        tostring(zombie:getVariableString("BartererId")), kind, tostring(sound), tostring(result),
        tostring(zombie:getActionStateName()), zombie:getX(), zombie:getY(), zombie:getZ()))
end

function Bartering.showBartererShot(zombie, sound)
    Bartering.logBartererSound(zombie, "shot", sound, zombie:getEmitter():playSound(sound))
    Bartering.spawnMuzzleFlashLight(zombie)
    BarteringMuzzleFlash.Add(zombie)
end

function Bartering.playBartererShot(bartererId, zombie, sound)
    Bartering.showBartererShot(zombie, sound)
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), "Bartering", "relayShot", { bartererId = bartererId, sound = sound })
    elseif isServer() then
        sendServerCommand("Bartering", "bartererShot", { bartererId = bartererId, sound = sound })
    end
end

function Bartering.playBartererSound(zombie, sound)
    Bartering.logBartererSound(zombie, "emitter", sound, zombie:getEmitter():playSound(sound))
    local bartererId = zombie:getVariableString("BartererId")
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), "Bartering", "relaySound", { bartererId = bartererId, sound = sound })
    elseif isServer() then
        sendServerCommand("Bartering", "bartererSound", { bartererId = bartererId, sound = sound })
    end
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

function Bartering.ensureBartererHome(barterer)
    local state = Bartering.getBartererLifeState(barterer.id)
    if state.homeX ~= nil then
        barterer.x, barterer.y, barterer.z = state.homeX, state.homeY, state.homeZ
        return
    end

    local loc = Bartering.pickRandomListItem(barterer.spawnLocations)
    Bartering.setBartererHome(barterer, loc.x, loc.y, loc.z)
end

function Bartering.clearBartererHome(bartererId)
    local state = Bartering.getBartererLifeState(bartererId)
    state.homeX, state.homeY, state.homeZ = nil, nil, nil
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.isNearBartererHome(barterer, x, y, maxDistSq)
    return BarteringAIUtils.distanceSqToTile(x, y, barterer.x, barterer.y) <= maxDistSq
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
        Bartering.MuzzleFlash.r, Bartering.MuzzleFlash.g, Bartering.MuzzleFlash.b, Bartering.MuzzleFlash.radius,
        Bartering.MuzzleFlash.life))
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

function Bartering.isWalkieTalkie(item)
    local fullType = item:getFullType()
    return fullType ~= nil and string.find(fullType:lower(), "walkietalkie") ~= nil
end

function Bartering.hasWalkieTalkie(player)
    if Bartering.getSandboxBoolean("DebugMode", false) then
        return true
    end
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        if Bartering.isWalkieTalkie(items:get(i)) then
            return true
        end
    end
    return false
end

function Bartering.getPlayerTable(player, key)
    local modData = player:getModData()
    if not modData[key] then
        modData[key] = {}
    end
    return modData[key]
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

function Bartering.isBartererDeathHidden(bartererId)
    local lifeState = Bartering.getBartererLifeState(bartererId)
    if lifeState.permanentlyDead == true or lifeState.respawnAt ~= nil then
        if lifeState.deathWitnessed ~= true and lifeState.deathDiscovered ~= true then
            return true
        end
    end
    return false
end

local function getReturningHomeKnowledge(player)
    if not player then
        return nil
    end
    return Bartering.getPlayerTable(player, "BarteringReturningHomeKnowledge")
end

function Bartering.hasReturningHomeKnowledge(player, bartererId)
    local knowledge = getReturningHomeKnowledge(player)
    return knowledge ~= nil and knowledge[bartererId] == true
end

function Bartering.revealReturningHome(player, bartererId)
    local knowledge = getReturningHomeKnowledge(player)
    if not knowledge or knowledge[bartererId] then
        return
    end
    knowledge[bartererId] = true
    player:transmitModData()
end

function Bartering.clearReturningHomeKnowledge(bartererId)
    BarteringAIUtils.forEachPlayer(function(player)
        local knowledge = getReturningHomeKnowledge(player)
        if knowledge and knowledge[bartererId] then
            knowledge[bartererId] = nil
            player:transmitModData()
        end
    end)
end

function Bartering.getBartererReturningHomeRemainingHours(bartererId, player)
    if not Bartering.hasReturningHomeKnowledge(player, bartererId) then
        return 0
    end
    return BarteringTiming.remainingHours(Bartering.getBartererLifeState(bartererId).returningHomeAt)
end

function Bartering.getMetBarterers(player)
    return Bartering.getPlayerTable(player, "BarteringMetBarterers")
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

Bartering.TrackedBarterers = Bartering.TrackedBarterers or {}

local STATUS_RANGE_SQ = 10 * 10
local INTEL_HEARTBEAT_UPDATES = 120
local LIVE_SNAPSHOT_WINDOW_MS = 2000

local COMBAT_STATES = {
    Retreat = true,
    DefendPistol = true,
    DefendKnife = true,
}

local intelHeartbeat = {}
local intentState = {}

local function getBartererIntelStore()
    local player = getSpecificPlayer(0)
    if not player then
        return nil, nil
    end
    return Bartering.getPlayerTable(player, "BarteringBartererIntel"), player
end

function Bartering.getBartererIntel(bartererId)
    local store = getBartererIntelStore()
    return store and store[bartererId] or nil
end

function Bartering.getLiveBartererSnapshot(bartererId)
    local snapshot = Bartering.TrackedBarterers[bartererId]
    if not snapshot or BarteringTiming.now() - snapshot.lastSeenAtMs > LIVE_SNAPSHOT_WINDOW_MS then
        return nil
    end
    return snapshot
end

function Bartering.getBartererSnapshot(bartererId)
    return Bartering.TrackedBarterers[bartererId] or Bartering.getBartererIntel(bartererId)
end

local function clearBartererIntel(bartererId)
    local store, player = getBartererIntelStore()
    if not store or not store[bartererId] then
        return
    end
    store[bartererId] = nil
    intelHeartbeat[bartererId] = nil
    player:transmitModData()
end

function Bartering.clearBartererSighting(bartererId)
    Bartering.TrackedBarterers[bartererId] = nil
    intentState[bartererId] = nil
    clearBartererIntel(bartererId)
end

local function withinStatusRange(zombie)
    local player = getSpecificPlayer(0)
    if not player then
        return false
    end
    return BarteringAIUtils.distanceSqBetween(player, zombie) <= STATUS_RANGE_SQ
end

local function copySnapshot(snapshot)
    return {
        x = snapshot.x,
        y = snapshot.y,
        state = snapshot.state,
        lastSeenAtMs = snapshot.lastSeenAtMs,
        seenAtWorldHours = snapshot.seenAtWorldHours,
        climbing = snapshot.climbing,
        calledIn = snapshot.calledIn,
        departureAtHours = snapshot.departureAtHours,
        name = snapshot.name,
    }
end

local function trackBartererPosition(zombie, bartererId, bartererState)
    local snapshot = Bartering.TrackedBarterers[bartererId]
    if not snapshot then
        snapshot = {}
        Bartering.TrackedBarterers[bartererId] = snapshot
    end
    snapshot.x = zombie:getX()
    snapshot.y = zombie:getY()
    snapshot.state = bartererState
    snapshot.lastSeenAtMs = BarteringTiming.now()
    snapshot.seenAtWorldHours = getGameTime():getWorldAgeHours()
    snapshot.climbing = zombie:getVariableBoolean("BartererClimbing") == true
    snapshot.calledIn = zombie:getVariableBoolean("BartererCalledIn") == true
    local record = Bartering.getLiveRecord(bartererId)
    snapshot.departureAtHours = record and record.departureAtHours or nil
    snapshot.name = Bartering.getBartererDisplayName(bartererId)

    local store, player = getBartererIntelStore()
    if not store then
        return
    end

    local stored = store[bartererId]
    intelHeartbeat[bartererId] = (intelHeartbeat[bartererId] or 0) - 1
    if stored and stored.state == bartererState and intelHeartbeat[bartererId] > 0 then
        return
    end

    intelHeartbeat[bartererId] = INTEL_HEARTBEAT_UPDATES
    store[bartererId] = copySnapshot(snapshot)
    player:transmitModData()
end

function Bartering.recordBartererSighting(zombie, bartererState)
    local bartererId = zombie:getVariableString("BartererId")
    if not COMBAT_STATES[bartererState] then
        intentState[bartererId] = bartererState
    end

    local inStatusRange = withinStatusRange(zombie)
    if not inStatusRange and not zombie:getVariableBoolean("BartererCalledIn") then
        return
    end

    local trackedState = bartererState
    if COMBAT_STATES[bartererState]
        and not inStatusRange
        and not Bartering.isBartererAwayFromHome(bartererId) then
        trackedState = intentState[bartererId] or "Approach"
    end
    trackBartererPosition(zombie, bartererId, trackedState)
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
