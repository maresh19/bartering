local events = _G["Events"]
local ZombieIdleState = _G["ZombieIdleState"]
local getCell = _G["getCell"]
local instanceof = _G["instanceof"]
local ClimbThroughWindowState = _G["ClimbThroughWindowState"]

require "Bartering"
local BarteringTasks = require "BarteringTasks"
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"
require "BarteringPathing"

local function manageActionState(zombie)
    local asn = zombie:getActionStateName()

    if asn == "pathfind" then
        zombie:setUseless(true)
        zombie:setTarget(nil)
        zombie:setTargetSeenTime(0)
        zombie:clearAggroList()
        return false, "enginePathfind"
    end

    if asn == "climbfence" or asn == "climbwindow" or asn == "hitreaction" then
        return false, "anim." .. asn
    end

    if asn == "onground" or asn == "getup" or asn == "getup-fromonback"
        or asn == "getup-fromonfront" or asn == "getup-fromsitting"
        or asn == "staggerback" or asn == "staggerback-knockeddown" then
        if BarteringTasks.HasTask(zombie) then
            BarteringPathTrace.counter(zombie, "drive.downed.clearedTasks")
        end
        BarteringTasks.ClearTasks(zombie)
        return false, "downed." .. asn
    end

    if asn == "turnalerted" then
        zombie:changeState(ZombieIdleState.instance())
        zombie:clearAggroList()
        zombie:setTarget(nil)
        return true
    end

    if asn == "lunge" then
        zombie:setUseless(true)
        zombie:clearAggroList()
        zombie:setTarget(nil)
        return true
    end

    zombie:setTarget(nil)
    zombie:setTargetSeenTime(0)
    zombie:setUseless(true)
    return true
end
local FENCE_MAX_ATTEMPTS = 6
local FENCE_CLIMB_TIMEOUT_TICKS = 180
local FENCE_MAX_FACE_TICKS = 40
local FENCE_COOLDOWN_TICKS = 30
local FENCE_BLOCKED_TICKS = 5
local FENCE_PROGRESS_EPSILON = 0.02

local function logFence(zombie, reason, detail)
    print(string.format(
        "[Bartering][Fence] %s | %s | %s action=%s curState=%s bump=%s useless=%s moving=%s pos=%.2f,%.2f,%.2f",
        tostring(Bartering.getBartererDisplayName(zombie:getVariableString("BartererId"))),
        tostring(reason),
        tostring(detail),
        tostring(zombie:getActionStateName()),
        tostring(zombie:getCurrentStateName()),
        tostring(zombie:getBumpType()),
        tostring(zombie:isUseless()),
        tostring(BarteringTasks.IsMoving(zombie)),
        zombie:getX(), zombie:getY(), zombie:getZ()))
end


local function hasNonMoveTask(zombie)
    for _, task in pairs(BarteringTasks.GetBrain(zombie).tasks) do
        if task.action ~= "Move" then
            return true
        end
    end
    return false
end

local function fenceKind(object)
    if not object then
        return nil
    end
    local properties = object:getProperties()
    if not properties then
        return nil
    end
    if properties:Val("FenceTypeHigh") then
        return "high"
    end
    if properties:Val("FenceTypeLow") then
        return "low"
    end
    return nil
end

local FENCE_ROUTE_SCAN_TILES = 40
local FENCE_CLIMB_MAX_DISTANCE = 1.1
local FENCE_CLOSE_IN_TICKS = 90
local CROSSING_STEPS = {
    { x = 1, y = 0 },
    { x = -1, y = 0 },
    { x = 0, y = 1 },
    { x = 0, y = -1 },
}

local function fenceObjectOn(square)
    if not square then
        return nil, nil
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local kind = fenceKind(object)
        if kind then
            return object, kind
        end
    end
    return nil, nil
end

local function findFenceApproachTile(zombie, goalX, goalY)
    if not goalX or not goalY then
        return nil
    end

    local startX, startY = zombie:getX(), zombie:getY()
    local dx = (goalX + 0.5) - startX
    local dy = (goalY + 0.5) - startY
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance < 1 then
        return nil
    end

    dx, dy = dx / distance, dy / distance
    local steps = math.min(math.floor(distance * 2), FENCE_ROUTE_SCAN_TILES * 2)
    local cell = getCell()
    local z = zombie:getZ()
    local lastX, lastY = math.floor(startX), math.floor(startY)
    local lastSquare = cell:getGridSquare(lastX, lastY, z)

    for step = 1, steps do
        local tx = math.floor(startX + dx * step * 0.5)
        local ty = math.floor(startY + dy * step * 0.5)
        if tx ~= lastX or ty ~= lastY then
            local square = cell:getGridSquare(tx, ty, z)
            if lastSquare and square and lastSquare:isSomethingTo(square)
                and (fenceObjectOn(lastSquare) or fenceObjectOn(square)) then
                return lastX, lastY, tx, ty
            end
            lastX, lastY, lastSquare = tx, ty, square
        end
    end

    return nil
end

local function findBlockedCrossing(zombie, goalX, goalY)
    local gx = goalX and (goalX + 0.5 - zombie:getX()) or 0
    local gy = goalY and (goalY + 0.5 - zombie:getY()) or 0
    local glen = math.sqrt(gx * gx + gy * gy)
    if glen < 0.01 then
        return nil
    end
    gx, gy = gx / glen, gy / glen

    local here = zombie:getSquare()
    if not here then
        return nil
    end

    local cell = getCell()
    local bestDot, bestObject, bestKind, bestSame, bestDir, bestStepX, bestStepY
    for _, step in pairs(CROSSING_STEPS) do
        local dot = step.x * gx + step.y * gy
        if dot > 0.2 and (not bestDot or dot > bestDot) then
            local ahead = cell:getGridSquare(here:getX() + step.x, here:getY() + step.y, here:getZ())
            if ahead and here:isSomethingTo(ahead) then
                local object, kind = fenceObjectOn(here)
                local sameSquare = true
                if not object then
                    object, kind = fenceObjectOn(ahead)
                    sameSquare = false
                end
                if object then
                    bestDot = dot
                    bestObject = object
                    bestKind = kind
                    bestSame = sameSquare
                    bestStepX = step.x
                    bestStepY = step.y
                    if step.x ~= 0 then
                        bestDir = step.x > 0 and IsoDirections.E or IsoDirections.W
                    else
                        bestDir = step.y > 0 and IsoDirections.S or IsoDirections.N
                    end
                end
            end
        end
    end

    return bestObject, bestKind, bestSame, bestDir, bestStepX, bestStepY
end


local function trackFenceProgress(zombie, brain)
    if zombie:isCollidedThisFrame() then
        return true
    end

    local movedX = zombie:getX() - (brain.fenceLastX or zombie:getX())
    local movedY = zombie:getY() - (brain.fenceLastY or zombie:getY())
    brain.fenceLastX, brain.fenceLastY = zombie:getX(), zombie:getY()

    if math.sqrt(movedX * movedX + movedY * movedY) > FENCE_PROGRESS_EPSILON then
        brain.fenceBlockedTicks = 0
        return false
    end

    brain.fenceBlockedTicks = (brain.fenceBlockedTicks or 0) + 1
    return brain.fenceBlockedTicks >= FENCE_BLOCKED_TICKS
end

local function clearFenceLatch(brain)
    brain.fenceLatchX = nil
    brain.fenceLatchY = nil
    brain.fenceLatchTileX = nil
    brain.fenceLatchTileY = nil
    brain.fenceLatchState = nil
    brain.fenceLatchSrcX = nil
    brain.fenceLatchSrcY = nil
    brain.fenceLatchSrcZ = nil
end

local function giveUpOnFence(zombie, brain, reason)
    logFence(zombie, "gave up on fence; repathing", reason)
    BarteringPathTrace.counter(zombie, "fence.gaveUp")
    zombie:setCollidable(true)
    zombie:setVariable("hitreaction", "")
    zombie:setVariable("BartererClimbing", false)
    brain.fenceClimbTicks = nil
    brain.fenceAttempts = 0
    brain.fenceFaceTicks = 0
    brain.fenceClosingIn = nil
    brain.fenceCloseTicks = nil
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = FENCE_COOLDOWN_TICKS
    clearFenceLatch(brain)
    BarteringTasks.ClearTasks(zombie)
    BarteringTasks.SetMoving(zombie, false)
    BarteringAIUtils.clearPathing(zombie)
end

local function updateClimbRelease(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.fenceHighVaulting and not zombie:getVariableBoolean("ClimbWallStartEnded") then
        local vdx = zombie:getX() - brain.fenceHopX
        local vdy = zombie:getY() - brain.fenceHopY
        logFence(zombie, "high fence: vault outcome", string.format("movedSinceHop=%.2f distAtHop=%.2f",
            math.sqrt(vdx * vdx + vdy * vdy), brain.fenceHopDistance or -1))
        brain.fenceHighVaulting = nil
        brain.fenceHopDistance = nil
        brain.fenceHopX = nil
        brain.fenceClimbTicks = nil
        zombie:setCollidable(true)
        zombie:setVariable("hitreaction", "")
        zombie:setVariable("BartererClimbing", false)
        clearFenceLatch(brain)
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        brain.fenceClimbTicks = (brain.fenceClimbTicks or 0) + 1
        if brain.fenceClimbTicks > FENCE_CLIMB_TIMEOUT_TICKS then
            logFence(zombie, "climb timed out; releasing hold", string.format("ticks=%d action=%s",
                brain.fenceClimbTicks, tostring(zombie:getActionStateName())))
            zombie:setVariable("BartererClimbing", false)
            zombie:setCollidable(true)
            zombie:setVariable("hitreaction", "")
            brain.fenceClimbTicks = nil
            brain.fenceCooldown = 0
            clearFenceLatch(brain)
        end
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        brain.fenceCooldown = brain.fenceCooldown - 1
        if brain.fenceCooldown == 0 and brain.fenceHopX and not brain.fenceHighVaulting then
            local hdx = zombie:getX() - brain.fenceHopX
            local hdy = zombie:getY() - brain.fenceHopY
            logFence(zombie, "hop outcome", string.format("movedSinceHop=%.2f distAtHop=%.2f",
                math.sqrt(hdx * hdx + hdy * hdy), brain.fenceHopDistance or -1))
            brain.fenceHopDistance = nil
            brain.fenceHopX = nil
            zombie:setCollidable(true)
            zombie:setVariable("hitreaction", "")
            zombie:setVariable("BartererClimbing", false)
            brain.fenceClimbTicks = nil
            clearFenceLatch(brain)
        end
    end
end

local function manageFenceClimbing(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.fenceHighVaulting then
        zombie:setCollidable(false)
        zombie:setVariable("hitreaction", "ClimbWallSuccess")
        zombie:setVariable("BartererClimbing", true)
        return
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return
    end

    local bartererState = zombie:getVariableString("BartererState")
    if bartererState ~= "Approach" and bartererState ~= "Return" and bartererState ~= "Retreat" then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceBlockedTicks = 0
        return
    end

    if hasNonMoveTask(zombie) then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceBlockedTicks = 0
        return
    end

    if zombie:getCurrentStateName() == "BumpedState" then
        return
    end

    local fenceStalled = trackFenceProgress(zombie, brain)

    local goalX = tonumber(zombie:getVariableString("BartererGoalX"))
    local goalY = tonumber(zombie:getVariableString("BartererGoalY"))
    local object, kind, sameSquare, direction = findBlockedCrossing(zombie, goalX, goalY)
    if not object then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceNoticed = nil
        brain.fenceClosingIn = nil
        brain.fenceCloseTicks = nil
        if brain.fenceLatchX and not BarteringTasks.HasTask(zombie) then
            logFence(zombie, "latched but no crossing found; releasing", string.format(
                "latch=%d,%d goal=%s,%s", brain.fenceLatchX, brain.fenceLatchY,
                tostring(goalX), tostring(goalY)))
            clearFenceLatch(brain)
        end
        return
    end

    if not brain.fenceNoticed then
        brain.fenceNoticed = true
        logFence(zombie, "blocked by fence", string.format(
            "obj=%.1f,%.1f kind=%s sprite=%s cross=%s sameSquare=%s blockedTicks=%d",
            object:getX(), object:getY(), tostring(kind), tostring(object:getSpriteName()),
            tostring(direction), tostring(sameSquare),
            brain.fenceBlockedTicks or 0))
    end

    local fdx = (object:getX() + 0.5) - zombie:getX()
    local fdy = (object:getY() + 0.5) - zombie:getY()
    local fenceDistance = math.sqrt(fdx * fdx + fdy * fdy)

    if not brain.fenceHighStarted and fenceDistance > FENCE_CLIMB_MAX_DISTANCE then
        brain.fenceCloseTicks = (brain.fenceCloseTicks or 0) + 1
        if brain.fenceCloseTicks <= FENCE_CLOSE_IN_TICKS then
            if not brain.fenceClosingIn then
                brain.fenceClosingIn = true
                logFence(zombie, "too far to climb; closing in", string.format(
                    "obj=%.1f,%.1f dist=%.2f max=%.2f", object:getX(), object:getY(),
                    fenceDistance, FENCE_CLIMB_MAX_DISTANCE))
            end
            return
        end
        logFence(zombie, "close-in timed out; climbing anyway", string.format(
            "obj=%.1f,%.1f dist=%.2f ticks=%d", object:getX(), object:getY(),
            fenceDistance, brain.fenceCloseTicks))
    end
    brain.fenceClosingIn = nil
    brain.fenceCloseTicks = nil

    if zombie:getDir() ~= direction then
        brain.fenceFaceTicks = (brain.fenceFaceTicks or 0) + 1
        if brain.fenceFaceTicks > FENCE_MAX_FACE_TICKS then
            giveUpOnFence(zombie, brain, string.format(
                "could not turn to fence in %d ticks; want=%s facing=%s obj=%.1f,%.1f sameSquare=%s",
                FENCE_MAX_FACE_TICKS, tostring(direction), tostring(zombie:getDir()),
                object:getX(), object:getY(), tostring(sameSquare)))
            return
        end
        zombie:setDir(direction)
        return
    end
    brain.fenceFaceTicks = 0

    if kind == "high" then
        if not zombie:getVariableBoolean("ClimbWallStartEnded") then
            if not brain.fenceHighStarted then
                brain.fenceHighStarted = true
                logFence(zombie, "high fence: pulling up", string.format(
                    "obj=%.1f,%.1f dir=%s dist=%.2f hadPath=%s",
                    object:getX(), object:getY(), tostring(direction), fenceDistance,
                    tostring(zombie:hasPath())))
                BarteringTasks.ClearTasks(zombie)
                BarteringTasks.SetMoving(zombie, false)
                BarteringAIUtils.detachPath(zombie)
            end
            zombie:setVariable("hitreaction", "ClimbWallStart")
            zombie:setVariable("BartererClimbing", true)
            return
        end

        logFence(zombie, "high fence: vaulting over", string.format(
            "obj=%.1f,%.1f dir=%s dist=%.2f hadPath=%s",
            object:getX(), object:getY(), tostring(direction), fenceDistance,
            tostring(zombie:hasPath())))
        brain.fenceHighVaulting = true
        brain.fenceHopDistance = fenceDistance
        brain.fenceHopX, brain.fenceHopY = zombie:getX(), zombie:getY()
        brain.fenceHighStarted = nil
        brain.fenceBlockedTicks = 0
        brain.fenceCooldown = FENCE_COOLDOWN_TICKS
        zombie:setCollidable(false)
        zombie:setVariable("hitreaction", "ClimbWallSuccess")
        zombie:setVariable("BartererClimbing", true)
        BarteringTasks.ClearTasks(zombie)
        BarteringTasks.SetMoving(zombie, false)
        return
    end

    brain.fenceAttempts = (brain.fenceAttempts or 0) + 1
    if brain.fenceAttempts > FENCE_MAX_ATTEMPTS then
        giveUpOnFence(zombie, brain, string.format("hopped %d times without progress", FENCE_MAX_ATTEMPTS))
        return
    end

    logFence(zombie, "hop attempt", string.format("obj=%.1f,%.1f dir=%s facing=%s dist=%.2f attempts=%d",
        object:getX(), object:getY(), tostring(direction), tostring(zombie:getDir()),
        fenceDistance, brain.fenceAttempts))
    brain.fenceHopDistance = fenceDistance
    brain.fenceHopX, brain.fenceHopY = zombie:getX(), zombie:getY()

    BarteringPathTrace.counter(zombie, "fence.hop")
    zombie:climbOverFence(direction)
    zombie:setBumpType("ClimbFenceEnd")
    zombie:setVariable("BartererClimbing", true)
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = FENCE_COOLDOWN_TICKS
    BarteringTasks.ClearTasks(zombie)
    BarteringTasks.SetMoving(zombie, false)
end



local WINDOW_CLIMB_DISTANCE = 1.0

local function windowOwingCrossing(zombie, goalX, goalY)
    local here = zombie:getSquare()
    if not here then
        return nil
    end
    local gx = goalX and (goalX + 0.5 - zombie:getX()) or 0
    local gy = goalY and (goalY + 0.5 - zombie:getY()) or 0
    local glen = math.sqrt(gx * gx + gy * gy)
    if glen < 0.01 then
        return nil
    end
    gx, gy = gx / glen, gy / glen

    local cell = getCell()
    for _, step in pairs(CROSSING_STEPS) do
        local dot = step.x * gx + step.y * gy
        if dot > 0.2 then
            local ahead = cell:getGridSquare(here:getX() + step.x, here:getY() + step.y, here:getZ())
            for _, square in ipairs({ here, ahead }) do
                if square then
                    local objects = square:getObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if instanceof(object, "IsoWindow") then
                            return object
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function manageWindowClimbing(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return
    end

    local bartererState = zombie:getVariableString("BartererState")
    if bartererState ~= "Approach" and bartererState ~= "Return" and bartererState ~= "Retreat" then
        return
    end

    if hasNonMoveTask(zombie) then
        return
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        return
    end

    if zombie:getCurrentStateName() == "BumpedState" then
        return
    end

    local goalX = tonumber(zombie:getVariableString("BartererGoalX"))
    local goalY = tonumber(zombie:getVariableString("BartererGoalY"))
    local window = windowOwingCrossing(zombie, goalX, goalY)
    if not window then
        return
    end

    local wdx = (window:getX() + 0.5) - zombie:getX()
    local wdy = (window:getY() + 0.5) - zombie:getY()
    if (wdx * wdx + wdy * wdy) > (WINDOW_CLIMB_DISTANCE * WINDOW_CLIMB_DISTANCE) then
        return
    end

    if not window:canClimbThrough(zombie) then
        return
    end

    if not zombie:isFacingObject(window, 0.5) then
        zombie:faceThisObject(window)
        return
    end

    BarteringPathTrace.counter(zombie, "window.climb")
    ClimbThroughWindowState.instance():setParams(zombie, window)
    zombie:changeState(ClimbThroughWindowState.instance())
    zombie:setBumpType("ClimbWindow")
    zombie:setVariable("BartererClimbing", true)
    zombie:setCollidable(false)
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = FENCE_COOLDOWN_TICKS
    BarteringTasks.ClearTasks(zombie)
    BarteringTasks.SetMoving(zombie, false)
    BarteringAIUtils.detachPath(zombie)
    logFence(zombie, "window climb triggered", string.format(
        "obj=%.1f,%.1f goalahead=%s,%s state=%s",
        window:getX(), window:getY(), tostring(goalX), tostring(goalY), tostring(bartererState)))
end

local function generateTask(zombie)
    local goalX = tonumber(zombie:getVariableString("BartererGoalX"))
    local goalY = tonumber(zombie:getVariableString("BartererGoalY"))
    local goalZ = tonumber(zombie:getVariableString("BartererGoalZ"))

    local brain = BarteringTasks.GetBrain(zombie)
    local bartererState = zombie:getVariableString("BartererState")

    if brain.fenceLatchX and brain.fenceLatchState ~= bartererState then
        logFence(zombie, "fence latch released; state changed", string.format(
            "latch=%d,%d was=%s now=%s", brain.fenceLatchX, brain.fenceLatchY,
            tostring(brain.fenceLatchState), tostring(bartererState)))
        clearFenceLatch(brain)
    end

    local active = BarteringTasks.GetTask(zombie)

    if active and active.action == "Move" and not goalX then
        BarteringPathTrace.counter(zombie, "move.abandon.goalCleared")
        clearFenceLatch(brain)
        BarteringTasks.ClearTasks(zombie)
        BarteringTasks.SetMoving(zombie, false)
        BarteringAIUtils.clearPathing(zombie)
        active = nil
    end

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
        BarteringTasks.ClearTasks(zombie)
        BarteringTasks.SetMoving(zombie, false)
        active = nil
    end

    if active then
        return "activeTask"
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        return "climbing"
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return "fenceCooldown"
    end

    if brain.moveCooldown and brain.moveCooldown > 0 then
        brain.moveCooldown = brain.moveCooldown - 1
        return "moveCooldown"
    end

    if not goalX or not goalY or not goalZ then
        return "noGoal"
    end

    local rawX, rawY, rawZ = goalX, goalY, goalZ
    local fenceApproach = false
    if bartererState == "Approach" or bartererState == "Return" or bartererState == "Retreat" then
        local fenceX, fenceY, tileX, tileY
        if brain.fenceLatchX then
            fenceX, fenceY = brain.fenceLatchX, brain.fenceLatchY
            tileX, tileY = brain.fenceLatchTileX, brain.fenceLatchTileY
            rawX, rawY, rawZ = brain.fenceLatchSrcX, brain.fenceLatchSrcY, brain.fenceLatchSrcZ
        else
            fenceX, fenceY, tileX, tileY = findFenceApproachTile(zombie, goalX, goalY)
        end
        if fenceX and (fenceX ~= goalX or fenceY ~= goalY) then
            if not brain.fenceLatchX then
                brain.fenceLatchX, brain.fenceLatchY = fenceX, fenceY
                brain.fenceLatchTileX, brain.fenceLatchTileY = tileX, tileY
                brain.fenceLatchState = bartererState
                brain.fenceLatchSrcX, brain.fenceLatchSrcY, brain.fenceLatchSrcZ = rawX, rawY, rawZ
                logFence(zombie, "fence on route; latching onto approach tile",
                    string.format("realGoal=%d,%d approachTile=%d,%d fenceTile=%s,%s",
                        goalX, goalY, fenceX, fenceY, tostring(tileX), tostring(tileY)))
            end
            goalX, goalY = fenceX, fenceY
            fenceApproach = true
        else
            clearFenceLatch(brain)
        end
    end

    local dx = zombie:getX() - (goalX + 0.5)
    local dy = zombie:getY() - (goalY + 0.5)
    local arriveSq = fenceApproach and 0.05 or 1.2
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

local function driveBarterer(zombie)
    if not zombie:getVariableBoolean("Barterer") then
        return
    end
    if zombie:isDead() or zombie:getHealth() <= 0 then
        BarteringTasks.RemoveBrain(zombie)
        BarteringPathTrace.forget(zombie)
        return
    end

    zombie:setUseless(false)

    updateClimbRelease(zombie)

    local driveAsn = zombie:getActionStateName()
    if zombie:getVariableBoolean("BartererClimbing")
        or driveAsn == "climbfence" or driveAsn == "climbwindow" then
        zombie:setUseless(true)
        Bartering.clearEngineTarget(zombie)
        zombie:setThumpTarget(nil)
        BarteringAIUtils.detachPath(zombie)
    end

    local proceed, blockedBy = manageActionState(zombie)
    if not proceed then
        BarteringPathTrace.driveStop(zombie, "blocked." .. blockedBy)
        return
    end

    manageFenceClimbing(zombie)
    manageWindowClimbing(zombie)
    local gate = generateTask(zombie)

    local task = BarteringTasks.GetTask(zombie)
    if task then
        BarteringPathTrace.driveStop(zombie, string.format("task.%s.%s", task.action, tostring(task.state)))
        BarteringTasks.ProcessTask(zombie, task)
        return
    end

    BarteringPathTrace.driveStop(zombie, "idle." .. tostring(gate))
end

if not isClient() then
    events.OnZombieUpdate.Add(driveBarterer)
end
