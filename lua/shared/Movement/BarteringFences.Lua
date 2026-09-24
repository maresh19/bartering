local getCell = _G["getCell"]
local instanceof = _G["instanceof"]
local IsoFlagType = _G["IsoFlagType"]

local BarteringTasks = require "Movement/BarteringTasks"
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"
local BarteringClimbingUtils = require "Movement/BarteringClimbingUtils"

local BarteringFences = {}

local FENCE_MAX_ATTEMPTS = 6
local FENCE_MAX_FACE_TICKS = 40
local FENCE_ANIM_ALIGN_DEGREES = 15
local FENCE_BLOCKED_TICKS = 5
local FENCE_PROGRESS_EPSILON = 0.02

local FENCE_ROUTE_SCAN_TILES = 40
local FENCE_CLIMB_MAX_DISTANCE = 0.6
local FENCE_CLOSE_IN_TICKS = 90

local function angleGap(a, b)
    local d = (a - b) % 360
    if d > 180 then
        d = d - 360
    end
    return math.abs(d)
end

local function fenceKind(object)
    if not object then
        return nil
    end
    local className = object:getClass():getSimpleName()
    if className == "IsoWindow"
        or className == "IsoDoor"
        or (className == "IsoThumpable" and object:isDoor() == true) then
        return nil
    end
    local properties = object:getProperties()
    if not properties then
        return nil
    end
    if properties:get("FenceTypeHigh") then
        return "high"
    end
    if properties:get("FenceTypeLow") then
        return "low"
    end
    return nil
end

local function fenceOnEdge(fromSquare, toSquare, stepX, stepY)
    local hoppable = fromSquare:getHoppableTo(toSquare)
    if hoppable and not fromSquare:getWindowFrameTo(toSquare) then
        return hoppable, "low", hoppable:getSquare() == fromSquare
    end
    local owner = (stepX < 0 or stepY < 0) and fromSquare or toSquare
    local flag = stepY ~= 0 and IsoFlagType.collideN or IsoFlagType.collideW
    local objects = owner:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local kind = fenceKind(object)
        if kind and object:getProperties():has(flag) then
            return object, kind, owner == fromSquare
        end
    end
    return nil, nil, nil
end

local function findFenceApproachTile(zombie, goalX, goalY)
    if not goalX or not goalY then
        return nil
    end

    local startX, startY = zombie:getX(), zombie:getY()
    local dirX = (goalX + 0.5) - startX
    local dirY = (goalY + 0.5) - startY
    if math.sqrt(dirX * dirX + dirY * dirY) < 1 then
        return nil
    end

    local cell = getCell()
    local z = zombie:getZ()
    local x, y = math.floor(startX), math.floor(startY)
    local stepX = dirX > 0 and 1 or -1
    local stepY = dirY > 0 and 1 or -1
    local tDeltaX, tMaxX = math.huge, math.huge
    local tDeltaY, tMaxY = math.huge, math.huge
    if dirX ~= 0 then
        tDeltaX = math.abs(1 / dirX)
        tMaxX = (dirX > 0 and (x + 1 - startX) or (startX - x)) * tDeltaX
    end
    if dirY ~= 0 then
        tDeltaY = math.abs(1 / dirY)
        tMaxY = (dirY > 0 and (y + 1 - startY) or (startY - y)) * tDeltaY
    end

    for _ = 1, FENCE_ROUTE_SCAN_TILES * 2 do
        if (x == goalX and y == goalY) or math.min(tMaxX, tMaxY) > 1 then
            return nil
        end
        local nextX, nextY, crossX, crossY = x, y, 0, 0
        if tMaxX < tMaxY then
            nextX, crossX = x + stepX, stepX
            tMaxX = tMaxX + tDeltaX
        else
            nextY, crossY = y + stepY, stepY
            tMaxY = tMaxY + tDeltaY
        end
        local fromSquare = cell:getGridSquare(x, y, z)
        local toSquare = cell:getGridSquare(nextX, nextY, z)
        if fromSquare and toSquare and fenceOnEdge(fromSquare, toSquare, crossX, crossY) then
            return x, y, nextX, nextY
        end
        x, y = nextX, nextY
    end

    return nil
end

function BarteringFences.releaseLatchOnStateChange(zombie, brain, bartererState)
    if not brain.fenceLatchX or brain.fenceLatchState == bartererState then
        return
    end
    if bartererState ~= "Approach" and bartererState ~= "Return" and bartererState ~= "Retreat"
        and bartererState ~= "Follow" then
        return
    end
    BarteringClimbingUtils.logClimb(zombie, "fence latch released; state changed", string.format(
        "latch=%d,%d was=%s now=%s", brain.fenceLatchX, brain.fenceLatchY,
        tostring(brain.fenceLatchState), tostring(bartererState)))
    BarteringClimbingUtils.clearClimbLatch(brain)
end

function BarteringFences.adjustGoalForFence(zombie, brain, goalX, goalY, goalZ, bartererState)
    local rawX, rawY, rawZ = goalX, goalY, goalZ
    local fenceApproach = false
    if bartererState == "Approach" or bartererState == "Return" or bartererState == "Retreat"
        or bartererState == "Follow" then
        local fenceX, fenceY, tileX, tileY
        if brain.fenceLatchX then
            fenceX, fenceY = brain.fenceLatchX, brain.fenceLatchY
            tileX, tileY = brain.fenceLatchTileX, brain.fenceLatchTileY
            rawX, rawY, rawZ = brain.fenceLatchSrcX, brain.fenceLatchSrcY, brain.fenceLatchSrcZ
        else
            fenceX, fenceY, tileX, tileY = BarteringFences.findFenceApproachTile(zombie, goalX, goalY)
        end
        if fenceX and (fenceX ~= goalX or fenceY ~= goalY) then
            if not brain.fenceLatchX then
                brain.fenceLatchX, brain.fenceLatchY = fenceX, fenceY
                brain.fenceLatchTileX, brain.fenceLatchTileY = tileX, tileY
                brain.fenceLatchState = bartererState
                brain.fenceLatchSrcX, brain.fenceLatchSrcY, brain.fenceLatchSrcZ = rawX, rawY, rawZ
                BarteringClimbingUtils.logClimb(zombie, "fence on route; latching onto approach tile",
                    string.format("realGoal=%d,%d approachTile=%d,%d fenceTile=%s,%s",
                        goalX, goalY, fenceX, fenceY, tostring(tileX), tostring(tileY)))
            end
            goalX, goalY = fenceX, fenceY
            fenceApproach = true
        else
            BarteringClimbingUtils.clearClimbLatch(brain)
        end
    end
    return goalX, goalY, rawX, rawY, rawZ, fenceApproach
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
    for _, step in pairs(BarteringClimbingUtils.CROSSING_STEPS) do
        local dot = step.x * gx + step.y * gy
        if dot > 0.2 and (not bestDot or dot > bestDot) then
            local ahead = cell:getGridSquare(here:getX() + step.x, here:getY() + step.y, here:getZ())
            local object, kind, sameSquare
            if ahead then
                object, kind, sameSquare = fenceOnEdge(here, ahead, step.x, step.y)
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

local function manageFenceClimbing(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.fenceHighVaulting then
        zombie:setCollidable(false)
        zombie:setVariable("BartererClimbing", true)
        return
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return
    end

    local bartererState = zombie:getVariableString("BartererState")
    if bartererState ~= "Approach" and bartererState ~= "Return" and bartererState ~= "Retreat"
        and bartererState ~= "Follow" then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceBlockedTicks = 0
        return
    end

    if BarteringClimbingUtils.hasNonMoveTask(zombie) then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceBlockedTicks = 0
        return
    end

    if zombie:getCurrentStateName() == "BumpedState" then
        return
    end

    local fenceStalled = trackFenceProgress(zombie, brain)

    local goalX, goalY = BarteringAIUtils.getGoal(zombie)
    local object, kind, sameSquare, direction, stepX, stepY = findBlockedCrossing(zombie, goalX, goalY)
    if not object then
        brain.fenceAttempts = 0
        brain.fenceFaceTicks = 0
        brain.fenceNoticed = nil
        brain.fenceClosingIn = nil
        brain.fenceCloseTicks = nil
        if brain.fenceLatchX and not BarteringTasks.HasTask(zombie) then
            BarteringClimbingUtils.logClimb(zombie, "latched but no crossing found; releasing", string.format(
                "latch=%d,%d goal=%s,%s", brain.fenceLatchX, brain.fenceLatchY,
                tostring(goalX), tostring(goalY)))
            BarteringClimbingUtils.clearClimbLatch(brain)
        end
        return
    end

    if not brain.fenceNoticed then
        brain.fenceNoticed = true
        BarteringClimbingUtils.logClimb(zombie, "blocked by fence", string.format(
            "obj=%.1f,%.1f kind=%s sprite=%s cross=%s sameSquare=%s blockedTicks=%d",
            object:getX(), object:getY(), tostring(kind), tostring(object:getSpriteName()),
            tostring(direction), tostring(sameSquare),
            brain.fenceBlockedTicks or 0))
    end

    local here = zombie:getSquare()
    local fenceDistance = stepX ~= 0
        and math.abs(zombie:getX() - (here:getX() + (stepX > 0 and 1 or 0)))
        or math.abs(zombie:getY() - (here:getY() + (stepY > 0 and 1 or 0)))

    if fenceDistance > FENCE_CLIMB_MAX_DISTANCE then
        brain.fenceCloseTicks = (brain.fenceCloseTicks or 0) + 1
        if brain.fenceCloseTicks <= FENCE_CLOSE_IN_TICKS then
            if not brain.fenceClosingIn then
                brain.fenceClosingIn = true
                BarteringClimbingUtils.logClimb(zombie, "too far to climb; closing in", string.format(
                    "obj=%.1f,%.1f dist=%.2f max=%.2f", object:getX(), object:getY(),
                    fenceDistance, FENCE_CLIMB_MAX_DISTANCE))
            end
            return
        end
        BarteringClimbingUtils.logClimb(zombie, "close-in timed out; climbing anyway", string.format(
            "obj=%.1f,%.1f dist=%.2f ticks=%d", object:getX(), object:getY(),
            fenceDistance, brain.fenceCloseTicks))
    end
    brain.fenceClosingIn = nil
    brain.fenceCloseTicks = nil

    if zombie:getDir() ~= direction then
        brain.fenceFaceTicks = (brain.fenceFaceTicks or 0) + 1
        if brain.fenceFaceTicks > FENCE_MAX_FACE_TICKS then
            BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format(
                "could not turn to fence in %d ticks; want=%s facing=%s obj=%.1f,%.1f sameSquare=%s",
                FENCE_MAX_FACE_TICKS, tostring(direction), tostring(zombie:getDir()),
                object:getX(), object:getY(), tostring(sameSquare)))
            return
        end
        zombie:setDir(direction)
        return
    end

    local desiredAngle = stepX ~= 0 and (stepX > 0 and 0 or 180) or (stepY > 0 and 90 or -90)
    local animGap = angleGap(zombie:getAnimAngle(), desiredAngle)
    if animGap > FENCE_ANIM_ALIGN_DEGREES then
        brain.fenceFaceTicks = (brain.fenceFaceTicks or 0) + 1
        if brain.fenceFaceTicks > FENCE_MAX_FACE_TICKS then
            BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format(
                "could not align model to fence in %d ticks; want=%s desiredAngle=%d animAngle=%.2f dirAngle=%.1f obj=%.1f,%.1f",
                FENCE_MAX_FACE_TICKS, tostring(direction), desiredAngle, zombie:getAnimAngle(),
                zombie:getDirectionAngle(), object:getX(), object:getY()))
            return
        end
        zombie:setTargetAndCurrentDirection(stepX, stepY)
        return
    end
    local facingDot = zombie:getForwardDirectionX() * stepX + zombie:getForwardDirectionY() * stepY
    brain.fenceFaceTicks = 0

    if kind == "high" then
        BarteringClimbingUtils.logClimb(zombie, "high fence: vaulting over", string.format(
            "obj=%.1f,%.1f dir=%s dist=%.2f hadPath=%s",
            object:getX(), object:getY(), tostring(direction), fenceDistance,
            tostring(zombie:hasPath())))
        brain.fenceHighVaulting = true
        brain.fenceHopDistance = fenceDistance
        brain.fenceHopX, brain.fenceHopY = zombie:getX(), zombie:getY()
        brain.hopStepX, brain.hopStepY = stepX, stepY
        brain.fenceBlockedTicks = 0
        brain.fenceCooldown = BarteringClimbingUtils.CLIMB_COOLDOWN_TICKS
        zombie:setCollidable(false)
        zombie:setVariable("BumpAnimFinished", false)
        zombie:setBumpType("ClimbFenceTall")
        zombie:setVariable("BartererClimbing", true)
        BarteringTasks.StopTasks(zombie)
        BarteringAIUtils.detachPath(zombie)
        return
    end

    if zombie:getActionStateName() ~= "idle" then
        BarteringTasks.StopMovement(zombie)
        brain.fenceIdleTicks = (brain.fenceIdleTicks or 0) + 1
        if brain.fenceIdleTicks > FENCE_MAX_FACE_TICKS then
            local stuckAction = zombie:getActionStateName()
            brain.fenceIdleTicks = nil
            BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format(
                "could not settle to idle before hopping in %d ticks; action=%s",
                FENCE_MAX_FACE_TICKS, tostring(stuckAction)))
        end
        return
    end
    brain.fenceIdleTicks = nil

    brain.fenceAttempts = (brain.fenceAttempts or 0) + 1
    if brain.fenceAttempts > FENCE_MAX_ATTEMPTS then
        BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format("hopped %d times without progress", FENCE_MAX_ATTEMPTS))
        return
    end

    BarteringClimbingUtils.logClimb(zombie, "hop attempt", string.format("obj=%.1f,%.1f dir=%s facing=%s facingDot=%.2f dirAngle=%.1f animAngle=%.2f dist=%.2f attempts=%d",
        object:getX(), object:getY(), tostring(direction), tostring(zombie:getDir()), facingDot,
        zombie:getDirectionAngle(), zombie:getAnimAngle(), fenceDistance, brain.fenceAttempts))
    brain.fenceHopDistance = fenceDistance
    brain.fenceHopX, brain.fenceHopY = zombie:getX(), zombie:getY()
    brain.hopStepX, brain.hopStepY = stepX, stepY

    BarteringPathTrace.counter(zombie, "fence.hop")
    zombie:setBumpType("")
    zombie:climbOverFence(direction)
    zombie:setVariable("BartererClimbing", true)
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = BarteringClimbingUtils.CLIMB_COOLDOWN_TICKS
    BarteringTasks.StopTasks(zombie)
end

BarteringFences.findFenceApproachTile = findFenceApproachTile
BarteringFences.manageFenceClimbing = manageFenceClimbing

return BarteringFences