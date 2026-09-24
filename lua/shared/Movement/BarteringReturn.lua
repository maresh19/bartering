Bartering = Bartering or {}

local getCell = _G["getCell"]
local getGameTime = _G["getGameTime"]
local ModData = _G["ModData"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringArrive = require "Movement/BarteringArrive"

local RETURNING_HOME_REGISTRY = Bartering.Registries.ReturningHome
local RETURN_OUT_OF_SIGHT_GRACE_MS = 5000
local REVEAL_DISTANCE_SQ = 30 * 30

local TUNE = {}
TUNE.RETURN_START_AFTER_FAR_TICKS = 45
TUNE.RESIDENT_POST_CLEAR_DISTANCE = 2
TUNE.RETURN_NEAR_POST_SETTLE_DISTANCE = 1.60
TUNE.RETURN_MOVEMENT_SPEED = 1.00
TUNE.RETURN_MAX_LEG_DISTANCE = 100
TUNE.RETURN_OBSTRUCTION_LOG_TICKS = 10
TUNE.RETURN_PLAYER_BLOCK_DISTANCE_SQ = 2.25
TUNE.RETURN_EXIT_STALL_TICKS = 180
TUNE.RETURN_ROUTE_STEP = 20
TUNE.RETURN_ROUTE_REACH_SQ = 6 * 6

local clearGoal = BarteringAIUtils.clearGoal
local publishGoal = BarteringAIUtils.publishGoal
local publishExactGoal = BarteringAIUtils.publishExactGoal

local function clearExit(entry)
    entry.exitDoor = nil
    entry.exitInsideX, entry.exitInsideY = nil, nil
    entry.exitOutsideX, entry.exitOutsideY = nil, nil
    entry.exitPhase = nil
    entry.exitBest, entry.exitStall = nil, nil
end

local function isOnTile(zombie, x, y)
    return math.floor(zombie:getX()) == x and math.floor(zombie:getY()) == y
end

local BarteringReturn = {}

BarteringReturn.RESIDENT_POST_CLEAR_DISTANCE = TUNE.RESIDENT_POST_CLEAR_DISTANCE

local function clampReturnLeg(zombie, targetX, targetY)
    local dx = targetX - zombie:getX()
    local dy = targetY - zombie:getY()
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= TUNE.RETURN_MAX_LEG_DISTANCE then
        return targetX, targetY, false
    end

    local scale = TUNE.RETURN_MAX_LEG_DISTANCE / distance
    return zombie:getX() + dx * scale, zombie:getY() + dy * scale, true
end

local function hasPost(entry)
    return entry.postX ~= nil and entry.postY ~= nil and entry.postZ ~= nil
end

local function isFarFromPost(entry, zombie, returnDistance)
    if not hasPost(entry) then
        return false
    end

    return zombie:getZ() ~= entry.postZ
        or BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), entry.postX, entry.postY) > (returnDistance * returnDistance)
end

local function isAtPost(entry, zombie, arrivedDistance, strictArrival)
    if not hasPost(entry) then
        return false
    end

    local onTile = zombie:getZ() == entry.postZ
        and math.floor(zombie:getX()) == entry.postX
        and math.floor(zombie:getY()) == entry.postY
    if onTile or strictArrival then
        return onTile
    end

    return zombie:getZ() == entry.postZ
        and BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), entry.postX, entry.postY) <= (arrivedDistance * arrivedDistance)
end

function BarteringReturn.clearPostIntruders(postX, postY, postZ, clearDistance, exceptZombie)
    local zombies = getCell():getZombieList()
    for i = zombies:size() - 1, 0, -1 do
        local zombie = zombies:get(i)
        if zombie ~= exceptZombie and not zombie:isDead() and zombie:getZ() == postZ
            and not BarteringAIUtils.isBartererZombie(zombie) then
            if BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), postX, postY) <= (clearDistance * clearDistance) then
                print(string.format("[Bartering][Post] clearing zombie zid=%s at %.1f,%.1f from post %d,%d",
                    tostring(zombie:getOnlineID()), zombie:getX(), zombie:getY(), postX, postY))
                Bartering.removeZombieEverywhere(zombie)
            end
        end
    end
end

local function clearResidentPostIntruders(entry, residentZombie, clearDistance)
    if not entry.homeResident or not entry.postX or not entry.postY or not entry.postZ then
        return
    end
    BarteringReturn.clearPostIntruders(entry.postX, entry.postY, entry.postZ, clearDistance, residentZombie)
end

function BarteringReturn.newMovement(deps)
    local function logReturnObstruction(zombie, reason)
        local collidedObject = zombie:getCollidedObject()
        local nearbyPlayer, playerDistanceSq = deps.getClosestNearbyPlayer(zombie, TUNE.RETURN_PLAYER_BLOCK_DISTANCE_SQ)
        print(string.format(
            "[Bartering][ReturnObstruction] %s | reason=%s action=%s collided=%s collideType=%s collidedObject=%s playerBlock=%s playerDistSq=%s pos=%.2f,%.2f,%.2f",
            tostring(zombie:getVariableString("BartererId")),
            tostring(reason),
            tostring(zombie:getActionStateName()),
            tostring(zombie:isCollidedThisFrame()),
            tostring(zombie:getCollideType()),
            tostring(collidedObject and collidedObject:getObjectName() or "nil"),
            tostring(nearbyPlayer ~= nil),
            tostring(playerDistanceSq),
            zombie:getX(),
            zombie:getY(),
            zombie:getZ()
        ))
    end

    local function neutralize(entry, zombie)
        local hostile = deps.neutralizeHostileAction(entry, zombie)
        if hostile and (entry.hostileTicks == 1 or entry.hostileTicks % TUNE.RETURN_OBSTRUCTION_LOG_TICKS == 0) then
            logReturnObstruction(zombie, "hostile-action")
        end
    end

    local function letMyselfOutIfStuck(entry, zombie)
        local attempted, opened, blocked = deps.tryDoorsIfStuck(entry, zombie)
        if not attempted or opened or not blocked or not zombie:getSquare():getBuilding() then
            return
        end
        BarteringAIUtils.unlockDoorFromInside(zombie, blocked)
        BarteringAIUtils.openDoorObject(blocked)
        BarteringPathTrace.counter(zombie, "return.letMyselfOut")
        deps.logBartererServerDebug(zombie, string.format(
            "letting myself out through locked door %.0f,%.0f [%s]",
            blocked:getX(), blocked:getY(), BarteringAIUtils.doorFlags(blocked)), "Return")
        entry.stillTicks = 0
        entry.stuckSample = false
    end

    local function exitProgress(entry, zombie, x, y)
        local dx = x + 0.5 - zombie:getX()
        local dy = y + 0.5 - zombie:getY()
        local distance = math.sqrt(dx * dx + dy * dy)
        if not entry.exitBest or distance < entry.exitBest - 0.5 then
            entry.exitBest, entry.exitStall = distance, 0
        else
            entry.exitStall = entry.exitStall + 1
        end
        return entry.exitStall
    end

    local function openExitDoor(entry, zombie)
        local door = entry.exitDoor
        if door:IsOpen() then
            return
        end
        if door:isLocked() or door:isLockedByKey() then
            BarteringAIUtils.unlockDoorFromInside(zombie, door)
            BarteringPathTrace.counter(zombie, "return.exitUnlocked")
            deps.logBartererServerDebug(zombie, string.format(
                "unlocking exit door %.0f,%.0f from inside", door:getX(), door:getY()), "Return")
        end
        BarteringAIUtils.openDoorObject(door)
    end

    local function leaveBuilding(entry, zombie)
        local here = zombie:getSquare()
        local building = here:getBuilding()
        if not building then
            entry.exitGaveUpBuilding = nil
            if entry.exitDoor then
                BarteringPathTrace.counter(zombie, "return.exitedBuilding")
                deps.logBartererServerDebug(zombie, "out of the building; heading home", "Return")
                clearExit(entry)
            end
            return false
        end

        if not entry.exitDoor then
            if building == entry.exitGaveUpBuilding then
                return false
            end
            local postSquare = getCell():getGridSquare(entry.postX, entry.postY, entry.postZ)
            if postSquare and postSquare:getBuilding() == building then
                return false
            end
            local door, outsideX, outsideY, doorState, doorNotes = BarteringAIUtils.findExitDoor(zombie)
            deps.logBartererServerDebug(zombie, "exit door candidates: " .. doorNotes, "Return")
            if not door then
                entry.exitGaveUpBuilding = building
                BarteringPathTrace.counter(zombie, "return.noExitDoor")
                return false
            end
            entry.exitDoor = door
            entry.exitInsideX, entry.exitInsideY = BarteringAIUtils.doorInteriorTile(door, here:getZ())
            entry.exitOutsideX, entry.exitOutsideY = outsideX, outsideY
            entry.exitPhase = "inside"
            BarteringPathTrace.counter(zombie, "return.exitDoor")
            deps.logBartererServerDebug(zombie, string.format(
                "leaving through %s door %d,%d via %d,%d", doorState,
                math.floor(door:getX()), math.floor(door:getY()), outsideX, outsideY), "Return")
        end

        if entry.exitPhase == "inside" and isOnTile(zombie, entry.exitInsideX, entry.exitInsideY) then
            openExitDoor(entry, zombie)
            entry.exitPhase = "outside"
            entry.exitBest, entry.exitStall = nil, nil
            deps.logBartererServerDebug(zombie, string.format(
                "at exit door; stepping out to %d,%d", entry.exitOutsideX, entry.exitOutsideY), "Return")
        end

        local targetX = entry.exitPhase == "inside" and entry.exitInsideX or entry.exitOutsideX
        local targetY = entry.exitPhase == "inside" and entry.exitInsideY or entry.exitOutsideY
        if exitProgress(entry, zombie, targetX, targetY) >= TUNE.RETURN_EXIT_STALL_TICKS then
            BarteringPathTrace.counter(zombie, "return.exitStalled")
            deps.logBartererServerDebug(zombie, string.format(
                "could not reach exit door tile %d,%d; walking home on my own", targetX, targetY), "Return")
            entry.exitGaveUpBuilding = building
            clearExit(entry)
            return false
        end

        publishExactGoal(zombie, targetX + 0.5, targetY + 0.5, zombie:getZ(), "return.exitDoor")
        return true
    end

    local function followRouteHome(entry, zombie)
        if not entry.homeTrip then
            entry.homeTrip = {
                startX = zombie:getX(),
                startY = zombie:getY(),
                targetX = entry.postX + 0.5,
                targetY = entry.postY + 0.5,
            }
            entry.returnAlong = 0
        end

        local route = Bartering.RoadRoute.ensure(entry.homeTrip)
        if route.status ~= "ready" then
            return false
        end

        if not entry.loggedRouteHome then
            entry.loggedRouteHome = true
            deps.logBartererServerDebug(zombie, string.format(
                "following road route home: %d points, %.0f tiles",
                #route.points, route.total), "Return")
        end

        local x, y = Bartering.RoadRoute.positionAt(route, entry.returnAlong / route.total)
        while entry.returnAlong < route.total
            and BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), x, y) <= TUNE.RETURN_ROUTE_REACH_SQ do
            entry.returnAlong = math.min(route.total, entry.returnAlong + TUNE.RETURN_ROUTE_STEP)
            x, y = Bartering.RoadRoute.positionAt(route, entry.returnAlong / route.total)
        end

        publishGoal(zombie, x, y, 0, "return.route")
        return true
    end

    local function update(entry, zombie)
        entry.returnFarTicks = entry.returnFarTicks or 0

        local arrivedDistance = entry.homeResident == true
            and (BarteringArrive.ARRIVED_AT_POST_DISTANCE + 0.55) or BarteringArrive.ARRIVED_AT_POST_DISTANCE
        local returnDistance = math.max(TUNE.RETURN_NEAR_POST_SETTLE_DISTANCE, arrivedDistance)

        clearResidentPostIntruders(entry, zombie, TUNE.RESIDENT_POST_CLEAR_DISTANCE)
        neutralize(entry, zombie)

        local isFar = isFarFromPost(entry, zombie, returnDistance)
entry.returnFarTicks = isFar and (entry.returnFarTicks + 1) or 0

        local strictReturnTrip = entry.returningAfterMeeting == true
        if not entry.returningToPost
            and (strictReturnTrip or entry.returnFarTicks >= TUNE.RETURN_START_AFTER_FAR_TICKS) then
            entry.returningToPost = isFar
        end

        if not entry.returningToPost then
            clearGoal(zombie, "waiting")
            deps.applyWaitingState(entry, zombie)
            deps.updateIdleFacing(entry, zombie)
            deps.updateIdleEmote(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.waiting.atPost")
            return
        end

        local master = entry.master
        local callerAtPost = master ~= nil
            and BarteringAIUtils.distanceSqBetween(master, zombie) <= TUNE.RETURN_PLAYER_BLOCK_DISTANCE_SQ
        local settleAtPost = callerAtPost and not isFar

        if isAtPost(entry, zombie, arrivedDistance, strictReturnTrip and not callerAtPost) or settleAtPost then
            entry.returningToPost = false
            entry.returnFarTicks = 0
            entry.returningAfterMeeting = false
            clearExit(entry)
            clearGoal(zombie, "return")
            deps.applyWaitingState(entry, zombie)
            deps.updateIdleFacing(entry, zombie)
            deps.report(entry, "atPost")
            deps.logBartererServerDebug(zombie, "return completed", "Waiting")
            BarteringPathTrace.aiStop(zombie, "move.return.arrived")
            return
        end

        local priorState = zombie:getVariableString("BartererState")
        zombie:setVariable("BartererState", "Return")
        if priorState ~= "Return" then
            print(string.format(
                "[Bartering][ReturnState] %s return-walk | hasArrived=%s returningToPost=%s returningAfterMeeting=%s isFar=%s farTicks=%s post=%s,%s,%s pos=%.2f,%.2f,%.2f calledIn=%s priorState=%s",
                tostring(entry.bartererId), tostring(entry.hasArrived), tostring(entry.returningToPost),
                tostring(entry.returningAfterMeeting), tostring(isFar), tostring(entry.returnFarTicks),
                tostring(entry.postX), tostring(entry.postY), tostring(entry.postZ),
                zombie:getX(), zombie:getY(), zombie:getZ(),
                tostring(zombie:getVariableBoolean("BartererCalledIn")),
                tostring(priorState)))
        end
        zombie:setVariable("MovementSpeed", tostring(TUNE.RETURN_MOVEMENT_SPEED))

        if leaveBuilding(entry, zombie) then
            letMyselfOutIfStuck(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.return.exitDoor")
            return
        end

        if strictReturnTrip and followRouteHome(entry, zombie) then
            letMyselfOutIfStuck(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.return.route")
            return
        end

        local legX, legY, clamped = clampReturnLeg(zombie, entry.postX + 0.5, entry.postY + 0.5)
        if clamped and (entry.loggedLegX ~= legX or entry.loggedLegY ~= legY) then
            entry.loggedLegX, entry.loggedLegY = legX, legY
            deps.logBartererServerDebug(zombie, string.format(
                "post %.0f,%.0f too far; walking leg to %.0f,%.0f",
                entry.postX, entry.postY, legX, legY), "Return")
        end

        publishGoal(zombie, legX, legY, clamped and zombie:getZ() or entry.postZ, "return")
        letMyselfOutIfStuck(entry, zombie)
        BarteringPathTrace.aiStop(zombie, clamped and "move.return.leg.clamped" or "move.return.leg")
    end

    return {
        update = update,
    }
end

function BarteringReturn.newSentHome(deps)
    local function startReturnHome(bartererId, record, barterer)
        deps.intercept.clear(bartererId, record)
        record.hasArrived = true
        record.returningToPost = true
        record.returningAfterMeeting = true
        record.postX, record.postY = deps.config.findSpawnLocation(barterer.x, barterer.y, barterer.z)
        record.postZ = barterer.z
        record.approachTargetX, record.approachTargetY, record.approachTargetZ = nil, nil, nil
        record.routeStartX, record.routeStartY, record.routeTargetX, record.routeTargetY = nil, nil, nil, nil
        record.routeStandoff = nil
        record.continuingTrip = false
        record.departureAtHours = nil
        record.state = "Return"
        deps.serverStateFor(bartererId).lostSightAt = nil
        Bartering.bumpLiveRev(record)
    end

    local function beginReturnHome(bartererId, knownPlayers, zombie, cooldownSeconds, hostile)
        local lifeState = Bartering.getBartererLifeState(bartererId)
        if BarteringTiming.remainingHours(lifeState.returningHomeAt) <= 0 then
            local worldAgeHours = getGameTime():getWorldAgeHours()
            local cooldownGameHours = (cooldownSeconds or 0) / BarteringTiming.realSecondsPerGameHour()
            lifeState.returningHomeAt = worldAgeHours + cooldownGameHours
            Bartering.markBartererDataDirty(bartererId)
        end

        local revealed = {}
        local function reveal(player)
            if player and not revealed[player] then
                revealed[player] = true
                deps.sendToClient(player, "bartererReturningHome", {
                    bartererId = bartererId,
                    hostile = hostile == true or nil,
                })
            end
        end
        for _, player in ipairs(knownPlayers or {}) do
            reveal(player)
        end
        if zombie then
            BarteringAIUtils.forEachPlayer(function(player)
                if BarteringAIUtils.distanceSqBetween(player, zombie) <= REVEAL_DISTANCE_SQ then
                    reveal(player)
                end
            end)
        end
    end

    local function sendBartererHome(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        if not barterer then
            return
        end

        if deps.pendingCalls[bartererId] then
            deps.cancelBartererMeeting(player, bartererId)
        end

        local record = Bartering.getLiveRecord(bartererId)
        if not record or record.unloaded or record.homeResident then
            return
        end

        local owner = Bartering.findOnlinePlayer(record.master) or player
        local zombie = deps.state.serverZombies[bartererId]
        local travelSeconds = BarteringTiming.travelSeconds(zombie:getX(), zombie:getY(),
            barterer.x, barterer.y, barterer.travelSecondsPerTile)
        startReturnHome(bartererId, record, barterer)
        beginReturnHome(bartererId, { owner }, zombie, travelSeconds)
        deps.sendToClient(owner, "playerSay", { text = Bartering.getBartererDisplayName(barterer.id) .. " is returning home" })
    end

    local function sendPlayerBarterersHome(player)
        local username = player:getUsername()
        for bartererId in pairs(Bartering.Barterers) do
            local call = deps.pendingCalls[bartererId]
            local record = Bartering.getLiveRecord(bartererId)
            local ownsCall = call ~= nil and call.player == player
            local ownsRecord = record ~= nil and not record.unloaded
                and not record.homeResident and record.master == username
            if ownsCall or ownsRecord then
                print(string.format("[Bartering][Return] sending %s home for %s | pendingCall=%s master=%s",
                    tostring(bartererId), tostring(username), tostring(ownsCall),
                    tostring(record and record.master)))
                sendBartererHome(player, bartererId)
            end
        end
    end

    local function debugSendAllHomeNow(player)
        for bartererId in pairs(Bartering.Barterers) do
            local call = deps.pendingCalls[bartererId]
            local master = call and call.player or player
            local record = Bartering.getLiveRecord(bartererId)
            if record and not record.homeResident then
                master = Bartering.findOnlinePlayer(record.master) or master
            end

            deps.consumePendingCall(bartererId)
            deps.despawnBarterer(bartererId)
            BarteringHire.clearHiredState(bartererId)
            deps.config.clearBartererDeath(bartererId)
            Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, nil)

            local lifeState = Bartering.getBartererLifeState(bartererId)
            lifeState.returningHomeAt = nil
            Bartering.markBartererDataDirty(bartererId)
            Bartering.clearReturningHomeKnowledge(bartererId)

            deps.setBartererAvailability(master, bartererId, true)
            deps.setBartererETA(master, bartererId, 0, false)
            deps.sendToClient(master, "clearBartererSighting", { bartererId = bartererId })
        end
    end

    local function shouldExpireReturningHome(bartererId, record)
        local st = deps.serverStateFor(bartererId)
        if st.visible then
            st.lostSightAt = nil
            return false
        end
        local now = BarteringTiming.now()
        if not st.lostSightAt then
            st.lostSightAt = now
            return false
        end
        if not BarteringTiming.hasElapsed(st.lostSightAt, RETURN_OUT_OF_SIGHT_GRACE_MS) then
            return false
        end
        print("[Bartering][ServerDebug] barterer " .. tostring(bartererId)
            .. " out of sight " .. tostring(now - st.lostSightAt) .. "ms while returning; expiring")
        return true
    end

    local function finishTripHome(bartererId, record, fromX, fromY, homeX, homeY)
        local barterer = Bartering.Barterers[bartererId]
        if not homeX then
            homeX = barterer and barterer.x
            homeY = barterer and barterer.y
        end
        local travelSeconds = 0
        local returnTrip
        if barterer and homeX and homeY then
            travelSeconds = BarteringTiming.travelSeconds(
                fromX, fromY, homeX + 0.5, homeY + 0.5, barterer.travelSecondsPerTile)
            returnTrip = {
                bartererId = bartererId,
                startX = fromX,
                startY = fromY,
                targetX = homeX + 0.5,
                targetY = homeY + 0.5,
                elapsedMs = 0,
                remainingMs = math.floor(travelSeconds * 1000),
            }
        end
        local arriveHomeAtMs = BarteringTiming.msFromSeconds(travelSeconds)
        local master = Bartering.findOnlinePlayer(record.master)

        beginReturnHome(bartererId, { master }, nil, travelSeconds)

        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, {
            arriveHomeAtMs = arriveHomeAtMs,
            remainingMs = math.max(0, arriveHomeAtMs - BarteringTiming.now()),
            fromX = fromX,
            fromY = fromY,
            homeX = homeX + 0.5,
            homeY = homeY + 0.5,
            totalMs = math.max(1, math.floor(travelSeconds * 1000)),
        })
        deps.setBartererAvailability(master, bartererId, true)
        deps.setBartererETA(master, bartererId, 0, false)
        if returnTrip then
            deps.sendToClient(master, "returnTrip", returnTrip)
        end
        deps.despawnBarterer(bartererId)

        print(string.format(
            "[Bartering][ServerDebug] barterer %s despawned returning home; finishes trip in %.0fs arriveHomeAtMs=%d",
            tostring(bartererId), travelSeconds, arriveHomeAtMs))
    end

    local function handleExpiryReturningHome(bartererId, record, zombie)
        finishTripHome(bartererId, record, zombie:getX(), zombie:getY(), record.postX, record.postY)
    end

    local function sendUnloadedHome(bartererId, record)
        local homeX, homeY
        if record.returningAfterMeeting then
            homeX, homeY = record.postX, record.postY
        end
        finishTripHome(bartererId, record, record.x, record.y, homeX, homeY)
    end

    local function restoreReturningHome(now)
        for bartererId, record in pairs(ModData.getOrCreate(RETURNING_HOME_REGISTRY)) do
            if record and record.remainingMs then
                record.arriveHomeAtMs = now + tonumber(record.remainingMs)
                print(string.format("[Bartering][Call] restored %s returning home, %.0fs left",
                    tostring(bartererId), tonumber(record.remainingMs) / 1000))
            end
        end
    end

    return {
        startReturnHome = startReturnHome,
        beginReturnHome = beginReturnHome,
        sendBartererHome = sendBartererHome,
        sendPlayerBarterersHome = sendPlayerBarterersHome,
        debugSendAllHomeNow = debugSendAllHomeNow,
        shouldExpireReturningHome = shouldExpireReturningHome,
        handleExpiryReturningHome = handleExpiryReturningHome,
        sendUnloadedHome = sendUnloadedHome,
        restoreReturningHome = restoreReturningHome,
    }
end

return BarteringReturn