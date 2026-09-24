local getCell = _G["getCell"]
local instanceof = _G["instanceof"]

local BarteringTasks = require "Movement/BarteringTasks"
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"
local BarteringClimbingUtils = require "Movement/BarteringClimbingUtils"

local BarteringWindows = {}

local WINDOW_CLIMB_DISTANCE = 1.0
local WINDOW_OPEN_MAX_TICKS = 120

local function windowOwingCrossing(zombie, goalX, goalY, brain, requiredKey)
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
    local hereRoom = here:getRoom()
    for _, step in pairs(BarteringClimbingUtils.CROSSING_STEPS) do
        local dot = step.x * gx + step.y * gy
        if dot > 0.2 then
            local ahead = cell:getGridSquare(here:getX() + step.x, here:getY() + step.y, here:getZ())
            local window = ahead and hereRoom ~= ahead:getRoom() and here:getWindowTo(ahead)
            if window and instanceof(window, "IsoWindow") and not (brain.blockedWindows
                and brain.blockedWindows[BarteringAIUtils.openableKey(window)])
                and (not requiredKey or BarteringAIUtils.openableKey(window) == requiredKey) then
                return window
            end
        end
    end

    return nil
end

local function manageWindowClimbing(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.windowOpening then
        brain.windowOpenTicks = brain.windowOpenTicks + 1
        if not zombie:getVariableBoolean("BumpAnimFinished") and brain.windowOpenTicks < WINDOW_OPEN_MAX_TICKS then
            return
        end
        local opening = brain.windowOpening
        brain.windowOpening = nil
        if BarteringAIUtils.openWindowFor(zombie, opening) then
            Bartering.logBartererSound(zombie, "character", "OpenWindow", zombie:playSound("OpenWindow"))
            BarteringPathTrace.counter(zombie, "window.opened")
        end
        return
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        return
    end

    local bartererState = zombie:getVariableString("BartererState")
    if bartererState ~= "Retreat" and bartererState ~= "Follow" then
        return
    end

    if BarteringClimbingUtils.hasNonMoveTask(zombie) then
        return
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        return
    end

    if zombie:getCurrentStateName() == "BumpedState" then
        return
    end

    local requiredKey = bartererState == "Follow" and brain.followWindowKey
    if bartererState == "Follow" and not requiredKey then
        return
    end

    local goalX, goalY = BarteringAIUtils.getGoal(zombie)
    local window = windowOwingCrossing(zombie, goalX, goalY, brain, requiredKey)
    if not window then
        return
    end

    local wdx = (window:getX() + 0.5) - zombie:getX()
    local wdy = (window:getY() + 0.5) - zombie:getY()
    if (wdx * wdx + wdy * wdy) > (WINDOW_CLIMB_DISTANCE * WINDOW_CLIMB_DISTANCE) then
        return
    end

    local state = BarteringAIUtils.windowStateFor(zombie, window)

    if state == "openable" then
        brain.windowOpening = window
        brain.windowOpenTicks = 0
        BarteringTasks.StopMovement(zombie)
        zombie:faceThisObject(window)
        zombie:setVariable("BumpAnimFinished", false)
        zombie:setBumpType("WindowOpen")
        BarteringPathTrace.counter(zombie, "window.openAnim")
        return
    end

    if state == "blocked" then
        local key = BarteringAIUtils.openableKey(window)
        brain.blockedWindows = brain.blockedWindows or {}
        if not brain.blockedWindows[key] then
            brain.blockedWindows[key] = true
            BarteringPathTrace.counter(zombie, "window.ignored")
            BarteringClimbingUtils.logClimb(zombie, "window will not open; ignoring it from now on", string.format(
                "obj=%.1f,%.1f", window:getX(), window:getY()))
        end
        return
    end

    if bartererState == "Retreat" and zombie:hasPath() and (brain.moveFailures or 0) == 0 then
        BarteringPathTrace.counter(zombie, "window.skippedWalkableRoute")
        return
    end

    if not zombie:isFacingObject(window, 0.5) then
        zombie:faceThisObject(window)
        return
    end

    BarteringPathTrace.counter(zombie, "window.climb")
    if requiredKey then
        brain.followWindowKey = nil
    end
    brain.windowClimbing = true
    brain.windowClimbEntered = nil
    brain.windowClimbX, brain.windowClimbY = zombie:getX(), zombie:getY()
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = BarteringClimbingUtils.CLIMB_COOLDOWN_TICKS
    BarteringTasks.StopTasks(zombie)
    BarteringAIUtils.detachPath(zombie)
    zombie:setBumpType("")
    zombie:setVariable("BartererClimbing", true)
    zombie:climbThroughWindow(window)
    BarteringClimbingUtils.logClimb(zombie, "window climb triggered", string.format(
        "obj=%.1f,%.1f goalahead=%s,%s state=%s",
        window:getX(), window:getY(), tostring(goalX), tostring(goalY), tostring(bartererState)))
end

BarteringWindows.manageWindowClimbing = manageWindowClimbing

return BarteringWindows