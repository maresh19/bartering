BarteringAI = BarteringAI or {}

local events = _G["Events"]
local getCell = _G["getCell"]
local ZombieIdleState = _G["ZombieIdleState"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringAICombat = require "BarteringAICombat"
local BarteringPathing = require "BarteringPathing"
local BarteringRetreat = require "BarteringRetreat"
local BarteringCalls = require "BarteringCalls"
local BarteringPathTrace = require "BarteringPathTrace"
local BarterSpawn = require "BarterSpawn"
local getClosestNearbyPlayer
local pathing
local retreat
local combat
local calls
local spawn
local KNIFE_REEQUIP_DELAY_MS = 3000

local loggingEntry = nil

local function logBartererServerDebug(zombie, reason, state)
    local bartererId = zombie:getVariableString("BartererId")
    local idSource = "var"
    if (not bartererId or bartererId == "") and loggingEntry then
        bartererId = loggingEntry.bartererId
        idSource = "entry"
    end
    local name = Bartering.getBartererDisplayName(bartererId)
    local primary = zombie:getPrimaryHandItem()
    print(string.format(
        "[Bartering][ServerDebug] %s [%s/%s] | %s | state=%s action=%s useless=%s pathing=%s hasPath=%s speed=%s bump=%s weapon=%s pos=%.2f,%.2f,%.2f",
        tostring(name),
        tostring(bartererId),
        idSource,
        tostring(reason),
        tostring(state),
        tostring(zombie:getActionStateName()),
        tostring(zombie:isUseless()),
        tostring(zombie:isPathing()),
        tostring(zombie:hasPath()),
        tostring(zombie:getVariableString("MovementSpeed")),
        tostring(zombie:getBumpType()),
        tostring(primary and primary:getType() or "none"),
        zombie:getX(),
        zombie:getY(),
        zombie:getZ()
    ))
end

BarteringAI.barterers = BarteringAI.barterers or {}
BarteringAI.residentsInitialized = BarteringAI.residentsInitialized or false

local function resolvePlayerFromRecord(record)
    local targetOnlineId = tonumber(record and record.BartererMaster)
    local targetUsername = record and record.BartererMasterName or nil
    local found = nil
    BarteringAIUtils.forEachPlayer(function(player)
        if targetOnlineId and player.getOnlineID and player:getOnlineID() == targetOnlineId then
            found = player
            return true
        end
        if targetUsername and player:getUsername() == targetUsername then
            found = player
            return true
        end
    end)
    return found or BarteringAIUtils.getAnyAvailablePlayer()
end

local function recordBartererDeath(entry)
    local cause = combat.getDeathCause(entry)
    spawn.deprovisionBarterer(entry.zombie)
    local permanentlyDead = spawn.markBartererDeath(entry.bartererId, cause)
    calls.setBartererAvailability(entry.master, entry.bartererId, false, permanentlyDead or nil)
    calls.clearActiveCalledInEntry(entry)
    calls.clearPendingCall(entry.bartererId)
    calls.setBartererETA(entry.master, entry.bartererId, 0, false)
    Bartering.setRegistryRecord(Bartering.Registries.Call, entry.bartererId, nil)
    print(string.format(
        "[Bartering][ServerDebug] barterer %s died cause=%s permanentlyDead=%s homeResident=%s"
        .. " health=%.3f state=%s action=%s worldAge=%.2f pos=%.2f,%.2f,%.2f",
        tostring(entry.bartererId), tostring(cause), tostring(permanentlyDead),
        tostring(entry.homeResident == true), entry.zombie:getHealth(),
        tostring(entry.zombie:getVariableString("BartererState")),
        tostring(entry.zombie:getActionStateName()),
        getGameTime():getWorldAgeHours(),
        entry.zombie:getX(), entry.zombie:getY(), entry.zombie:getZ()))
end

local function manageBartererActionState(entry, zombie)
    local actionState = zombie:getActionStateName()
    local bartererState = zombie:getVariableString("BartererState") or ""
    local isDefendState = bartererState == "DefendKnife" or bartererState == "DefendPistol" or entry.combatTask ~= nil
    local isTravelState = bartererState == "Return" or bartererState == "Retreat"

    local function clearTasksOnly()
        combat.clearCombatTask(entry)
    end

    local function suppressAndClearTasks()
        BarteringAIUtils.suppressZombieCombat(zombie)
        clearTasksOnly()
    end

    local function idleAndSuppress()
        zombie:changeState(ZombieIdleState.instance())
        suppressAndClearTasks()
        return true
    end

    if actionState == "pathfind" then
        return false
    end

    if BarteringAIUtils.isDownedActionState(actionState) or BarteringAIUtils.STAGGER_ACTION_STATES[actionState] then
        clearTasksOnly()
        return false
    end

    if actionState == "turnalerted" then
        if isTravelState then
            return idleAndSuppress()
        end
        if bartererState == "Approach" then
            suppressAndClearTasks()
            return true
        end
        if isDefendState then
            return true
        end
        return idleAndSuppress()
    end

    if actionState == "lunge" then
        zombie:setUseless(true)
        zombie:clearAggroList()
        zombie:setTarget(nil)
        return true
    end

    if BarteringAIUtils.isHostileActionState(actionState) then
        if isTravelState or not isDefendState then
            return idleAndSuppress()
        end
        BarteringAIUtils.suppressZombieCombat(zombie)
        return true
    end

    Bartering.clearEngineTarget(zombie)
    zombie:setTargetSeenTime(0)
    zombie:setUseless(true)
    return true
end

getClosestNearbyPlayer = function(zombie, maxDistanceSquared)
    local closestPlayer = nil
    local closestDistance = nil
    BarteringAIUtils.forEachPlayer(function(player)
        local distance = BarteringAIUtils.distanceSqBetween(player, zombie)
        if distance <= maxDistanceSquared and (not closestDistance or distance < closestDistance) then
            closestPlayer = player
            closestDistance = distance
        end
    end)
    return closestPlayer, closestDistance
end

combat = BarteringAICombat.new({
    state = BarteringAI,
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
})

pathing = BarteringPathing.new({
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
})

retreat = BarteringRetreat.new({
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
})

local spawnConfig = {
    state = BarteringAI,
    combat = combat,
    findSpawnLocation = pathing.findSpawnLocation,
    idleTurnIntervalTicks = pathing.IDLE_TURN_INTERVAL_TICKS,
    logBartererServerDebug = logBartererServerDebug,
}
spawn = BarterSpawn.new(spawnConfig)

calls = BarteringCalls.new({
    state = BarteringAI,
    resolvePlayerFromRecord = resolvePlayerFromRecord,
    findSpawnLocation = pathing.findSpawnLocation,
    spawnBarterer = spawn.spawnBarterer,
    createBartererZombie = spawn.createBartererZombie,
    trackBarterer = spawn.trackBarterer,
    despawnBarterer = spawn.despawnBarterer,
    despawnZombie = spawn.despawnZombie,
    hasTrackedBarterer = spawn.hasTrackedBarterer,
    clearBartererDeath = spawn.clearBartererDeath,
    clearCombatTask = combat.clearCombatTask,
})
spawnConfig.calls = calls

local function dropBartererLoot(entry)
    local stock = Bartering.getBartererStock(entry.bartererId)
    local bag = Bartering.getBartererBag(entry.zombie)
    if bag then
        local bagInventory = bag:getInventory()
        for _, itemName in ipairs(stock) do
            bagInventory:AddItem(itemName)
        end
    end
    Bartering.clearBartererStock(entry.bartererId)
end

local function finalizeBartererDeath(entry)
    if entry.deathFinalized then
        return
    end
    entry.deathFinalized = true
    dropBartererLoot(entry)
    recordBartererDeath(entry)
    Bartering.Relations.resetAll(entry.bartererId)
end

local BANDAGE_SAFE_TICKS = 180
local BANDAGE_ANIM_TIMEOUT_TICKS = 240

local function updateBandage(entry, zombie)
    local health = zombie:getHealth()
    if entry.bandageLastHealth and health < entry.bandageLastHealth then
        entry.needsBandage = true
    end
    entry.bandageLastHealth = health

    if not entry.needsBandage then
        entry.bandageSafeTicks = 0
        return
    end

    local atPost = zombie:getVariableString("BartererState") == "Waiting"
    local safe = atPost and not entry.combatTask and not entry.threatNearby and not entry.swarmed

    if entry.bandaging then
        if not safe then
            entry.bandaging = false
            entry.bandageSafeTicks = 0
            zombie:setBumpType("")
            logBartererServerDebug(zombie, "bandage interrupted; still hurt", "Waiting")
            return
        end

        entry.bandageTicks = entry.bandageTicks + 1
        if zombie:getVariableBoolean("BumpAnimFinished")
            or entry.bandageTicks >= BANDAGE_ANIM_TIMEOUT_TICKS then
            entry.bandaging = false
            entry.needsBandage = false
            entry.bandageSafeTicks = 0
            zombie:setBumpType("")
            logBartererServerDebug(zombie, "bandage applied", "Waiting")
        end
        return
    end

    if not safe then
        entry.bandageSafeTicks = 0
        return
    end

    entry.bandageSafeTicks = (entry.bandageSafeTicks or 0) + 1
    if entry.bandageSafeTicks < BANDAGE_SAFE_TICKS then
        return
    end

    entry.bandaging = true
    entry.bandageTicks = 0
    zombie:setVariable("BumpAnimFinished", false)
    zombie:setBumpType("Bandage")
    logBartererServerDebug(zombie, "applying bandage", "Waiting")
end

local function updateBarterer(entry)
    loggingEntry = entry
    local zombie = entry.zombie
    if zombie:getHealth() <= 0 and not zombie:isDead() then
        logBartererServerDebug(zombie, string.format(
            "health depleted (%.3f); converting to corpse", zombie:getHealth()), "Dying")
        zombie:setUseless(false)
        zombie:setAttackedBy(getCell():getFakeZombieForHit())
        zombie:becomeCorpse()
    end
    if zombie:isDead() then
        finalizeBartererDeath(entry)
        BarteringPathTrace.forget(zombie)
        return false
    end

    if not zombie:getSquare() then
        if entry.returningAfterMeeting then
            BarteringPathTrace.aiStop(zombie, "entry.noSquare.expiring")
            return calls.handleExpiry(entry, zombie)
        end
        logBartererServerDebug(zombie, "removed from world; dropping entry", "Removed")
        spawn.noteLeftover(entry.bartererId)
        BarteringPathTrace.forget(zombie)
        return false
    end

    if not getClosestNearbyPlayer(zombie, BarterSpawn.DORMANT_DISTANCE_SQ) then
        if entry.returningAfterMeeting then
            BarteringPathTrace.aiStop(zombie, "entry.dormant.expiring")
            return calls.handleExpiry(entry, zombie)
        end
        spawn.unloadEntry(entry, zombie)
        BarteringPathTrace.forget(zombie)
        return false
    end

    if not entry.homeResident and entry.master and entry.master:isDead() then
        calls.clearActiveCalledInEntry(entry)
        calls.clearPendingCall(entry.bartererId)
        calls.setBartererETA(entry.master, entry.bartererId, 0, false)
        calls.setBartererAvailability(entry.master, entry.bartererId, true)
        Bartering.setRegistryRecord(Bartering.Registries.Call, entry.bartererId, nil)
        BarteringPathTrace.aiStop(zombie, "entry.masterDead.expiring")
        return calls.handleExpiry(entry, zombie)
    end

    if entry.shutOff then
        zombie:setZombiesDontAttack(false)
        Bartering.clearEngineTarget(zombie)
        calls.persistActiveCalledInEntry(entry, zombie)
        BarteringPathTrace.aiStop(zombie, "entry.shutOff")
        return true
    end

    local bartererState = zombie:getVariableString("BartererState") or ""

    calls.persistActiveCalledInEntry(entry, zombie)

    if calls.shouldExpire(entry) then
        BarteringPathTrace.aiStop(zombie, "entry.callExpired")
        return calls.handleExpiry(entry, zombie)
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        if not entry.loggedClimbing then
            entry.loggedClimbing = true
            logBartererServerDebug(zombie, "climbing; holding all other logic", "Climb")
        end
        BarteringAIUtils.suppressZombieCombat(zombie)
        combat.clearCombatTask(entry)
        BarteringPathTrace.aiStop(zombie, "climbing")
        return true
    end
    entry.loggedClimbing = nil

    local fighting = bartererState == "DefendPistol" or bartererState == "DefendKnife"
    local nearestThreatSq
    nearestThreatSq, entry.meleeInFront, entry.meleeBehind = combat.scanThreats(zombie)
    entry.swarmed = retreat.isSwarmed(entry.meleeInFront + entry.meleeBehind)
    entry.threatNearby = nearestThreatSq ~= nil and nearestThreatSq <= combat.THREAT_SPRINT_DISTANCE_SQ
    if entry.threatNearby then
        entry.aggroScanTicks = (entry.aggroScanTicks or 0) - 1
        if entry.aggroScanTicks <= 0 then
            entry.aggroScanTicks = combat.BARTERER_AGGRO_SCAN_INTERVAL_TICKS
            combat.updateZombieTargetPriorityForBarterer(zombie)
        end
        if fighting then
            combat.updateZombieBitesOnBarterer(entry, zombie)
        end
    elseif entry.biteStates then
        combat.resetBiteStates(entry)
    end

    pathing.applyWalkType(entry, zombie, bartererState)

    if bartererState == "Return" and not entry.combatTask
        and zombie:getBumpType() == ""
        and (not entry.combatEndedAt or getTimeInMillis() - entry.combatEndedAt >= KNIFE_REEQUIP_DELAY_MS)
        and zombie:getVariableString("BartererWeapon") ~= "Knife" then
        combat.equipWeapon(zombie, entry.knife, "Knife")
    end

    local isApproaching = not entry.homeResident and not entry.hasArrived
    local isReturning = entry.returningAfterMeeting == true

    if isReturning then
        combat.clearCombatTask(entry)
    elseif entry.retreatActive or entry.retreatForced or entry.swarmed or entry.meleeBehind > 0 or not isApproaching then
        retreat.tryStartRetreat(entry, zombie)
        if entry.retreatActive then
            combat.clearCombatTask(entry)
            if retreat.updateRetreat(entry, zombie) then
                BarteringPathTrace.aiStop(zombie, "retreat.active")
                return true
            end
        end
    end

    if not manageBartererActionState(entry, zombie) then
        BarteringPathTrace.aiStop(zombie, "actionState." .. tostring(zombie:getActionStateName()))
        return true
    end

    if isApproaching then
        pathing.updateApproachCrowding(entry, zombie)
    end

    if not isReturning and entry.combatTask and combat.processCombatTask(entry, zombie) then
        BarteringPathTrace.aiStop(zombie, "combat.task")
        return true
    end

    if isApproaching then
        local threatWithinFightRange = nearestThreatSq ~= nil and nearestThreatSq <= BarteringAIUtils.APPROACH_FIGHT_RADIUS_SQ
        if not entry.retreatActive and (entry.swarmed or threatWithinFightRange
            or (entry.approachCrowded and entry.withinApproachFightRange)) then
            local threat, distance = combat.getClosestThreat(zombie, entry.hostilePlayer)
            if threat then
                combat.defend(entry, zombie, threat, distance)
                BarteringPathTrace.aiStop(zombie, "combat.defend.approachThreat")
                return true
            end
        end
    elseif not isReturning then
        local hostilePlayer, hostileDistance = combat.getHostilePlayer(entry, zombie)
        if hostilePlayer then
            combat.defend(entry, zombie, hostilePlayer, hostileDistance)
            BarteringPathTrace.aiStop(zombie, "combat.defend.hostilePlayer")
            return true
        end

        local threat, distance = combat.getClosestThreat(zombie, entry.hostilePlayer)
        if threat then
            combat.defend(entry, zombie, threat, distance)
            BarteringPathTrace.aiStop(zombie, "combat.defend.threat")
            return true
        end
    end

    combat.clearCombatTask(entry)
    BarteringAIUtils.resetPassiveState(zombie)
    updateBandage(entry, zombie)
    pathing.updateMovement(entry, zombie)

    return true
end

local function updateBarterers()
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        if not spawn.ownsZombie(entry) then
            spawn.releaseLostEntry(i)
        elseif not updateBarterer(entry) then
            spawn.untrackEntry(i)
        end
    end
end

function BarteringAI.syncBartererStock(bartererId, player)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, bartererId)
    if entry and not entry.zombie:isDead() then
        Bartering.syncBartererStockToContainer(Bartering.getBartererBag(entry.zombie), bartererId, player or entry.master)
    end
end

function BarteringAI.debugDespawnAll(player)
    local removed = #BarteringAI.barterers
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        local master = entry.master or player
        calls.clearActiveCalledInEntry(entry)
        calls.clearPendingCall(entry.bartererId)
        calls.setBartererAvailability(master, entry.bartererId, true)
        calls.setBartererETA(master, entry.bartererId, 0, false)
        Bartering.setRegistryRecord(Bartering.Registries.Call, entry.bartererId, nil)
        spawn.despawnBartererEntry(i)
    end
    print(string.format("[Bartering][ServerDebug] debug despawn all | removed=%d", removed))
end

function BarteringAI.debugKillBarterer(player, bartererId)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, bartererId)
    if entry then
        entry.zombie:setHealth(0)
        print("[Bartering][ServerDebug] debug killed barterer " .. tostring(bartererId))
    end
end

function BarteringAI.debugZombifyBarterer(player, bartererId)
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        if entry.bartererId == bartererId then
            local zombie = entry.zombie
            spawn.untrackEntry(i)
            spawn.deprovisionBarterer(zombie)
            spawn.markBartererDeath(bartererId, "zombie")
            calls.clearActiveCalledInEntry(entry)
            calls.clearPendingCall(bartererId)
            calls.setBartererAvailability(entry.master or player, bartererId, false)
            Bartering.setRegistryRecord(Bartering.Registries.Call, bartererId, nil)
            zombie:setZombiesDontAttack(false)
            print("[Bartering][ServerDebug] zombified barterer " .. tostring(bartererId))
            return
        end
    end
end

function BarteringAI.debugHurtBarterer(player, bartererId)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, bartererId)
    if entry then
        entry.zombie:setHealth(math.max(0.1, entry.zombie:getHealth() - 30))
        entry.needsBandage = true
        print("[Bartering][ServerDebug] hurt barterer " .. tostring(bartererId) .. " health=" .. tostring(entry.zombie:getHealth()))
    end
end

function BarteringAI.debugBandageBarterer(player, bartererId)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, bartererId)
    if entry then
        entry.zombie:setVariable("BumpAnimFinished", false)
        entry.zombie:setBumpType("Bandage")
        print("[Bartering][ServerDebug] triggered bandage animation for " .. tostring(bartererId) .. " state=" .. tostring(entry.zombie:getActionStateName()))
    end
end

function BarteringAI.debugShutOffBarterer(player, bartererId)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, bartererId)
    if entry then
        entry.shutOff = true
        combat.clearCombatTask(entry)
        entry.zombie:setPrimaryHandItem(nil)
        entry.zombie:setVariable("BartererWeapon", "")
        print("[Bartering][ServerDebug] shut off barterer " .. tostring(bartererId))
    end
end

BarteringAI.spawnBarterer = spawn.spawnBarterer
BarteringAI.attackedBy = combat.attackedBy
BarteringAI.shovedBy = combat.shovedBy
BarteringAI.callBarterer = calls.callBarterer
BarteringAI.updateBartererCallLocation = calls.updateBartererCallLocation
BarteringAI.debugCallBarterer = calls.debugCallBarterer
BarteringAI.cancelBartererMeeting = calls.cancelBartererMeeting
BarteringAI.sendBartererHome = calls.sendBartererHome
BarteringAI.debugSpawnBarterer = calls.debugSpawnBarterer
BarteringAI.debugSpawnBartererAt = calls.debugSpawnBartererAt

local function onBartererDeath(zombie)
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        if entry.zombie == zombie then
            finalizeBartererDeath(entry)
            spawn.untrackEntry(i)
        end
    end
end

events.OnZombieDead.Add(onBartererDeath)
events.OnTick.Add(spawn.bootstrap)
events.OnTick.Add(updateBarterers)
events.OnTick.Add(spawn.updateSpawns)
events.OnTick.Add(function() calls.processCalledInCleanups() end)
events.OnTick.Add(function() calls.updatePendingCalls() end)
events.OnServerStarted.Add(spawn.resetBootstrap)

return BarteringAI
