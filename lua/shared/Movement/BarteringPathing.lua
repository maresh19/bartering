local getCell = _G["getCell"]
local ZombieIdleState = _G["ZombieIdleState"]
local events = _G["Events"]
local AdjacentFreeTileFinder = _G["AdjacentFreeTileFinder"]
local BehaviorResult = _G["BehaviorResult"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTasks = require "Movement/BarteringTasks"
local BarteringTiming = require "BarteringTiming"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringDialogue = require "BarteringDialogue"
local BarteringClimbingUtils = require "Movement/BarteringClimbingUtils"
local BarteringWindows = require "Movement/BarteringWindows"
local BarteringFences = require "Movement/BarteringFences"
local BarteringReturn = require "Movement/BarteringReturn"
local BarteringApproach = require "Movement/BarteringApproach"
local BarteringArrive = require "Movement/BarteringArrive"

BarteringActions = BarteringActions or {}

local BarteringPathing = {}

local TUNE = {}
TUNE.IDLE_TURN_INTERVAL_TICKS = 360
TUNE.DOOR_RETRY_COOLDOWN_TICKS = 20
TUNE.STUCK_SAMPLE_TICKS = 30
TUNE.STUCK_PROGRESS_MIN = 0.75
TUNE.BLOCKED_DOOR_HOLD_DISTANCE_SQ = 2 * 2
TUNE.BLOCKED_BUMP_TIMEOUT_TICKS = 90
TUNE.BLOCKED_HOLD_DRIFT_SQ = 0.6 * 0.6
TUNE.SCRIPTED_BUMP_HOLD_MS = 8000
TUNE.IDLE_EMOTE_MIN_MS = 8000
TUNE.IDLE_EMOTE_MAX_MS = 12000

local IDLE_EMOTES = {
    "ExtBentDouble", "ExtBridgeNose", "ExtChewNails", "ExtCough",
    "ExtIdle1", "ExtIdle2", "ExtIdle3", "ExtIdle4",
    "ExtPainHead1", "ExtPainHead2", "ExtPainStomach1", "ExtPainStomach2",
    "ExtPainArmL", "ExtPainArmR", "ExtPainHandL", "ExtPainHandR",
    "ExtPainLegL", "ExtPainLegR", "ExtPainTorso", "ExtPullAtCollar",
    "ExtShiftWeight", "ExtShiver", "ExtSneeze1", "ExtSneeze2",
    "ExtTiredStretch", "ExtWipeArmL", "ExtWipeArmR", "ExtWipeBrow",
    "ExtWipeHead", "ExtWipeLegL", "ExtWipeLegR", "ExtWipeTorso",
    "ExtYawn",
}
TUNE.HOSTILE_HARD_RESET_TICKS = 30
TUNE.MOVE_PROGRESS_MIN = 0.5
TUNE.MOVE_RETRY_COOLDOWN_MS = 1000

local clearGoal = BarteringAIUtils.clearGoal
local setVariableIfChanged = BarteringAIUtils.setVariableIfChanged

local SNAP_DOT = -0.643

local function snapTowardTask(zombie, task, phase)
    local dot = zombie:getDotWithForwardDirection(task.x, task.y)
    if dot >= SNAP_DOT then
        return
    end
    local before = zombie:getDirectionAngle()
    zombie:faceLocationF(task.x, task.y)
    print(string.format("[Bartering][Task] %s | SNAP %s | action=%s facing %.0f -> %.0f dot=%.2f",
        tostring(zombie:getVariableString("BartererId")), phase, tostring(zombie:getActionStateName()),
        before, zombie:getDirectionAngle(), dot))
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
    end
    if task.walkType == "BartererSprint" then
        snapTowardTask(zombie, task, "start")
    end

    zombie:getPathFindBehavior2():pathToLocation(task.x, task.y, task.z)
    zombie:getPathFindBehavior2():update()
    BarteringPathTrace.counter(zombie, "move.pathToLocation")

    return true
end

BarteringActions.Move.onWorking = function(zombie, task)
    setVariableIfChanged(zombie, "BartererWalkType", task.walkType)
    if task.walkType == "BartererSprint" and zombie:getActionStateName() == "walktoward" then
        snapTowardTask(zombie, task, "working")
    end

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
        brain.moveRetryAtMs = BarteringTiming.now() + TUNE.MOVE_RETRY_COOLDOWN_MS
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

local function setSprint(entry, zombie, sprinting)
    zombie:setVariable("MovementSpeed", "1.00")
    if sprinting then
        zombie:setPathing(true)
        zombie:setWalkType("BartererSprint")
        zombie:setVariable("BartererWalkType", "BartererSprint")
    end
end
BarteringPathing.setSprint = setSprint

function BarteringPathing.new(config)
    local suppressZombieCombat = BarteringAIUtils.suppressZombieCombat
    local BUMP_ANIM_GRACE_TICKS = 10
    local BUMP_ANIM_MAX_HELD_TICKS = 60

    local function shouldPreserveBumpAnimation(entry, zombie)
        if not entry then
            return false
        end

        local actionName = zombie:getActionStateName() or ""
        if actionName == "bumped" or zombie:isCollidedThisFrame() then
            entry.bumpAnimGraceTicks = BUMP_ANIM_GRACE_TICKS
            entry.bumpAnimHeldTicks = (entry.bumpAnimHeldTicks or 0) + 1
        else
            entry.bumpAnimHeldTicks = 0
        end

        if entry.bumpAnimHeldTicks > BUMP_ANIM_MAX_HELD_TICKS then
            BarteringPathTrace.counter(zombie, "bump.forcedFinish")
            entry.bumpAnimGraceTicks = 0
            return false
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

        if BarteringTasks.GetBrain(zombie).windowOpening then
            return
        end

        if entry.scriptedBumpAtMs then
            if zombie:getVariableBoolean("BumpAnimFinished")
                or BarteringTiming.hasElapsed(entry.scriptedBumpAtMs, TUNE.SCRIPTED_BUMP_HOLD_MS) then
                entry.scriptedBumpAtMs = nil
            else
                return
            end
        end

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

    local function settleInPlace(entry, zombie, bartererState)
        entry.stillTicks = 0
        entry.stuckSample = false
        entry.lastGoalDistance = nil
        setVariableIfChanged(zombie, "MovementSpeed", "1.00")
        setVariableIfChanged(zombie, "BartererState", bartererState)
    end

    local function applyBlockedState(entry, zombie)
        settleInPlace(entry, zombie, entry.blockedKind or "BlockedByDoor")

        if not entry.blockedHoldX then
            entry.blockedHoldX, entry.blockedHoldY = zombie:getX(), zombie:getY()
        end

        local dx = zombie:getX() - entry.blockedHoldX
        local dy = zombie:getY() - entry.blockedHoldY
        if (dx * dx + dy * dy) > TUNE.BLOCKED_HOLD_DRIFT_SQ then
            BarteringPathTrace.counter(zombie, "blocked.driftPinned")
            zombie:setX(entry.blockedHoldX)
            zombie:setY(entry.blockedHoldY)
        end
    end

    local function applyWaitingState(entry, zombie)
        settleInPlace(entry, zombie, "Waiting")
    end

    local function cancelMove(zombie, counterName)
        if BarteringTasks.HasTask(zombie) then
            BarteringPathTrace.counter(zombie, counterName)
            BarteringTasks.StopMovement(zombie)
            zombie:changeState(ZombieIdleState.instance())
        end
    end

    local function holdBlocked(entry, zombie, counterName)
        entry.blockedBumpTicks = (entry.blockedBumpTicks or 0) + 1
        if entry.blockedBumpTicks == TUNE.BLOCKED_BUMP_TIMEOUT_TICKS
            or zombie:getVariableBoolean("BumpAnimFinished") then
            zombie:setVariable("BumpAnimFinished", true)
            zombie:setBumpType("")
        end
        cancelMove(zombie, counterName)
        applyBlockedState(entry, zombie)
    end

    local function clearBlockedHold(entry)
        entry.blockedOpenable = nil
        entry.blockedKind = nil
        entry.blockedBumpTicks = nil
        entry.blockedHoldX, entry.blockedHoldY = nil, nil
    end

    local function openNearbyDoor(entry, zombie)
        local opened, blocked = BarteringAIUtils.tryOpenNearbyDoor(entry, zombie)
        if opened then
            config.logBartererServerDebug(zombie, "opened nearby door; reinitiate path",
                zombie:getVariableString("BartererState"))
        end
        return opened ~= nil, blocked
    end

    local function tryDoorsIfStuck(entry, zombie)
        if not entry.stuckSample or entry.doorRetryCooldown > 0 then
            return false
        end
        entry.doorRetryCooldown = TUNE.DOOR_RETRY_COOLDOWN_TICKS
        local opened, blocked = openNearbyDoor(entry, zombie)
        if opened then
            BarteringPathTrace.counter(zombie, "stuck.doorOpened")
            entry.stillTicks = 0
            entry.stuckSample = false
        end
        return true, opened, blocked
    end

    local function reportBlockedOpenable(entry, zombie, blocked)
        local key = BarteringAIUtils.openableKey(blocked)
        if entry.blockedOpenables[key] then
            return
        end
        entry.blockedOpenables[key] = true
        entry.blockedOpenable = blocked
        entry.blockedKind = "BlockedByDoor"

        entry.blockedBumpTicks = 0
        clearGoal(zombie, "blockedByDoor")
        applyBlockedState(entry, zombie)
        cancelMove(zombie, "blockedByDoor.cancelledMove")

        zombie:faceThisObject(blocked)
        BarteringAIUtils.playScriptedBump(entry, zombie, "TryDoor")
        BarteringAIUtils.sayBarterer(entry.bartererId, BarteringDialogue.Movement.doorLocked)

        BarteringPathTrace.counter(zombie, "stuck.lockedOpenable")
        local square = blocked:getSquare()
        local objects = square and square:getObjects()
        if objects then
            local nearby = {}
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                nearby[#nearby + 1] = string.format("%s@%.0f,%.0f/%s",
                    object:getClass():getSimpleName(), object:getX(), object:getY(), tostring(object:getSpriteName()))
            end
            config.logBartererServerDebug(zombie, "blocked square objects=" .. table.concat(nearby, ";"), "Blocked")
        end
        config.logBartererServerDebug(zombie, string.format(
            "blocked by locked openable at %.0f,%.0f type=%s [%s]; ignoring it from now on",
            blocked:getX(), blocked:getY(), tostring(blocked:getClass():getSimpleName()),
            BarteringAIUtils.doorFlags(blocked)), "Blocked")
        config.report(entry, "doorCheck", {
            x = math.floor(blocked:getX()),
            y = math.floor(blocked:getY()),
            z = math.floor(blocked:getZ()),
            clientFlags = BarteringAIUtils.doorFlags(blocked),
        })
    end

    local function reportDoorLocked(entry, zombie, door)
        entry.blockedOpenables[BarteringAIUtils.openableKey(door)] = nil
        reportBlockedOpenable(entry, zombie, door)
    end

    local function holdAtBlockedDoor(entry, zombie)
        if not entry.blockedOpenable then
            return false
        end

        local blockedDistanceSq = BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(),
            entry.blockedOpenable:getX(), entry.blockedOpenable:getY())
        if entry.blockedOpenable:IsOpen() or blockedDistanceSq > TUNE.BLOCKED_DOOR_HOLD_DISTANCE_SQ then
            config.logBartererServerDebug(zombie, "no longer held at blocked opening; resuming route", "Blocked")
            clearBlockedHold(entry)
            return false
        end

        clearGoal(zombie, "blockedByDoor")
        holdBlocked(entry, zombie, "blockedByDoor.cancelledMove")
        zombie:faceThisObject(entry.blockedOpenable)
        BarteringPathTrace.aiStop(zombie, "move.waiting.blockedByDoor")
        return true
    end

    local function neutralizeHostileAction(entry, zombie)
        local actionName = zombie:getActionStateName() or ""
        if not BarteringAIUtils.isHostileActionState(actionName) then
            entry.hostileTicks = 0
            return false, false
        end

        entry.hostileTicks = (entry.hostileTicks or 0) + 1
        BarteringPathTrace.counter(zombie, "hostileState." .. actionName)
        maintainSuppression(entry, zombie)
        local reset = entry.hostileTicks % TUNE.HOSTILE_HARD_RESET_TICKS == 0
        if reset then
            forceReturnNeutralState(entry, zombie)
        end
        return true, reset
    end

    local function applyWalkType(entry, zombie, bartererState)
        local walkType
        if zombie:getHealth() < 0.8 then
            walkType = "BartererLimp"
        elseif bartererState == "DefendPistol" or bartererState == "DefendKnife" then
            walkType = "WalkAim"
        elseif entry.continuingTrip then
            walkType = "BartererSprint"
        elseif bartererState == "Return" and entry.returningAfterMeeting then
            walkType = "BartererSprint"
        elseif entry.threatNearby
            and (bartererState == "Approach" or bartererState == "Retreat") then
            walkType = "BartererSprint"
        elseif entry.master and not entry.hireWarningActive
            and entry.master:isSprinting() and zombie:getHealth() >= 0.8 then
            walkType = "BartererSprint"
        else
            walkType = "BartererWalk"
        end
        if zombie:getVariableString("BartererWalkType") ~= walkType then
            zombie:setWalkType(walkType)
            zombie:setVariable("BartererWalkType", walkType)
        end
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

    local function updateIdleEmote(entry, zombie)
        local now = BarteringTiming.now()
        if not entry.idleEmoteAtMs or zombie:getActionStateName() ~= "idle"
            or now - (entry.idleEmoteSeenMs or 0) > 1000 then
            entry.idleEmoteAtMs = now + ZombRand(TUNE.IDLE_EMOTE_MIN_MS, TUNE.IDLE_EMOTE_MAX_MS + 1)
        end
        entry.idleEmoteSeenMs = now
        if now < entry.idleEmoteAtMs then
            return
        end
        entry.idleEmoteAtMs = now + ZombRand(TUNE.IDLE_EMOTE_MIN_MS, TUNE.IDLE_EMOTE_MAX_MS + 1)
        entry.idleEmoteIndex = (entry.idleEmoteIndex or ZombRand(#IDLE_EMOTES)) % #IDLE_EMOTES + 1
        BarteringAIUtils.playScriptedBump(entry, zombie, IDLE_EMOTES[entry.idleEmoteIndex])
    end

    local function sampleStuck(entry, zombie)
        entry.stillTicks = entry.stillTicks or 0

        local climbBrain = BarteringTasks.GetBrain(zombie)
        if zombie:getVariableBoolean("BartererClimbing")
            or (climbBrain.fenceCooldown and climbBrain.fenceCooldown > 0)
            or zombie:getActionStateName() == "climbfence" then
            entry.stillTicks = 0
            entry.stuckSample = false
            entry.lastGoalDistance = nil
            entry.lastSampleX, entry.lastSampleY = nil, nil
            entry.unreachableAttempts = 0
        end

        entry.stillTicks = entry.stillTicks + 1
        if entry.stillTicks < TUNE.STUCK_SAMPLE_TICKS then
            return
        end

        local goalX, goalY = BarteringAIUtils.getGoal(zombie)
        local movedX = zombie:getX() - (entry.lastSampleX or zombie:getX())
        local movedY = zombie:getY() - (entry.lastSampleY or zombie:getY())
        local moved = math.sqrt(movedX * movedX + movedY * movedY)
        local wasStill = entry.lastSampleX ~= nil and moved < TUNE.STUCK_PROGRESS_MIN
        entry.lastSampleX, entry.lastSampleY = zombie:getX(), zombie:getY()

        if goalX and goalY then
            local goalDistance = math.sqrt(
                BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), goalX, goalY))
            entry.stuckSample = wasStill
                and entry.lastGoalDistance ~= nil
                and (entry.lastGoalDistance - goalDistance) < TUNE.STUCK_PROGRESS_MIN
            entry.lastGoalDistance = goalDistance
        else
            entry.stuckSample = false
            entry.lastGoalDistance = nil
        end
        entry.stillTicks = 0
    end

    local shared = {
        forceReturnNeutralState = forceReturnNeutralState,
        applyWaitingState = applyWaitingState,
        applyBlockedState = applyBlockedState,
        holdBlocked = holdBlocked,
        clearBlockedHold = clearBlockedHold,
        cancelMove = cancelMove,
        openNearbyDoor = openNearbyDoor,
        tryDoorsIfStuck = tryDoorsIfStuck,
        reportBlockedOpenable = reportBlockedOpenable,
        reportDoorLocked = reportDoorLocked,
        neutralizeHostileAction = neutralizeHostileAction,
        updateIdleFacing = updateIdleFacing,
        updateIdleEmote = updateIdleEmote,
        getClosestNearbyPlayer = config.getClosestNearbyPlayer,
        logBartererServerDebug = config.logBartererServerDebug,
        report = config.report,
    }

    local returnLogic = BarteringReturn.newMovement(shared)
    local arriveLogic = BarteringArrive.new(shared)
    local approachLogic = BarteringApproach.new(shared, arriveLogic)

    local function updateMovement(entry, zombie)
        entry.doorRetryCooldown = math.max((entry.doorRetryCooldown or 0) - 1, 0)
        sampleStuck(entry, zombie)
        maintainSuppression(entry, zombie)

        local bartererState = zombie:getVariableString("BartererState")
        applyWalkType(entry, zombie, bartererState)

        if not entry.hasArrived and approachLogic.updateBlockers(entry, zombie) then
            return
        end

        if holdAtBlockedDoor(entry, zombie) then
            return
        end

        if entry.hasArrived then
            returnLogic.update(entry, zombie)
        else
            approachLogic.update(entry, zombie)
        end
    end

    local function separatesFromMaster(entry, zombie, door)
        return BarteringAIUtils.doorSeparates(door, zombie:getX(), zombie:getY(),
            entry.master:getX(), entry.master:getY())
    end

    local function updateHireFollow(entry, zombie)
        entry.doorRetryCooldown = math.max((entry.doorRetryCooldown or 0) - 1, 0)
        sampleStuck(entry, zombie)
        maintainSuppression(entry, zombie)

        if entry.blockedOpenable and not separatesFromMaster(entry, zombie, entry.blockedOpenable) then
            config.logBartererServerDebug(zombie, "blocked door no longer between me and my employer; following again", "Follow")
            clearBlockedHold(entry)
        end

        if holdAtBlockedDoor(entry, zombie) then
            return true
        end

        local attempted, opened, blocked = tryDoorsIfStuck(entry, zombie)
        if not attempted or not blocked or not separatesFromMaster(entry, zombie, blocked) then
            return false
        end
        reportBlockedOpenable(entry, zombie, blocked)
        return true
    end

    return {
        updateMovement = updateMovement,
        updateHireFollow = updateHireFollow,
        applyWalkType = applyWalkType,
        updateApproachCrowding = approachLogic.updateCrowding,
        findSpawnLocation = findSpawnLocation,
        IDLE_TURN_INTERVAL_TICKS = TUNE.IDLE_TURN_INTERVAL_TICKS,
    }
end

local function generateTask(zombie)
    local goalX, goalY, goalZ, goalPrecise = BarteringAIUtils.getGoal(zombie)

    local brain = BarteringTasks.GetBrain(zombie)
    local bartererState = zombie:getVariableString("BartererState")

    BarteringFences.releaseLatchOnStateChange(zombie, brain, bartererState)

    local active = BarteringTasks.GetTask(zombie)

    local currentWalkType = zombie:getVariableString("BartererWalkType") or "BartererWalk"
    if active and active.action == "Move" and active.walkType ~= currentWalkType then
        BarteringPathTrace.counter(zombie, "move.walkTypeUpdatedInPlace")
        active.walkType = currentWalkType
    end

    if active and active.action == "Move" and goalX and not brain.fenceLatchX
        and (active.srcX ~= goalX or active.srcY ~= goalY or active.srcZ ~= goalZ) then
        print(string.format("[Bartering][Task] %s | ABANDON Move | was=%s,%s,%s now=%d,%d,%d aiming=%d,%d",
            tostring(zombie:getVariableString("BartererId")),
            tostring(active.srcX), tostring(active.srcY), tostring(active.srcZ),
            goalX, goalY, goalZ, active.x, active.y))
        BarteringPathTrace.counter(zombie, "move.abandon.goalChanged")
        BarteringTasks.StopTasks(zombie)
        active = nil
    end

    if active and active.hopStep then
        local sdx = zombie:getX() - (active.x + 0.5)
        local sdy = zombie:getY() - (active.y + 0.5)
        if sdx * sdx + sdy * sdy <= 0.25 then
            BarteringPathTrace.counter(zombie, "move.hopStepHandoff")
            BarteringTasks.StopTasks(zombie)
            active = nil
        end
    end

    if active then
        return "activeTask"
    end

    if bartererState == "BlockedByDoor" or bartererState == "BlockedRoute" then
        return "blocked"
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        return "climbing"
    end

    if brain.windowOpening then
        return "windowOpening"
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return "fenceCooldown"
    end

    if brain.moveRetryAtMs and BarteringTiming.now() < brain.moveRetryAtMs then
        return "moveCooldown"
    end

    if not goalX or not goalY or not goalZ then
        return "noGoal"
    end

    if brain.hopStepX then
        local here = zombie:getSquare()
        local stepSquare = getCell():getGridSquare(here:getX() + brain.hopStepX, here:getY() + brain.hopStepY, here:getZ())
        local open = stepSquare ~= nil and stepSquare:isFree(false) and not here:isBlockedTo(stepSquare)
        BarteringClimbingUtils.logClimb(zombie, "stepping off fence", string.format(
            "step=%d,%d open=%s", brain.hopStepX, brain.hopStepY, tostring(open)))
        brain.hopStepX, brain.hopStepY = nil, nil
        if open then
            BarteringTasks.AddTask(zombie, {
                action = "Move",
                x = stepSquare:getX(),
                y = stepSquare:getY(),
                z = stepSquare:getZ(),
                srcX = goalX,
                srcY = goalY,
                srcZ = goalZ,
                walkType = currentWalkType,
                hopStep = true,
                state = "NEW",
                time = 600,
            })
            return "taskCreated.hopStep"
        end
    end

    local goalX, goalY, rawX, rawY, rawZ, fenceApproach = BarteringFences.adjustGoalForFence(
        zombie, brain, goalX, goalY, goalZ, bartererState)

    local dx = zombie:getX() - (goalX + 0.5)
    local dy = zombie:getY() - (goalY + 0.5)
    local exact = fenceApproach or goalPrecise
    local arriveSq = exact and 0.05 or 1.2
    if dx * dx + dy * dy <= arriveSq then
        return fenceApproach and "atFenceApproachTile" or "alreadyAtGoal"
    end

    BarteringPathTrace.goalConsumed(zombie, goalX, goalY, goalZ)
    BarteringTasks.AddTask(zombie, {
        action = "Move",
        x = goalX,
        y = goalY,
        z = goalZ,
        srcX = rawX,
        srcY = rawY,
        srcZ = rawZ,
        walkType = currentWalkType,
        state = "NEW",
        time = 600,
    })
    return fenceApproach and "taskCreated.fenceDetour" or "taskCreated"
end

local FOOTSTEP_DISTANCE = 0.7
local FOOTSTEP_RADIUS = {
    BartererSneak = 3,
    BartererSneakRun = 3,
    BartererWalk = 7,
    BartererLimp = 7,
    WalkAim = 7,
    BartererSprint = 10,
}

local function emitFootsteps(zombie, brain)
    local x, y = zombie:getX(), zombie:getY()
    local dx, dy = x - (brain.stepX or x), y - (brain.stepY or y)
    brain.stepX, brain.stepY = x, y
    brain.stepDistance = (brain.stepDistance or 0) + math.sqrt(dx * dx + dy * dy)
    if brain.stepDistance < FOOTSTEP_DISTANCE then
        return
    end
    brain.stepDistance = 0

    local walkType = zombie:getVariableString("BartererWalkType")
    local sneaking = walkType == "BartererSneak" or walkType == "BartererSneakRun"
    if ZombRand(sneaking and 4 or 2) ~= 0 then
        return
    end
    local radius = FOOTSTEP_RADIUS[walkType]
    if zombie:getCurrentSquare():getRoom() then
        radius = math.floor(radius * 0.5)
    end
    if sneaking then
        radius = math.max(1, radius)
    end
    addSound(zombie, math.floor(x), math.floor(y), math.floor(zombie:getZ()), radius, radius)
    Bartering.logBartererSound(zombie, "worldNoise", "footstep", string.format("radius=%d walk=%s", radius, walkType))
end

local function driveBarterer(zombie)
    if not zombie:getVariableBoolean("Barterer") or (isClient() and zombie:isRemoteZombie()) then
        return
    end
    if zombie:isDead() or zombie:getHealth() <= 0 then
        BarteringTasks.RemoveBrain(zombie)
        BarteringPathTrace.forget(zombie)
        return
    end

    emitFootsteps(zombie, BarteringTasks.GetBrain(zombie))
    zombie:setUseless(false)

    BarteringClimbingUtils.updateClimbRelease(zombie)

    BarteringClimbingUtils.suppressClimbEngine(zombie)

    local proceed, blockedBy = BarteringClimbingUtils.manageActionState(zombie)
    if not proceed then
        BarteringPathTrace.driveStop(zombie, "blocked." .. blockedBy)
        return
    end

    BarteringFences.manageFenceClimbing(zombie)
    BarteringWindows.manageWindowClimbing(zombie)
    local gate = generateTask(zombie)

    local task = BarteringTasks.GetTask(zombie)
    if task then
        BarteringPathTrace.driveStop(zombie, string.format("task.%s.%s", task.action, tostring(task.state)))
        BarteringTasks.ProcessTask(zombie, task)
        return
    end

    BarteringPathTrace.driveStop(zombie, "idle." .. tostring(gate))
end

if not isServer() then
    events.OnZombieUpdate.Add(driveBarterer)
end

return BarteringPathing
