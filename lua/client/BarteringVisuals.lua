local events = _G["Events"]
local instanceof = _G["instanceof"]
local sendClientCommand = _G["sendClientCommand"]
local getSpecificPlayer = _G["getSpecificPlayer"]

require "Bartering"
local BarteringAIUtils = require "BarteringAIUtils"

local debugBartererState = {}

local function getBartererDebugKey(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    if bartererId and bartererId ~= "" then
        return bartererId
    end

    return tostring(zombie)
end

local function logBartererDebug(zombie, reason, bartererState, actionState)
    local name = Bartering.getBartererDisplayName(zombie:getVariableString("BartererId"))
    print(string.format(
        "[Bartering][ClientDebug] %s | %s | state=%s action=%s curState=%s useless=%s walk=%s bump=%s bumpDone=%s pos=%.2f,%.2f,%.2f",
        tostring(name),
        tostring(reason),
        tostring(bartererState),
        tostring(actionState),
        tostring(zombie:getCurrentStateName()),
        tostring(zombie:isUseless()),
        tostring(zombie:getVariableString("BartererWalkType")),
        tostring(zombie:getBumpType()),
        tostring(zombie:getVariableBoolean("BumpAnimFinished")),
        zombie:getX(),
        zombie:getY(),
        zombie:getZ()
    ))
end

Bartering.TrackedBarterers = Bartering.TrackedBarterers or {}

local STATUS_RANGE_SQ = 10 * 10
local INTEL_HEARTBEAT_UPDATES = 120

local intelHeartbeat = {}
local visualsSeen = {}

local function getBartererIntelStore()
    local player = getSpecificPlayer(0)
    if not player then
        return nil, nil
    end
    local modData = player:getModData()
    if not modData.BarteringBartererIntel then
        modData.BarteringBartererIntel = {}
    end
    return modData.BarteringBartererIntel, player
end

function Bartering.getBartererIntel(bartererId)
    local store = getBartererIntelStore()
    return store and store[bartererId] or nil
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

local function isWithinStatusRange(zombie)
    if zombie:getVariableBoolean("BartererCalledIn") then
        return true
    end
    local player = getSpecificPlayer(0)
    if not player then
        return false
    end
    return BarteringAIUtils.distanceSqBetween(player, zombie) <= STATUS_RANGE_SQ
end

local function trackBartererPosition(zombie, bartererState)
    local bartererId = zombie:getVariableString("BartererId")
    local key = (bartererId and bartererId ~= "") and bartererId or tostring(zombie)
    local snapshot = {
        x = zombie:getX(),
        y = zombie:getY(),
        state = bartererState,
        seenAtWorldHours = getGameTime():getWorldAgeHours(),
        climbing = zombie:getVariableBoolean("BartererClimbing") == true,
        departureAtMs = tonumber(zombie:getVariableString("BartererDepartureAtMs")) or 0,
        name = Bartering.getBartererDisplayName(bartererId),
    }
    Bartering.TrackedBarterers[key] = snapshot

    if not bartererId or bartererId == "" then
        return
    end

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
    store[bartererId] = snapshot
    player:transmitModData()
end

local function silenceZombieSounds(zombie)
    zombie:getEmitter():stopSoundByName("MaleZombieCombined")
    zombie:getEmitter():stopSoundByName("FemaleZombieCombined")
end

local function ensureCombatWeaponVisuals(zombie, bartererState)
    if bartererState ~= "DefendPistol" and bartererState ~= "DefendKnife" then
        return
    end

    local bartererId = zombie:getVariableString("BartererId")
    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return
    end

    local gun = Bartering.getBartererWeapon(bartererId)
    local isRanged = bartererState == "DefendPistol"
    local expectedItemType = isRanged and gun.item or barterer.equipment.knife
    local expectedWeapon = isRanged and gun.weaponType or "Knife"
    local expectedPrimaryType = isRanged and gun.primaryType or "onehanded"

    if zombie:getVariableString("BartererWeapon") ~= expectedWeapon then
        zombie:setVariable("BartererWeapon", expectedWeapon)
    end
    if zombie:getVariableString("BartererPrimaryType") ~= expectedPrimaryType then
        zombie:setVariable("BartererPrimaryType", expectedPrimaryType)
    end

    local primary = zombie:getPrimaryHandItem()
    if primary and primary:getFullType() == expectedItemType then
        return
    end

    local desired = zombie:getInventory():getFirstTypeRecurse(expectedItemType)
    if desired then
        zombie:setPrimaryHandItem(desired)
    end
end

local function updateBartererVisuals(zombie)
    if not zombie:getVariableBoolean("Barterer") then
        return
    end

    local debugKey = getBartererDebugKey(zombie)
    if zombie:isDead() or zombie:getHealth() <= 0 then
        local deadId = zombie:getVariableString("BartererId") or ""
        debugBartererState[debugKey] = nil
        Bartering.TrackedBarterers[deadId] = nil
        visualsSeen[deadId] = nil
        clearBartererIntel(deadId)
        return
    end

    local debugEntry = debugBartererState[debugKey]
    if not debugEntry then
        debugEntry = {}
        debugBartererState[debugKey] = debugEntry
    end

    local bartererState = zombie:getVariableString("BartererState") or ""
    local isReturnState = bartererState == "Return"
    local actionState = zombie:getActionStateName()
    local muzzleFlashAt = tonumber(zombie:getVariableString("BartererMuzzleFlashAt")) or 0

    silenceZombieSounds(zombie)
    zombie:setNoTeeth(true)
    zombie:setVariable("NoLungeAttack", true)
    zombie:setZombiesDontAttack(true)
    Bartering.clearEngineTarget(zombie)
    zombie:setEatBodyTarget(nil, false)
    local activeWalkType = zombie:getVariableString("BartererWalkType") or "BartererWalk"
    zombie:setWalkType(activeWalkType)
    zombie:setSpeedMod(1)
    ensureCombatWeaponVisuals(zombie, bartererState)

    local bartererId = zombie:getVariableString("BartererId") or ""
    if not visualsSeen[bartererId] then
        visualsSeen[bartererId] = true
        zombie:setVariable("BartererVisualsApplied", false)
    end

    if isWithinStatusRange(zombie) then
        trackBartererPosition(zombie, bartererState)
    end

    if debugEntry.lastBartererState ~= bartererState then
        logBartererDebug(zombie, "state changed", bartererState, actionState)
        debugEntry.lastBartererState = bartererState
    end
    if debugEntry.lastActionState ~= actionState then
        logBartererDebug(zombie, "action changed", bartererState, actionState)
        debugEntry.lastActionState = actionState
    end
    if isReturnState and actionState ~= "pathfind" and actionState ~= "walktoward" and actionState ~= "idle" then
        if debugEntry.lastUnexpectedActionState ~= actionState then
            logBartererDebug(zombie, "unexpected moving action", bartererState, actionState)
            debugEntry.lastUnexpectedActionState = actionState
        end
    else
        debugEntry.lastUnexpectedActionState = nil
    end

    if muzzleFlashAt > 0 and debugEntry.lastMuzzleFlashAt ~= muzzleFlashAt then
        debugEntry.lastMuzzleFlashAt = muzzleFlashAt
        Bartering.spawnMuzzleFlashLight(zombie)
    end

    if not zombie:getVariableBoolean("BartererVisualsApplied") then
        Bartering.applyBartererVisuals(zombie)
    end
end

local function onHitZombie(zombie, attacker)
    if not zombie:getVariableBoolean("Barterer") then
        return
    end

    silenceZombieSounds(zombie)
    if instanceof(attacker, "IsoPlayer") then
        local weapon = attacker:getPrimaryHandItem()
        local isShove = not weapon or weapon:getType() == "BareHands"
        if isShove then
            sendClientCommand(attacker, "Bartering", "shovedBarterer", {
                id = zombie:getVariableString("BartererId"),
            })
        else
            sendClientCommand(attacker, "Bartering", "attackedBarterer", {
                id = zombie:getVariableString("BartererId"),
            })
        end
    end
end

events.OnZombieUpdate.Add(updateBartererVisuals)
events.OnHitZombie.Add(onHitZombie)
