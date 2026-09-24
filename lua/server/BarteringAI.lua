BarteringAI = BarteringAI or {}

local events = _G["Events"]
local getCell = _G["getCell"]
local ZombieIdleState = _G["ZombieIdleState"]
local sendClientCommand = _G["sendClientCommand"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local instanceItem = _G["instanceItem"]
local instanceof = _G["instanceof"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringAICombat = require "BarteringAICombat"
local BarteringPathing = require "Movement/BarteringPathing"
local BarteringRetreat = require "Movement/BarteringRetreat"
local BarteringTasks = require "Movement/BarteringTasks"
local BarteringCalls = require "BarteringCalls"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringTiming = require "BarteringTiming"
local BarterSpawn = require "BarterSpawn"
local BarteringHire = require "BarteringHire"
local BarteringFollow = require "Movement/BarteringFollow"
local BarteringDialogue = require "BarteringDialogue"
local BarteringIntercept = require "Movement/BarteringIntercept"

local KNIFE_REEQUIP_DELAY_MS = 3000
local REPORT_INTERVAL_TICKS = 20
local PULSE_STALE_MS = 2000
local DEATH_FALLBACK_MS = 3000
local PLAYER_KILL_CAUSE_TIMEOUT_MS = 15000
local WITNESS_DISTANCE_SQ = 15 * 15
local CORPSE_SEARCH_RADIUS = 2
local BANDAGE_SAFE_TICKS = 180
local BANDAGE_ANIM_TIMEOUT_TICKS = 240
local DRESS_DELAY_MS = 2000
local DRESS_ANIM_TIMEOUT_TICKS = 240

BarteringAI.barterers = BarteringAI.barterers or {}
BarteringAI.serverZombies = BarteringAI.serverZombies or {}
BarteringAI.serverZombieIds = BarteringAI.serverZombieIds or {}
BarteringAI.serverItems = BarteringAI.serverItems or {}
BarteringAI.serverState = BarteringAI.serverState or {}
BarteringAI.residentsInitialized = BarteringAI.residentsInitialized or false

local loggingEntry = nil
local zidIndex = {}

local function logBartererServerDebug(zombie, reason, state)
    local bartererId = zombie:getVariableString("BartererId")
    if (not bartererId or bartererId == "") and loggingEntry then
        bartererId = loggingEntry.bartererId
    end
    local primary = zombie:getPrimaryHandItem()
    print(string.format(
        "[Bartering][ServerDebug] %s [%s] | %s | state=%s action=%s useless=%s pathing=%s hasPath=%s speed=%s bump=%s weapon=%s pos=%.2f,%.2f,%.2f",
        tostring(Bartering.getBartererDisplayName(bartererId)),
        tostring(bartererId),
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

function BarteringAI.serverStateFor(bartererId)
    local st = BarteringAI.serverState[bartererId]
    if not st then
        st = {}
        BarteringAI.serverState[bartererId] = st
    end
    return st
end

local function getClosestNearbyPlayer(zombie, maxDistanceSquared)
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

local function resolvePlayerFromRecord(record)
    return Bartering.findOnlinePlayer(record.playerName) or BarteringAIUtils.getAnyAvailablePlayer()
end

local function report(entry, kind, fields)
    local args = fields or {}
    args.bartererId = entry.bartererId
    args.seq = entry.seq
    args.kind = kind
    sendClientCommand(getSpecificPlayer(0), "Bartering", "bartererReport", args)
end

local function relayZombieHit(attacker, target, weapon, damage, isRanged)
    sendClientCommand(getSpecificPlayer(0), "Bartering", "relayZombieHit", {
        bartererId = attacker:getVariableString("BartererId"),
        zid = target:getOnlineID(),
        weapon = weapon:getFullType(),
        damage = damage,
        ranged = isRanged == true,
    })
end

local function relayPlayerHit(attacker, target, weapon, damage, isRanged)
    sendClientCommand(getSpecificPlayer(0), "Bartering", "relayPlayerHit", {
        bartererId = attacker:getVariableString("BartererId"),
        username = target:getUsername(),
        weapon = weapon:getFullType(),
        damage = damage,
        ranged = isRanged == true,
    })
end

local combat = BarteringAICombat.new({
    state = BarteringAI,
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
    relayZombieHit = relayZombieHit,
    relayPlayerHit = relayPlayerHit,
    report = report,
})

local pathing = BarteringPathing.new({
    state = BarteringAI,
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
    equipWeapon = combat.equipWeapon,
    report = report,
})

local retreat = BarteringRetreat.new({
    getClosestNearbyPlayer = getClosestNearbyPlayer,
    logBartererServerDebug = logBartererServerDebug,
})

local function applyRecord(entry, record)
    local wasReturning = entry.returningAfterMeeting == true
    entry.homeResident = record.homeResident == true
    entry.hasArrived = record.hasArrived == true
    entry.returningAfterMeeting = record.returningAfterMeeting == true
    entry.returningToPost = record.returningToPost == true
    entry.postX, entry.postY, entry.postZ = record.postX, record.postY, record.postZ
    entry.approachTargetX = record.approachTargetX
    entry.approachTargetY = record.approachTargetY
    entry.approachTargetZ = record.approachTargetZ
    entry.intercepted = record.intercepted == true
    if entry.interceptMeet and record.interceptMeet ~= true and entry.approachRoute then
        entry.approachAlong = BarteringIntercept.nearestAlongRoute(entry.approachRoute,
            entry.zombie:getX(), entry.zombie:getY())
    end
    entry.interceptMeet = record.interceptMeet == true
    entry.ignoreCombat = record.ignoreCombat == true
    entry.continuingTrip = record.continuingTrip == true
    entry.hireWarningActive = record.hireWarning == true
    if not entry.hireWarningActive then
        entry.hireWarningStopped = nil
    end

    if entry.returningAfterMeeting and not wasReturning then
        entry.homeTrip = nil
        entry.returnAlong = nil
        entry.loggedRouteHome = nil
        entry.blockedOpenable = nil
        entry.blockedKind = nil
        entry.blockedBumpTicks = nil
        entry.blockedHoldX, entry.blockedHoldY = nil, nil
        BarteringAIUtils.clearPathing(entry.zombie)
        entry.zombie:setVariable("BartererState", "Return")
        combat.clearCombatTask(entry)
    end

    local routeKey = record.routeStartX and string.format("%s:%s:%s:%s",
        tostring(record.routeStartX), tostring(record.routeStartY),
        tostring(record.routeTargetX), tostring(record.routeTargetY)) or nil
    if routeKey ~= entry.routeKey then
        entry.routeKey = routeKey
        entry.approachRoute = nil
        entry.approachAlong = nil
        entry.routeTrip = routeKey and {
            startX = record.routeStartX,
            startY = record.routeStartY,
            targetX = record.routeTargetX,
            targetY = record.routeTargetY,
            standoff = record.routeStandoff,
        } or nil
    end

    local clothing = record.pendingClothing
    if clothing and (not entry.pendingClothing or entry.pendingClothing.id ~= clothing.id) then
        entry.pendingClothing = {
            id = clothing.id,
            itemType = clothing.itemType,
            replacedType = clothing.replacedType,
            startAtMs = BarteringTiming.now() + DRESS_DELAY_MS,
        }
    end

    entry.appliedRev = record.rev
end

local spawnConfig = {
    state = BarteringAI,
    combat = combat,
    findSpawnLocation = pathing.findSpawnLocation,
    idleTurnIntervalTicks = pathing.IDLE_TURN_INTERVAL_TICKS,
    logBartererServerDebug = logBartererServerDebug,
    applyRecord = applyRecord,
}
local spawn = BarterSpawn.new(spawnConfig)

local calls = BarteringCalls.new({
    state = BarteringAI,
    resolvePlayerFromRecord = resolvePlayerFromRecord,
    findSpawnLocation = pathing.findSpawnLocation,
    spawnBarterer = spawn.spawnBarterer,
    createBartererZombie = spawn.createBartererZombie,
    registerLive = spawn.registerLive,
    despawnBarterer = spawn.despawnBarterer,
    hasTrackedBarterer = spawn.hasTrackedBarterer,
    clearBartererDeath = spawn.clearBartererDeath,
    serverStateFor = BarteringAI.serverStateFor,
})
spawnConfig.calls = calls

function Bartering.resolveBartererRecord(zombie)
    local bartererId
    if isClient() then
        bartererId = zidIndex[zombie:getOnlineID()]
    else
        bartererId = BarteringAI.serverZombieIds[zombie]
    end
    if not bartererId then
        return nil
    end
    local record = Bartering.getLiveRecord(bartererId)
    if not record or record.unloaded then
        return nil
    end
    return record, bartererId
end

local function rebuildZidIndex()
    zidIndex = {}
    for bartererId, record in pairs(Bartering.getLiveRecords()) do
        if record.zid and not record.unloaded then
            zidIndex[record.zid] = bartererId
        end
    end
end

BarteringAI.rebuildZidIndex = rebuildZidIndex

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

    if zombie:getCurrentStateName() == "WalkTowardState" then
        zombie:changeState(ZombieIdleState.instance())
    end
    Bartering.clearEngineTarget(zombie)
    zombie:setTargetSeenTime(0)
    zombie:setUseless(true)
    return true
end

local function isSafeAtPost(entry, zombie)
    return zombie:getVariableString("BartererState") == "Waiting"
        and not entry.combatTask and not entry.threatNearby and not entry.swarmed
end

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

    local safe = isSafeAtPost(entry, zombie)

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
    BarteringAIUtils.playScriptedBump(entry, zombie, "Bandage")
    logBartererServerDebug(zombie, "applying bandage", "Waiting")
end

local function updateDressUp(entry, zombie)
    local dress = entry.pendingClothing
    if not dress or dress.done then
        return false
    end

    if not dress.playing then
        if BarteringTiming.now() < dress.startAtMs or entry.bandaging or not isSafeAtPost(entry, zombie) then
            return true
        end
        dress.playing = true
        dress.ticks = 0
        BarteringAIUtils.playScriptedBump(entry, zombie, Bartering.getWearBumpType(dress.itemType))
        logBartererServerDebug(zombie, "putting on " .. dress.itemType, "Waiting")
        return true
    end

    dress.ticks = dress.ticks + 1
    local finished = zombie:getVariableBoolean("BumpAnimFinished")
    if finished or dress.ticks >= DRESS_ANIM_TIMEOUT_TICKS then
        zombie:setBumpType("")
        Bartering.wearBartererClothing(zombie, entry.bartererId, dress.itemType, dress.replacedType)
        dress.done = true
        report(entry, "clothingDone", { id = dress.id })
        logBartererServerDebug(zombie, string.format("now wearing %s (animFinished=%s ticks=%d)",
            dress.itemType, tostring(finished), dress.ticks), "Waiting")
    end
    return true
end

local function pulse(entry, zombie)
    entry.reportTicks = (entry.reportTicks or 0) - 1
    if entry.reportTicks > 0 then
        return
    end
    entry.reportTicks = REPORT_INTERVAL_TICKS
    report(entry, "pulse", {
        x = zombie:getX(),
        y = zombie:getY(),
        z = zombie:getZ(),
        state = zombie:getVariableString("BartererState") or "",
        ammo = entry.ammoReserve + entry.gun:getCurrentAmmoCount(),
        weapon = zombie:getVariableString("BartererWeapon"),
        loaded = entry.gun:getCurrentAmmoCount(),
        magOut = entry.gunMagOut == true,
        returningToPost = entry.returningToPost == true,
        visible = BarteringAIUtils.forEachPlayer(function(player)
            return player:CanSee(zombie)
        end, true),
        playerNear = BarteringIntercept.findPlayerNear(zombie:getX(), zombie:getY()) ~= nil,
    })
end

local function resolveApproachRoute(entry, zombie)
    if not entry.routeTrip then
        return
    end
    local route = Bartering.RoadRoute.ensure(entry.routeTrip)
    if route.status ~= "ready" then
        return
    end
    entry.routeTrip = nil
    if route.total > 0 then
        entry.approachRoute = route
        entry.approachAlong = BarteringIntercept.nearestAlongRoute(route, zombie:getX(), zombie:getY())
    end
end

local function updateBarterer(entry)
    loggingEntry = entry
    local zombie = entry.zombie
    if zombie:isDead() then
        if not entry.deathReported then
            entry.deathReported = true
            report(entry, "died", {
                witnessed = BarteringAIUtils.forEachPlayer(function(player)
                    return player:CanSee(zombie)
                end),
            })
        end
        logBartererServerDebug(zombie, string.format(
            "health depleted (%.3f); converting to corpse", zombie:getHealth()), "Dying")
        zombie:setUseless(false)
        zombie:setAttackedBy(getCell():getFakeZombieForHit())
        zombie:Kill(getCell():getFakeZombieForHit())
        return false
    end

    if not zombie:getSquare() then
        return false
    end

    local record = Bartering.getLiveRecord(entry.bartererId)
    entry.master = Bartering.findOnlinePlayer(record.master)
    if entry.hostilePlayer and not Bartering.Hostility.isHostileTo(entry.bartererId, entry.hostilePlayer) then
        entry.hostilePlayer = nil
    end

    if entry.zombifyPending then
        if not entry.zombifyReported then
            entry.zombifyReported = true
            report(entry, "zombify")
        end
        return true
    end

    resolveApproachRoute(entry, zombie)

    local bartererState = zombie:getVariableString("BartererState") or ""
    local hired = BarteringHire.isHired(entry.bartererId) and entry.master ~= nil
    entry.hired = hired

    if hired then
        local pullDistSq = BarteringAIUtils.distanceSqBetween(entry.master, zombie)
        if entry.hirePull then
            if pullDistSq <= BarteringFollow.PULL_RELEASE_DISTANCE_SQ then
                entry.hirePull = nil
            end
        elseif pullDistSq > BarteringFollow.PULL_TRIGGER_DISTANCE_SQ then
            entry.hirePull = true
        end
    else
        entry.hirePull = nil
    end

    pulse(entry, zombie)

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
        elseif entry.biteStates then
            combat.resetBiteStates(entry)
        end
    elseif entry.biteStates then
        combat.resetBiteStates(entry)
    end

    if not fighting and not entry.combatTask
        and zombie:getBumpType() == ""
        and (not entry.combatEndedAt or BarteringTiming.now() - entry.combatEndedAt >= KNIFE_REEQUIP_DELAY_MS)
        and zombie:getVariableString("BartererWeapon") ~= "Knife" then
        combat.equipWeapon(zombie, entry.knife, "Knife")
    end

    local isApproaching = not entry.homeResident and not entry.hasArrived
    local isReturning = entry.returningAfterMeeting == true
    local hostilePlayer, hostileDistance = combat.getHostilePlayer(entry, zombie)
    if isReturning then
        if not hostilePlayer then
            combat.clearCombatTask(entry)
        end
    elseif not hostilePlayer
        and (entry.retreatActive or entry.retreatForced or entry.swarmed or entry.meleeBehind > 0 or not isApproaching) then
        retreat.tryStartRetreat(entry, zombie)
        if entry.retreatActive then
            combat.clearCombatTask(entry)
            if retreat.updateRetreat(entry, zombie) then
                BarteringPathTrace.aiStop(zombie, "retreat.active")
                return true
            end
        end
    end

    if hostilePlayer and not entry.hirePull then
        local target, targetDistance = hostilePlayer, hostileDistance
        local threat, threatDistance = combat.getClosestThreat(zombie, hostilePlayer)
        if threat and threatDistance < hostileDistance then
            target, targetDistance = threat, threatDistance
        end
        if not entry.chasingThreat then
            if BarteringTasks.HasTask(zombie) then
                BarteringTasks.StopTasks(zombie)
            end
            BarteringAIUtils.clearGoal(zombie, "hostileDefend")
            BarteringAIUtils.clearPathing(zombie)
        end
        combat.defend(entry, zombie, target, targetDistance)
        BarteringPathTrace.aiStop(zombie,
            target == hostilePlayer and "combat.defend.hostilePlayer" or "combat.defend.hostileThreat")
        return true
    end

    if not manageBartererActionState(entry, zombie) then
        BarteringPathTrace.aiStop(zombie, "actionState." .. tostring(zombie:getActionStateName()))
        return true
    end

    local idleAtPost = entry.hasArrived
        and (nearestThreatSq == nil or nearestThreatSq > combat.THREAT_ENGAGE_DISTANCE_SQ)
        and zombie:getVariableString("BartererState") == "Waiting"
        and zombie:getActionStateName() == "idle"
        and not entry.returningToPost
        and not entry.returningAfterMeeting
        and not entry.retreatActive
        and not entry.swarmed
        and not entry.combatTask

    if idleAtPost then
        BarteringPathTrace.counter(zombie, "idleAtPost.skippedThreatScan")
    end

    if isApproaching then
        pathing.updateApproachCrowding(entry, zombie)
    end

    if entry.ignoreCombat and entry.combatTask then
        combat.clearCombatTask(entry)
        BarteringAIUtils.suppressZombieCombat(zombie)
    end

    if not entry.hirePull and entry.combatTask and combat.processCombatTask(entry, zombie) then
        BarteringPathTrace.aiStop(zombie, "combat.task")
        return true
    end

    if isApproaching then
        local threatWithinFightRange = nearestThreatSq ~= nil and nearestThreatSq <= BarteringAIUtils.APPROACH_FIGHT_RADIUS_SQ
        if not entry.retreatActive and not entry.ignoreCombat and not entry.hirePull and (entry.swarmed or threatWithinFightRange
            or (entry.approachCrowded and entry.withinApproachFightRange)) then
            local threat, distance = combat.getClosestThreat(zombie, entry.hostilePlayer)
            if threat then
                combat.defend(entry, zombie, threat, distance)
                BarteringPathTrace.aiStop(zombie, "combat.defend.approachThreat")
                return true
            end
        end
    elseif not isReturning and not idleAtPost and not entry.hirePull then
        local threat, distance = combat.getClosestThreat(zombie, entry.hostilePlayer)
        if threat then
            combat.defend(entry, zombie, threat, distance)
            BarteringPathTrace.aiStop(zombie, "combat.defend.threat")
            return true
        end
    end

    combat.clearCombatTask(entry)
    BarteringAIUtils.resetPassiveState(zombie)
    if not updateDressUp(entry, zombie) then
        updateBandage(entry, zombie)
    end
    if hired then
        if entry.hirePull then
            if pathing.updateHireFollow(entry, zombie) then
                BarteringPathTrace.aiStop(zombie, "hire.pull.doorHold")
            else
                BarteringFollow.pullToMaster(entry, zombie, entry.master, BarteringFollow.FOLLOW_SPRINT_MOVEMENT_SPEED)
                BarteringPathTrace.aiStop(zombie, "hire.pull")
            end
        elseif entry.hireWarningActive then
            BarteringFollow.holdForWarning(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "hire.warning")
        elseif pathing.updateHireFollow(entry, zombie) then
            BarteringPathTrace.aiStop(zombie, "hire.doorHold")
        else
            BarteringFollow.updateFollow(entry, zombie, entry.master)
            BarteringPathTrace.aiStop(zombie, "hire.follow")
        end
    else
        pathing.updateMovement(entry, zombie)
    end

    return true
end

function BarteringAI.noteControllerZombie(zombie, bartererId, record)
    if isClient() and zombie:isRemoteZombie() then
        return
    end
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        if entry.bartererId == bartererId then
            if entry.zombie == zombie and entry.seq == record.seq then
                return
            end
            spawn.untrackEntry(i)
        end
    end
    spawn.attachController(zombie, bartererId, record)
    print(string.format("[Bartering][MP] now controlling %s seq=%s zid=%s",
        tostring(bartererId), tostring(record.seq), tostring(zombie:getOnlineID())))
end

local function updateControlledBarterers()
    BarteringAIUtils.advanceThreatSnapshots()
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        local record = Bartering.getLiveRecord(entry.bartererId)
        if not record or record.unloaded or record.seq ~= entry.seq
            or entry.zombie:getOnlineID() ~= entry.zid
            or (isClient() and entry.zombie:isRemoteZombie()) then
            print(string.format("[Bartering][MP] releasing control of %s | record=%s unloaded=%s seqMatch=%s remote=%s zid=%s now=%s",
                tostring(entry.bartererId), tostring(record ~= nil), tostring(record and record.unloaded),
                tostring(record and record.seq == entry.seq), tostring(entry.zombie:isRemoteZombie()),
                tostring(entry.zid), tostring(entry.zombie:getOnlineID())))
            BarteringPathTrace.forget(entry.zombie)
            spawn.untrackEntry(i)
        else
            if record.rev ~= entry.appliedRev then
                applyRecord(entry, record)
            end
            if not updateBarterer(entry) then
                BarteringPathTrace.forget(entry.zombie)
                spawn.untrackEntry(i)
            end
        end
    end
end

local function findBartererCorpse(record)
    local cell = getCell()
    local cx, cy, z = math.floor(record.x), math.floor(record.y), record.z or 0
    local best, bestDistSq
    for dx = -CORPSE_SEARCH_RADIUS, CORPSE_SEARCH_RADIUS do
        for dy = -CORPSE_SEARCH_RADIUS, CORPSE_SEARCH_RADIUS do
            local square = cell:getGridSquare(cx + dx, cy + dy, z)
            if square then
                local objects = square:getStaticMovingObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoDeadBody") then
                        local distSq = dx * dx + dy * dy
                        if not bestDistSq or distSq < bestDistSq then
                            best, bestDistSq = object, distSq
                        end
                    end
                end
            end
        end
    end
    return best
end

local function isWitnessedNear(x, y)
    return BarteringAIUtils.forEachPlayer(function(player)
        return BarteringAIUtils.distanceSq(player:getX(), player:getY(), x, y) <= WITNESS_DISTANCE_SQ
    end)
end

local function recordBartererDeath(bartererId, record, zombie)
    local st = BarteringAI.serverStateFor(bartererId)
    local cause = (st.lastPlayerAttackAt and BarteringTiming.now() - st.lastPlayerAttackAt <= PLAYER_KILL_CAUSE_TIMEOUT_MS)
        and "player" or "zombie"
    local witnessed = st.deathWitnessed == true or isWitnessedNear(record.x, record.y)
    local permanentlyDead = spawn.markBartererDeath(bartererId, cause, witnessed)
    local master = Bartering.findOnlinePlayer(record.master)
    calls.setBartererAvailability(master, bartererId, false, permanentlyDead or nil)
    calls.clearPendingCall(bartererId)
    calls.setBartererETA(master, bartererId, 0, false)
    Bartering.setRegistryRecord(Bartering.Registries.Call, bartererId, nil)
    print(string.format(
        "[Bartering][ServerDebug] barterer %s died cause=%s permanentlyDead=%s witnessed=%s homeResident=%s pos=%.2f,%.2f,%.2f",
        tostring(bartererId), tostring(cause), tostring(permanentlyDead), tostring(witnessed),
        tostring(record.homeResident == true), record.x, record.y, record.z))
end

local function finalizeDeath(bartererId, zombie, viaFallback)
    local st = BarteringAI.serverStateFor(bartererId)
    if st.deathFinalized then
        return
    end
    st.deathFinalized = true

    local record = Bartering.getLiveRecord(bartererId)
    if zombie:getSquare() then
        record.x, record.y, record.z = zombie:getX(), zombie:getY(), zombie:getZ()
    end
    local stock = Bartering.takeBartererDeathStock(bartererId)
    local corpse
    if viaFallback then
        corpse = findBartererCorpse(record)
        if corpse then
            Bartering.stockBartererCorpse(corpse, stock)
        end
    else
        Bartering.restoreBartererDeathLook(zombie, bartererId)
        Bartering.stockBartererDeathbag(zombie, stock)
    end
    Bartering.releaseBartererZombie(zombie)
    recordBartererDeath(bartererId, record, zombie)

    local items = BarteringAI.serverItems[bartererId]
    local square = getCell():getGridSquare(math.floor(record.x), math.floor(record.y), record.z or 0)
    items.gun:setCurrentAmmoCount(record.loaded or 0)
    items.gun:setContainsClip(not record.magOut)
    Bartering.dropBartererEquipment(bartererId, square, items.gun, items.knife, (record.ammo or 0) - items.gun:getCurrentAmmoCount(),
        corpse and corpse:getContainer() or zombie:getInventory(), corpse ~= nil, record.weapon == "Knife")

    Bartering.Relations.resetAll(bartererId)
    Bartering.Hostility.clearAll(bartererId)
    BarteringHire.clearHiredState(bartererId)
    spawn.removeLive(bartererId)
    print(string.format("[Bartering][MP] finalized death of %s via=%s corpseFound=%s stock=%d",
        tostring(bartererId), viaFallback and "fallback" or "OnZombieDead", tostring(corpse ~= nil), #stock))
end

local function zombifyBarterer(bartererId, reporter)
    local record = Bartering.getLiveRecord(bartererId)
    local zombie = BarteringAI.serverZombies[bartererId]
    if not record or not zombie then
        return
    end
    local recipient = Bartering.findOnlinePlayer(record.master) or reporter
    local witnessed = isWitnessedNear(zombie:getX(), zombie:getY())
    spawn.removeLive(bartererId)
    Bartering.releaseBartererZombie(zombie)
    local permanentlyDead = spawn.markBartererDeath(bartererId, "zombie", witnessed)
    calls.setBartererAvailability(recipient, bartererId, false, permanentlyDead or nil)
    calls.clearPendingCall(bartererId)
    calls.setBartererETA(recipient, bartererId, 0, false)
    Bartering.setRegistryRecord(Bartering.Registries.Call, bartererId, nil)
    Bartering.Relations.resetAll(bartererId)
    Bartering.Hostility.clearAll(bartererId)
    BarteringHire.clearHiredState(bartererId)
    print(string.format("[Bartering][ServerDebug] zombified barterer %s permanentlyDead=%s witnessed=%s pos=%.2f,%.2f,%.2f",
        tostring(bartererId), tostring(permanentlyDead), tostring(witnessed),
        zombie:getX(), zombie:getY(), zombie:getZ()))
end

local function releaseHire(bartererId, record)
    BarteringHire.clearHiredState(bartererId)
    local st = BarteringAI.serverStateFor(bartererId)
    st.hireWarningElapsedMs = nil
    st.hireWarningLastMs = nil
    st.hireWindowOpen = nil
    record.master = nil
    record.hireWarning = false
    Bartering.bumpLiveRev(record)
end

local function finishHireExpiry(bartererId, record, zombie)
    releaseHire(bartererId, record)
    BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Hire.expired)
    if record.homeResident then
        return false
    end
    calls.handleExpiry(bartererId, record, zombie)
    return true
end

local function updateServerHire(bartererId, record, zombie)
    if not BarteringHire.isHired(bartererId) then
        if record.hireWarning then
            record.hireWarning = false
            Bartering.bumpLiveRev(record)
        end
        return false
    end

    local hireState = BarteringHire.getHiredState(bartererId)
    if not Bartering.findOnlinePlayer(hireState.hiredBy) then
        releaseHire(bartererId, record)
        if record.homeResident then
            return false
        end
        calls.handleExpiry(bartererId, record, zombie)
        return true
    end
    if record.master ~= hireState.hiredBy then
        record.master = hireState.hiredBy
        Bartering.bumpLiveRev(record)
    end

    local st = BarteringAI.serverStateFor(bartererId)
    local remainingHours = BarteringHire.getRemainingHours(bartererId)
    local nowMs = BarteringTiming.now()
    if record.hireWarning then
        if remainingHours > BarteringHire.getHireWarningHours() then
            record.hireWarning = false
            st.hireWarningElapsedMs = nil
            st.hireWarningLastMs = nil
            Bartering.bumpLiveRev(record)
        elseif not st.hireWindowOpen then
            st.hireWarningElapsedMs = (st.hireWarningElapsedMs or 0) + (nowMs - (st.hireWarningLastMs or nowMs))
            st.hireWarningLastMs = nowMs
            if st.hireWarningElapsedMs >= BarteringHire.HIRE_WARNING_SECONDS * 1000 then
                return finishHireExpiry(bartererId, record, zombie)
            end
        else
            st.hireWarningLastMs = nowMs
        end
    elseif remainingHours <= 0 then
        return finishHireExpiry(bartererId, record, zombie)
    elseif remainingHours <= BarteringHire.getHireWarningHours() then
        record.hireWarning = true
        st.hireWarningElapsedMs = 0
        st.hireWarningLastMs = nowMs
        Bartering.bumpLiveRev(record)
        BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Hire.leavingSoon)
    end
    return false
end

local function updateServerBarterer(bartererId, record, zombie)
    local st = BarteringAI.serverStateFor(bartererId)
    if st.deathFinalized then
        return
    end

    if zombie:isDead() or (st.deathReportedAt and not zombie:getSquare()) then
        if st.deathReportedAt and BarteringTiming.hasElapsed(st.deathReportedAt, DEATH_FALLBACK_MS) then
            finalizeDeath(bartererId, zombie, true)
        end
        return
    end

    BarteringAIUtils.keepBartererDocile(zombie)

    if not zombie:getSquare() then
        if record.returningAfterMeeting then
            calls.handleExpiry(bartererId, record, zombie)
            return
        end
        spawn.releaseLost(bartererId, record, zombie, "removed from world")
        return
    end

    if not spawn.ownsServerZombie(bartererId, record, zombie) then
        spawn.releaseLost(bartererId, record, zombie, "instance reused")
        return
    end

    if st.pulseAt and BarteringTiming.hasElapsed(st.pulseAt, PULSE_STALE_MS) then
        st.visible = false
        st.playerNear = false
    end

    if not record.homeResident and record.master and not record.returningAfterMeeting
        and not BarteringHire.isHired(bartererId) and not Bartering.findOnlinePlayer(record.master) then
        print(string.format("[Bartering][MP] %s master %s offline or dead; heading home",
            tostring(bartererId), tostring(record.master)))
        calls.clearIntercept(bartererId, record)
        calls.clearPendingCall(bartererId)
        Bartering.setRegistryRecord(Bartering.Registries.Call, bartererId, nil)
        calls.handleExpiry(bartererId, record, zombie)
        return
    end

    local anyPlayerNear = BarteringAIUtils.forEachPlayer(function(player)
        return BarteringAIUtils.distanceSqBetween(player, zombie) <= BarterSpawn.DORMANT_DISTANCE_SQ
    end, true)
    if not anyPlayerNear then
        if (record.intercepted and calls.hasPendingCall(bartererId)) or record.returningAfterMeeting then
            calls.handleExpiry(bartererId, record, zombie)
            return
        end
        spawn.unloadBarterer(bartererId, record, zombie)
        return
    end

    if st.hostileFlee then
        st.hostileFlee = nil
        if not record.homeResident and not record.returningAfterMeeting then
            if BarteringHire.isHired(bartererId) then
                releaseHire(bartererId, record)
            end
            calls.clearIntercept(bartererId, record)
            calls.handleExpiry(bartererId, record, zombie)
            return
        end
    end

    if not record.homeResident and not record.returningAfterMeeting
        and not st.visible and Bartering.Hostility.hasUnresolved(bartererId) then
        print(string.format("[Bartering][Hostility] %s lost sight of hostile player; heading home",
            tostring(bartererId)))
        if BarteringHire.isHired(bartererId) then
            releaseHire(bartererId, record)
        end
        calls.clearIntercept(bartererId, record)
        calls.handleExpiry(bartererId, record, zombie)
        return
    end

    if updateServerHire(bartererId, record, zombie) then
        return
    end

    if not BarteringHire.isHired(bartererId) and calls.shouldExpire(bartererId, record) then
        calls.handleExpiry(bartererId, record, zombie)
    end
end

local function updateServerBarterers()
    for bartererId, record in pairs(Bartering.getLiveRecords()) do
        if record.unloaded then
            if BarteringAI.residentsInitialized and not record.homeResident then
                calls.updateUnloaded(bartererId, record)
            end
        else
            local zombie = BarteringAI.serverZombies[bartererId]
            if zombie then
                updateServerBarterer(bartererId, record, zombie)
            else
                spawn.markUnloaded(bartererId, record)
            end
        end
    end
end

local function onServerZombieDead(zombie)
    local bartererId = BarteringAI.serverZombieIds[zombie]
    if bartererId then
        finalizeDeath(bartererId, zombie, false)
    end
end

local function onControllerZombieDead(zombie)
    for _, entry in ipairs(BarteringAI.barterers) do
        if entry.zombie == zombie and not entry.deathReported then
            entry.deathReported = true
            report(entry, "died", {
                witnessed = BarteringAIUtils.forEachPlayer(function(player)
                    return player:CanSee(zombie)
                end),
            })
        end
    end
end

function BarteringAI.handleReport(player, args)
    local record = Bartering.getLiveRecord(args.bartererId)
    if not record or record.unloaded or record.seq ~= args.seq then
        return
    end
    local st = BarteringAI.serverStateFor(args.bartererId)
    local kind = args.kind

    if kind == "pulse" then
        record.x, record.y, record.z = args.x, args.y, args.z
        record.ammo = args.ammo
        record.weapon = args.weapon
        record.loaded = args.loaded
        record.magOut = args.magOut
        st.visible = args.visible == true
        st.playerNear = args.playerNear == true
        st.pulseAt = BarteringTiming.now()
        if record.state ~= args.state or record.returningToPost ~= args.returningToPost then
            record.state = args.state
            record.returningToPost = args.returningToPost
            Bartering.markLiveDirty()
        end
    elseif kind == "arrived" then
        record.hasArrived = true
        record.postX, record.postY, record.postZ = args.postX, args.postY, args.postZ
        record.returningToPost = false
        record.continuingTrip = false
        record.departureAtHours = (not record.homeResident)
            and (record.meetupDeadlineHours or BarteringTiming.createCalledInDepartureHours()) or nil
        if record.intercepted then
            calls.clearIntercept(args.bartererId, record)
        end
        Bartering.bumpLiveRev(record)
        print(string.format("[Bartering][MP] %s arrived at %s,%s,%s", tostring(args.bartererId),
            tostring(args.postX), tostring(args.postY), tostring(args.postZ)))
    elseif kind == "atPost" then
        record.returningToPost = false
        record.returningAfterMeeting = false
        Bartering.bumpLiveRev(record)
    elseif kind == "died" then
        st.deathWitnessed = args.witnessed == true
        st.deathReportedAt = BarteringTiming.now()
        print(string.format("[Bartering][MP] %s death reported by %s witnessed=%s",
            tostring(args.bartererId), tostring(player:getUsername()), tostring(args.witnessed)))
    elseif kind == "zombify" then
        zombifyBarterer(args.bartererId, player)
    elseif kind == "doorCheck" then
        local square = getCell():getGridSquare(args.x, args.y, args.z)
        local door = square and square:getIsoDoor()
        print(string.format("[Bartering][MP] doorCheck %s at %d,%d,%d | client [%s] | server %s",
            tostring(args.bartererId), args.x, args.y, args.z, tostring(args.clientFlags),
            door and ("[" .. BarteringAIUtils.doorFlags(door) .. "]")
                or ("no IsoDoor (square=" .. tostring(square ~= nil) .. ")")))
    elseif kind == "dropMagazine" then
        local square = getCell():getGridSquare(math.floor(args.x), math.floor(args.y), math.floor(args.z))
        square:AddWorldInventoryItem(instanceItem(args.item), ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
        print(string.format("[Bartering][Ammo] dropMagazine %s item=%s from=%s",
            tostring(args.bartererId), tostring(args.item), tostring(player:getUsername())))
    elseif kind == "clothingDone" then
        if record.pendingClothing and record.pendingClothing.id == args.id then
            record.pendingClothing = nil
            Bartering.bumpLiveRev(record)
        end
    end
end

function BarteringAI.relaySay(player, args)
    sendServerCommand("Bartering", "bartererSay", {
        bartererId = args.bartererId,
        text = args.text,
        from = player:getUsername(),
    })
end

function BarteringAI.relayShot(player, args)
    sendServerCommand("Bartering", "bartererShot", {
        bartererId = args.bartererId,
        sound = args.sound,
        from = player:getUsername(),
    })
end

function BarteringAI.relaySound(player, args)
    sendServerCommand("Bartering", "bartererSound", {
        bartererId = args.bartererId,
        sound = args.sound,
        from = player:getUsername(),
    })
end

function BarteringAI.removeZombie(player, args)
    local zombies = getCell():getZombieList()
    for i = zombies:size() - 1, 0, -1 do
        local zombie = zombies:get(i)
        if zombie:getOnlineID() == args.zid then
            print(string.format("[Bartering][MP] removing zombie zid=%s at client request from %s",
                tostring(args.zid), tostring(player:getUsername())))
            Bartering.removeZombieEverywhere(zombie)
            return
        end
    end
    print(string.format("[Bartering][MP] client asked to remove zid=%s but the server has no such zombie",
        tostring(args.zid)))
end

function BarteringAI.relayZombieHit(player, args)
    Bartering.broadcastToClients("zombieHit", args)
end

function BarteringAI.relayPlayerHit(player, args)
    local victim = Bartering.findOnlinePlayer(args.username)
    local attacker = BarteringAI.serverZombies[args.bartererId]
    if not victim or not attacker then
        return
    end
    local healthBefore = victim:getBodyDamage():getOverallBodyHealth()
    BarteringAICombat.hitPlayer(attacker, victim, instanceItem(args.weapon), args.damage)
    print(string.format("[Bartering][MP] %s hit player %s with %s dmg=%.2f health %.1f->%.1f",
        tostring(args.bartererId), tostring(args.username), tostring(args.weapon), args.damage,
        healthBefore, victim:getBodyDamage():getOverallBodyHealth()))
end

function BarteringAI.applyRelayedZombieHit(args)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local target = zombies:get(i)
        if target:getOnlineID() == args.zid then
            if (isClient() and target:isRemoteZombie()) or target:isDead() then
                return
            end
            local attacker = Bartering.getLocalBartererZombie(args.bartererId)
            if attacker then
                BarteringAICombat.hitZombie(attacker, target, instanceItem(args.weapon), args.damage, args.ranged)
            end
            return
        end
    end
end

function BarteringAI.applyDebugAction(args)
    local entry = BarteringAIUtils.findBartererEntry(BarteringAI.barterers, args.bartererId)
    if not entry then
        return
    end
    local zombie = entry.zombie
    if args.action == "kill" then
        zombie:setHealth(0)
    elseif args.action == "hurt" then
        zombie:setHealth(math.max(0.1, zombie:getHealth() - 30))
        entry.needsBandage = true
    elseif args.action == "bandage" then
        BarteringAIUtils.playScriptedBump(entry, zombie, "Bandage")
    end
    print(string.format("[Bartering][ServerDebug] debug %s applied to %s health=%.3f",
        tostring(args.action), tostring(args.bartererId), zombie:getHealth()))
end

function BarteringAI.attackedBy(player, args)
    local bartererId = args.id
    local record = bartererId and Bartering.getLiveRecord(bartererId)
    if not record or record.unloaded then
        return
    end
    print(string.format("[Bartering][Hostility] attack by %s on %s | preRelation=%s",
        tostring(player:getUsername()), tostring(bartererId),
        tostring(Bartering.Relations.get(player, bartererId))))
    local st = BarteringAI.serverStateFor(bartererId)
    st.lastPlayerAttackAt = BarteringTiming.now()
    st.hostileFlee = true
    if Bartering.Hostility.isAmendsPendingFor(bartererId, player) then
        Bartering.Hostility.cancelAmends(bartererId)
    end
    Bartering.Hostility.trigger(bartererId, player)
end

function BarteringAI.shovedBy(player, args)
    local bartererId = args.id
    local record = bartererId and Bartering.getLiveRecord(bartererId)
    if not record or record.unloaded then
        return
    end
    BarteringAI.serverStateFor(bartererId).lastPlayerAttackAt = BarteringTiming.now()
    if Bartering.Hostility.isAmendsPendingFor(bartererId, player) then
        Bartering.Hostility.cancelAmends(bartererId)
    end
    Bartering.Hostility.trigger(bartererId, player)
    print(string.format("[Bartering][Hostility] shove by %s on %s | hostileNow=%s",
        tostring(player:getUsername()), tostring(bartererId),
        tostring(Bartering.Hostility.isHostileTo(bartererId, player))))
end

function BarteringAI.syncBartererStock(bartererId)
    local zombie = BarteringAI.serverZombies[bartererId]
    if zombie and not zombie:isDead() then
        Bartering.syncBartererStockToContainer(Bartering.getBartererBag(zombie), bartererId)
    end
end

function BarteringAI.queueClothingChange(bartererId, itemType, replacedType)
    local record = Bartering.getLiveRecord(bartererId)
    if not record or record.unloaded then
        return false
    end
    record.pendingClothing = {
        id = BarteringTiming.now(),
        itemType = itemType,
        replacedType = replacedType,
    }
    Bartering.bumpLiveRev(record)
    return true
end

function BarteringAI.setHireWindowOpen(bartererId, open)
    BarteringAI.serverStateFor(bartererId).hireWindowOpen = open or nil
end

function BarteringAI.isEnRoute(bartererId)
    local record = Bartering.getLiveRecord(bartererId)
    return record ~= nil and not record.unloaded
        and (record.intercepted or (not record.hasArrived and record.approachTargetX ~= nil))
end

function BarteringAI.debugDespawnAll(player)
    local removed = 0
    for _ in pairs(Bartering.getLiveRecords()) do
        removed = removed + 1
    end
    calls.debugSendAllHomeNow(player)
    print(string.format("[Bartering][ServerDebug] debug despawn all | removed=%d ended trips and sent barterers home", removed))
    calls.sendToClient(player, "playerSay", { text = string.format("Despawned %d barterers and sent everyone home", removed) })
end

local function debugAction(action)
    return function(player, bartererId)
        Bartering.broadcastToClients("bartererDebug", { bartererId = bartererId, action = action })
    end
end

BarteringAI.debugKillBarterer = debugAction("kill")
BarteringAI.debugHurtBarterer = debugAction("hurt")
BarteringAI.debugBandageBarterer = debugAction("bandage")

function BarteringAI.debugZombifyBarterer(player, bartererId)
    zombifyBarterer(bartererId, player)
end

BarteringAI.despawnBarterer = spawn.despawnBarterer
BarteringAI.spawnBarterer = spawn.spawnBarterer
BarteringAI.callBarterer = calls.callBarterer
BarteringAI.radioStatus = calls.radioStatus
BarteringAI.updateBartererCallLocation = calls.updateBartererCallLocation
BarteringAI.debugCallBarterer = calls.debugCallBarterer
BarteringAI.cancelBartererMeeting = calls.cancelBartererMeeting
function BarteringAI.sendBartererHome(player, bartererId)
    if BarteringHire.isHired(bartererId) then
        if not BarteringHire.isHiredBy(player, bartererId) then
            return
        end
        releaseHire(bartererId, Bartering.getLiveRecord(bartererId))
    end
    calls.sendBartererHome(player, bartererId)
end
BarteringAI.sendPlayerBarterersHome = calls.sendPlayerBarterersHome
BarteringAI.acceptStayHere = calls.acceptStayHere
BarteringAI.declineTradeHere = calls.declineTradeHere
BarteringAI.noteInterceptDialog = calls.noteInterceptDialog
BarteringAI.debugSpawnBarterer = calls.debugSpawnBarterer
BarteringAI.debugSpawnBartererAt = calls.debugSpawnBartererAt

if not isClient() then
    events.OnZombieDead.Add(onServerZombieDead)
    events.OnZombieCreate.Add(spawn.probeOnZombieCreate)
    events.OnTick.Add(spawn.probeHomes)
    events.OnTick.Add(spawn.bootstrap)
    events.OnTick.Add(updateServerBarterers)
    events.OnTick.Add(spawn.updateSpawns)
    events.OnTick.Add(function() calls.processCalledInCleanups() end)
    events.OnTick.Add(function() calls.updatePendingCalls() end)
    events.OnServerStarted.Add(spawn.resetBootstrap)
end

if isClient() then
    events.OnTick.Add(rebuildZidIndex)
    events.OnZombieDead.Add(onControllerZombieDead)
end

if not isServer() then
    events.OnTick.Add(updateControlledBarterers)
end

return BarteringAI
