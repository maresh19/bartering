local getCell = _G["getCell"]
local ZombieIdleState = _G["ZombieIdleState"]
local AdjacentFreeTileFinder = _G["AdjacentFreeTileFinder"]
local BehaviorResult = _G["BehaviorResult"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTasks = require "BarteringTasks"
local BarteringTiming = require "BarteringTiming"
local BarteringPathTrace = require "BarteringPathTrace"

BarteringActions = BarteringActions or {}

local BarteringPathing = {}

local TUNE = {}
TUNE.RETURN_TO_POST_DISTANCE = 1.35
TUNE.ARRIVED_AT_POST_DISTANCE = 1.10
TUNE.RETURN_START_AFTER_FAR_TICKS = 45
TUNE.RESIDENT_POST_CLEAR_DISTANCE = 2
TUNE.IDLE_TURN_INTERVAL_TICKS = 360
TUNE.RETURN_REPATH_COOLDOWN_TICKS = 12
TUNE.RETURN_DOOR_RETRY_COOLDOWN_TICKS = 20
TUNE.RETURN_NON_MOVING_REPATH_TICKS = 20
TUNE.RETURN_AGGRESSIVE_REPATH_TICKS = 60
TUNE.RETURN_STUCK_TICKS = 180
TUNE.RETURN_DETOUR_STUCK_TICKS = 45
TUNE.RETURN_DETOUR_HOLD_TICKS = 40
TUNE.RETURN_DETOUR_COOLDOWN_TICKS = 120
TUNE.RETURN_PLAYER_BLOCK_DISTANCE_SQ = 2.25
TUNE.RETURN_DETOUR_RADIUS_DEFAULT = 2
TUNE.RETURN_DETOUR_RADIUS_PLAYER_BLOCK = 4
TUNE.RETURN_NEAR_POST_SETTLE_DISTANCE = 1.60
TUNE.RETURN_HOSTILE_RESET_TICKS = 12
TUNE.RETURN_PROGRESS_EPSILON_SQ = 0.0025
TUNE.RETURN_PATH_FAIL_REPATH_TICKS = 8
TUNE.APPROACH_CONTINUE_REPATH_TICKS = 12
TUNE.APPROACH_HARD_RESET_TICKS = 30
TUNE.APPROACH_TARGET_REFRESH_TICKS = 60
TUNE.RETURN_PATH_FAIL_DETOUR_FAILS = 2
TUNE.THREAT_SPRINT_MOVEMENT_SPEED = 1.00
TUNE.RETURN_MOVEMENT_SPEED = 1.00
TUNE.RETURN_OBSTRUCTION_LOG_TICKS = 10
TUNE.APPROACH_TARGET_STALE_DISTANCE_SQ = 250 * 250
TUNE.RETURN_MAX_LEG_DISTANCE = 100

TUNE.MOVE_PROGRESS_MIN = 0.5
TUNE.MOVE_RETRY_COOLDOWN_TICKS = 60

local clearGoal = BarteringAIUtils.clearGoal
local publishGoal = BarteringAIUtils.publishGoal
local setVariableIfChanged = BarteringAIUtils.setVariableIfChanged

local function calcAngle(x1, y1, x2, y2)
    return math.deg(math.atan2(y2 - y1, x2 - x1))
end

BarteringActions.Move = {}

BarteringActions.Move.onStart = function(zombie, task)
    local brain = BarteringTasks.GetBrain(zombie)
    brain.moveStartX, brain.moveStartY = zombie:getX(), zombie:getY()

    if not zombie:getSquare():isFree(false) then
        local asquare = AdjacentFreeTileFinder.Find(zombie:getSquare(), zombie)
        if asquare then
            BarteringPathTrace.counter(zombie, "move.start.nudgedOffBlockedTile")
            zombie:setX(asquare:getX() + 0.5)
            zombie:setY(asquare:getY() + 0.5)
        end
    end

    zombie:setVariable("BartererWalkType", task.walkType)

    if not BarteringTasks.IsMoving(zombie) then
        BarteringTasks.SetMoving(zombie, true)
    elseif task.walkType == "BartererSprint" then
        local angleDifference = zombie:getDirectionAngle()
            - calcAngle(zombie:getX(), zombie:getY(), task.x, task.y)
        if angleDifference > 180 then
            angleDifference = angleDifference - 360
        elseif angleDifference < -180 then
            angleDifference = angleDifference + 360
        end
        if math.abs(angleDifference) > 130 then
            zombie:faceLocation(task.x, task.y)
        end
    end

    zombie:getPathFindBehavior2():pathToLocation(task.x, task.y, task.z)
    BarteringPathTrace.counter(zombie, "move.pathToLocation")

    return true
end

BarteringActions.Move.onWorking = function(zombie, task)
    setVariableIfChanged(zombie, "BartererWalkType", task.walkType)

    local result = zombie:getPathFindBehavior2():update()

    if result == BehaviorResult.Failed then
        BarteringPathTrace.counter(zombie, "move.result.failed")
        return true
    end
    if result == BehaviorResult.Succeeded then
        BarteringPathTrace.counter(zombie, "move.result.succeeded")
        return true
    end

    return false
end

BarteringActions.Move.onComplete = function(zombie, task)
    local brain = BarteringTasks.GetBrain(zombie)
    local mdx = zombie:getX() - (brain.moveStartX or zombie:getX())
    local mdy = zombie:getY() - (brain.moveStartY or zombie:getY())

    if math.sqrt(mdx * mdx + mdy * mdy) < TUNE.MOVE_PROGRESS_MIN then
        BarteringPathTrace.counter(zombie, "move.complete.noProgress")
        brain.moveFailures = (brain.moveFailures or 0) + 1
        brain.moveCooldown = TUNE.MOVE_RETRY_COOLDOWN_TICKS
        if brain.moveFailures == 1 or (brain.moveFailures % 10) == 0 then
            print(string.format("[Bartering][Task] %s | Move made no progress | target=%d,%d dist=%.0f failures=%d",
                tostring(zombie:getVariableString("BartererId")),
                task.x, task.y,
                math.sqrt((task.x - zombie:getX()) ^ 2 + (task.y - zombie:getY()) ^ 2),
                brain.moveFailures))
        end
    else
        BarteringPathTrace.counter(zombie, "move.complete.progressed")
        brain.moveFailures = 0
    end

    BarteringAIUtils.clearPathing(zombie)
    return true
end

local function findSpawnLocation(x, y, z)
    if BarteringAIUtils.isStandableSquare(getCell():getGridSquare(x, y, z)) then
        return x, y
    end

    for radius = 1, 6 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local square = getCell():getGridSquare(x + dx, y + dy, z)
                    if BarteringAIUtils.isStandableSquare(square) then
                        return x + dx, y + dy
                    end
                end
            end
        end
    end

    for radius = 1, 4 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local square = getCell():getGridSquare(x + dx, y + dy, z)
                if square and square:isFree(false) then
                    return x + dx, y + dy
                end
            end
        end
    end

    return x, y
end

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

local function isFarFromPost(entry, zombie, returnDistance)
    if not entry.postX or not entry.postY or not entry.postZ then
        return false
    end

    return zombie:getZ() ~= entry.postZ
        or BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), entry.postX, entry.postY) > (returnDistance * returnDistance)
end

local function isAtPost(entry, zombie, arrivedDistance, strictArrival)
    if not entry.postX or not entry.postY or not entry.postZ then
        return false
    end

    if strictArrival then
        return zombie:getZ() == entry.postZ
            and math.floor(zombie:getX()) == entry.postX
            and math.floor(zombie:getY()) == entry.postY
    end

    if zombie:getZ() == entry.postZ
        and math.floor(zombie:getX()) == entry.postX
        and math.floor(zombie:getY()) == entry.postY then
        return true
    end

    return zombie:getZ() == entry.postZ
        and BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), entry.postX, entry.postY) <= (arrivedDistance * arrivedDistance)
end

local function clearResidentPostIntruders(entry, residentZombie, clearDistance)
    if not entry.homeResident or not entry.postX or not entry.postY or not entry.postZ then
        return
    end

    local zombies = getCell():getZombieList()
    for i = zombies:size() - 1, 0, -1 do
        local zombie = zombies:get(i)
        if zombie ~= residentZombie and not zombie:isDead() and zombie:getZ() == entry.postZ then
            if BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), entry.postX, entry.postY) <= (clearDistance * clearDistance) then
                zombie:removeFromWorld()
                zombie:removeFromSquare()
            end
        end
    end
end

function BarteringPathing.new(config)
    local suppressZombieCombat = BarteringAIUtils.suppressZombieCombat
    local BUMP_ANIM_GRACE_TICKS = 10

    local function shouldPreserveBumpAnimation(entry, zombie)
        if not entry then
            return false
        end

        local actionName = zombie:getActionStateName() or ""
        if actionName == "bumped" or zombie:isCollidedThisFrame() then
            entry.bumpAnimGraceTicks = BUMP_ANIM_GRACE_TICKS
        end

        entry.bumpAnimGraceTicks = entry.bumpAnimGraceTicks or 0
        if entry.bumpAnimGraceTicks > 0 then
            entry.bumpAnimGraceTicks = entry.bumpAnimGraceTicks - 1
            return true
        end

        return false
    end

    local function maintainPassiveBumpState(entry, zombie)
        zombie:setVariable("NoLungeAttack", true)
        if shouldPreserveBumpAnimation(entry, zombie) then
            return
        end

        zombie:setVariable("BumpAnimFinished", true)
        if zombie:getActionStateName() ~= "bumped" then
            zombie:setBumpType("")
        end
    end

    local function maintainSuppression(entry, zombie)
        suppressZombieCombat(zombie)
        maintainPassiveBumpState(entry, zombie)
    end

    local function forceReturnNeutralState(entry, zombie)
        zombie:setStateMachineLocked(false)
        zombie:changeState(ZombieIdleState.instance())
        maintainSuppression(entry, zombie)
    end

    local function applyWaitingState(entry, zombie)
        maintainSuppression(entry, zombie)
        setVariableIfChanged(zombie, "MovementSpeed", "1.00")
        setVariableIfChanged(zombie, "BartererState", "Waiting")
    end

    local function openNearbyDoor(zombie, skipWindows)
        local opened = BarteringAIUtils.tryOpenNearbyDoor(zombie, skipWindows)
        if opened == "door" then
            config.logBartererServerDebug(zombie, "return opened nearby door; reinitiate path", "Return")
        elseif opened == "window" then
            config.logBartererServerDebug(zombie, "return opened nearby window; reinitiate path", "Return")
        end
        return opened ~= nil
    end

    local function updateApproachCrowding(entry, zombie)
        local hasApproachTarget = entry.approachTargetX ~= nil and entry.approachTargetY ~= nil and entry.approachTargetZ ~= nil
        local targetX = hasApproachTarget and entry.approachTargetX or (entry.master and entry.master:getX())
        local targetY = hasApproachTarget and entry.approachTargetY or (entry.master and entry.master:getY())
        local targetZ = hasApproachTarget and entry.approachTargetZ or (entry.master and entry.master:getZ())

        if targetX ~= nil then
            BarteringPathTrace.counter(zombie, "scan.approachCrowdList")
        end

        entry.approachCrowded = targetX ~= nil
            and BarteringAIUtils.countZombiesAround(targetX, targetY, targetZ, BarteringAIUtils.APPROACH_CROWD_DISTANCE_SQ) >= BarteringAIUtils.APPROACH_CROWD_MIN

        entry.withinApproachFightRange = false
        if targetX ~= nil then
            local dx = zombie:getX() - targetX
            local dy = zombie:getY() - targetY
            local dz = zombie:getZ() - targetZ
            entry.withinApproachFightRange = dx * dx + dy * dy + dz * dz <= BarteringAIUtils.APPROACH_FIGHT_RADIUS_SQ
        end
    end

    local function applyWalkType(entry, zombie, bartererState)
        local walkType
        if zombie:getHealth() < 0.8 then
            walkType = "BartererLimp"
        elseif bartererState == "DefendPistol" or bartererState == "DefendKnife" then
            walkType = "WalkAim"
        elseif bartererState == "Return" and entry.returningAfterMeeting then
            walkType = "BartererSprint"
        elseif entry.threatNearby
            and (bartererState == "Approach" or bartererState == "Retreat") then
            walkType = "BartererSprint"
        else
            walkType = "BartererWalk"
        end
        if zombie:getVariableString("BartererWalkType") ~= walkType then
            zombie:setWalkType(walkType)
            zombie:setVariable("BartererWalkType", walkType)
        end
    end

    local function movementSpeedFor(entry)
        if entry.returningToPost then
            return TUNE.RETURN_MOVEMENT_SPEED
        end
        if entry.threatNearby then
            return TUNE.THREAT_SPRINT_MOVEMENT_SPEED
        end
        return 1.00
    end

    local function applyApproachState(entry, zombie)
        maintainSuppression(entry, zombie)
        setVariableIfChanged(zombie, "MovementSpeed", tostring(movementSpeedFor(entry)))
        setVariableIfChanged(zombie, "BartererState", "Approach")
    end

    local function updateIdleFacing(entry, zombie)
        local nearbyPlayer = config.getClosestNearbyPlayer(zombie, 25)
        if not nearbyPlayer then
            return
        end

        entry.idleTurnTicks = (entry.idleTurnTicks or TUNE.IDLE_TURN_INTERVAL_TICKS) - 1
        if entry.idleTurnTicks > 0 then
            return
        end

        entry.idleTurnTicks = TUNE.IDLE_TURN_INTERVAL_TICKS
        zombie:faceLocationF(nearbyPlayer:getX(), nearbyPlayer:getY())
    end

    local function logReturnObstruction(entry, zombie, reason)
        local collided = zombie:isCollidedThisFrame()
        local collideType = zombie:getCollideType()
        local collidedObject = zombie:getCollidedObject()
        local collidedName = collidedObject and collidedObject:getObjectName() or "nil"
        local nearbyPlayer, playerDistanceSq = config.getClosestNearbyPlayer(zombie, TUNE.RETURN_PLAYER_BLOCK_DISTANCE_SQ)
        local playerBlock = nearbyPlayer ~= nil
        print(string.format(
            "[Bartering][ReturnObstruction] %s | reason=%s action=%s collided=%s collideType=%s collidedObject=%s playerBlock=%s playerDistSq=%s pos=%.2f,%.2f,%.2f",
            tostring(zombie:getVariableString("BartererId")),
            tostring(reason),
            tostring(zombie:getActionStateName()),
            tostring(collided),
            tostring(collideType),
            tostring(collidedName),
            tostring(playerBlock),
            tostring(playerDistanceSq),
            zombie:getX(),
            zombie:getY(),
            zombie:getZ()
        ))
    end

    local isReturnHostileAction = BarteringAIUtils.isHostileActionState

    local function clearReturnTarget(entry)
        entry.returnTargetX = nil
        entry.returnTargetY = nil
        entry.returnTargetZ = nil
    end

    local function neutralizeHostileAction(entry, zombie, isReturning)
        local actionName = zombie:getActionStateName() or ""
        if not isReturnHostileAction(actionName) then
            entry.hostileTicks = 0
            return false, actionName
        end

        entry.hostileTicks = (entry.hostileTicks or 0) + 1
        BarteringPathTrace.counter(zombie, "hostileState." .. actionName)
        maintainSuppression(entry, zombie)
        if entry.hostileTicks % TUNE.APPROACH_HARD_RESET_TICKS == 0 then
            forceReturnNeutralState(entry, zombie)
        end

        if not isReturning then
            if entry.hostileTicks == 1 or entry.hostileTicks % TUNE.APPROACH_HARD_RESET_TICKS == 0 then
                config.logBartererServerDebug(zombie, "approach hostile-state neutralized", "Approach")
            end
            return true, zombie:getActionStateName() or ""
        end

        if entry.hostileTicks == 1 or entry.hostileTicks % TUNE.RETURN_OBSTRUCTION_LOG_TICKS == 0 then
            logReturnObstruction(entry, zombie, "hostile-action")
        end

        if entry.hostileTicks % TUNE.RETURN_HOSTILE_RESET_TICKS == 0 then
            clearReturnTarget(entry)
            entry.repathCooldown = 0
            config.logBartererServerDebug(zombie, "return hostile-state path reset", "Return")
        end

        return true, actionName
    end

    local function updateMovement(entry, zombie)
        local isHomeResident = entry.homeResident == true
        local returnDistance = isHomeResident and (TUNE.RETURN_TO_POST_DISTANCE + 0.65) or TUNE.RETURN_TO_POST_DISTANCE
        local arrivedDistance = isHomeResident and (TUNE.ARRIVED_AT_POST_DISTANCE + 0.55) or TUNE.ARRIVED_AT_POST_DISTANCE

        entry.returnFarTicks = entry.returnFarTicks or 0
        entry.stillTicks = entry.stillTicks or 0
        entry.doorRetryCooldown = math.max((entry.doorRetryCooldown or 0) - 1, 0)

        local movedX = zombie:getX() - (entry.lastMoveX or zombie:getX())
        local movedY = zombie:getY() - (entry.lastMoveY or zombie:getY())
        entry.lastMoveX, entry.lastMoveY = zombie:getX(), zombie:getY()
        if movedX * movedX + movedY * movedY < TUNE.RETURN_PROGRESS_EPSILON_SQ then
            entry.stillTicks = entry.stillTicks + 1
        else
            entry.stillTicks = 0
        end

        maintainSuppression(entry, zombie)

        local function openDoorIfStuck()
            if entry.stillTicks < TUNE.RETURN_NON_MOVING_REPATH_TICKS or entry.doorRetryCooldown > 0 then
                return
            end
            entry.doorRetryCooldown = TUNE.RETURN_DOOR_RETRY_COOLDOWN_TICKS
            if openNearbyDoor(zombie) then
                BarteringPathTrace.counter(zombie, "stuck.doorOpened")
                entry.stillTicks = 0
            else
                BarteringPathTrace.counter(zombie, "stuck.noDoorFound")
            end
        end

        if entry.hasArrived then
            clearResidentPostIntruders(entry, zombie, TUNE.RESIDENT_POST_CLEAR_DISTANCE)
            neutralizeHostileAction(entry, zombie, true)

            local isFar = isFarFromPost(entry, zombie, returnDistance)
            entry.returnFarTicks = isFar and (entry.returnFarTicks + 1) or 0

            local strictReturnTrip = entry.returningAfterMeeting == true
            if not entry.returningToPost
                and (strictReturnTrip or entry.returnFarTicks >= TUNE.RETURN_START_AFTER_FAR_TICKS) then
                entry.returningToPost = isFar
            end

            if not entry.returningToPost then
                clearGoal(zombie, "waiting")
                applyWaitingState(entry, zombie)
                updateIdleFacing(entry, zombie)
                BarteringPathTrace.aiStop(zombie, "move.waiting.atPost")
                return
            end

            if isAtPost(entry, zombie, arrivedDistance, strictReturnTrip) then
                entry.returningToPost = false
                entry.returnFarTicks = 0
                entry.returningAfterMeeting = false
                clearGoal(zombie, "return")
                applyWaitingState(entry, zombie)
                updateIdleFacing(entry, zombie)
                config.logBartererServerDebug(zombie, "return completed", "Waiting")
                BarteringPathTrace.aiStop(zombie, "move.return.arrived")
                return
            end

            zombie:setVariable("BartererState", "Return")
            zombie:setVariable("MovementSpeed", tostring(TUNE.RETURN_MOVEMENT_SPEED))

            local legX, legY, clamped = clampReturnLeg(zombie, entry.postX + 0.5, entry.postY + 0.5)
            if clamped and (entry.loggedLegX ~= legX or entry.loggedLegY ~= legY) then
                entry.loggedLegX, entry.loggedLegY = legX, legY
                config.logBartererServerDebug(zombie, string.format(
                    "post %.0f,%.0f too far; walking leg to %.0f,%.0f",
                    entry.postX, entry.postY, legX, legY), "Return")
            end

            publishGoal(zombie, legX, legY, entry.postZ, "return")
            openDoorIfStuck()
            BarteringPathTrace.aiStop(zombie, clamped and "move.return.leg.clamped" or "move.return.leg")
            return
        end

        local master = entry.master
        if not master or master:isDead() then
            clearGoal(zombie, "waiting")
            applyWaitingState(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.waiting.noMaster")
            return
        end

        applyApproachState(entry, zombie)

        local hasApproachTarget = entry.approachTargetX ~= nil and entry.approachTargetY ~= nil
        if hasApproachTarget then
            local staleX = master:getX() - entry.approachTargetX
            local staleY = master:getY() - entry.approachTargetY
            if staleX * staleX + staleY * staleY > TUNE.APPROACH_TARGET_STALE_DISTANCE_SQ then
                config.logBartererServerDebug(zombie, string.format(
                    "approach target %.0f,%.0f is stale; falling back to master",
                    entry.approachTargetX, entry.approachTargetY), "Approach")
                entry.approachTargetX, entry.approachTargetY, entry.approachTargetZ = nil, nil, nil
                hasApproachTarget = false
            end
        end

        local targetX = hasApproachTarget and entry.approachTargetX or master:getX()
        local targetY = hasApproachTarget and entry.approachTargetY or master:getY()
        local targetZ = hasApproachTarget and entry.approachTargetZ or master:getZ()

        local function completeApproachArrival(postX, postY, postZ, logReason)
            clearGoal(zombie, "approach")
            applyWaitingState(entry, zombie)
            forceReturnNeutralState(entry, zombie)
            entry.postX, entry.postY, entry.postZ = postX, postY, postZ
            entry.returningToPost = false
            entry.hasArrived = true
            entry.returnFarTicks = 0
            entry.arrivalTime = getGameTime():getMinutesStamp()
            entry.departureAtMs = BarteringTiming.createCalledInDeparture()
            zombie:setVariable("BartererDepartureAtMs", tostring(entry.departureAtMs))
            config.logBartererServerDebug(zombie, logReason, "Waiting")
            updateIdleFacing(entry, zombie)
        end

        if hasApproachTarget then
            local adx = zombie:getX() - (targetX + 0.5)
            local ady = zombie:getY() - (targetY + 0.5)
            local onTile = math.floor(zombie:getX()) == targetX and math.floor(zombie:getY()) == targetY
            local arrivedSq = TUNE.ARRIVED_AT_POST_DISTANCE * TUNE.ARRIVED_AT_POST_DISTANCE
            if zombie:getZ() == targetZ and (onTile or (adx * adx + ady * ady) <= arrivedSq) then
                completeApproachArrival(
                    onTile and targetX or math.floor(zombie:getX()),
                    onTile and targetY or math.floor(zombie:getY()),
                    targetZ, "arrived at call location")
                BarteringPathTrace.aiStop(zombie, "move.approach.arrivedAtCallLocation")
                return
            end
        else
            if BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), targetX, targetY) <= 4 then
                completeApproachArrival(math.floor(zombie:getX()), math.floor(zombie:getY()),
                    zombie:getZ(), "arrived with player")
                BarteringPathTrace.aiStop(zombie, "move.approach.arrivedWithPlayer")
                return
            end
        end

        neutralizeHostileAction(entry, zombie, false)
        publishGoal(zombie,
            hasApproachTarget and (targetX + 0.5) or targetX,
            hasApproachTarget and (targetY + 0.5) or targetY,
            targetZ,
            hasApproachTarget and "approach.callTarget" or "approach.master")
        openDoorIfStuck()
        BarteringPathTrace.aiStop(zombie, "move.approach.goal")
    end

    return {
        updateMovement = updateMovement,
        applyWalkType = applyWalkType,
        updateApproachCrowding = updateApproachCrowding,
        findSpawnLocation = findSpawnLocation,
        IDLE_TURN_INTERVAL_TICKS = TUNE.IDLE_TURN_INTERVAL_TICKS,
    }
end

return BarteringPathing
