local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTasks = require "Movement/BarteringTasks"

local BarteringFollow = {}

BarteringFollow.FOLLOW_DISTANCE = 2
BarteringFollow.FOLLOW_TRAIL_SAMPLE_DISTANCE = 0.5
BarteringFollow.FOLLOW_CATCHUP_DISTANCE_SQ = 9
BarteringFollow.FOLLOW_SETTLED_DISTANCE_SQ = 4
BarteringFollow.FOLLOW_TOO_CLOSE_DISTANCE_SQ = 2.25
BarteringFollow.FOLLOW_SPRINT_MOVEMENT_SPEED = 0.85
BarteringFollow.CHASE_SPRINT_MOVEMENT_SPEED = 0.76
BarteringFollow.FOLLOW_GOAL_HYSTERESIS = 0.75
BarteringFollow.PULL_TRIGGER_DISTANCE = 10
BarteringFollow.PULL_TRIGGER_DISTANCE_SQ = BarteringFollow.PULL_TRIGGER_DISTANCE * BarteringFollow.PULL_TRIGGER_DISTANCE
BarteringFollow.PULL_RELEASE_DISTANCE = 5
BarteringFollow.PULL_RELEASE_DISTANCE_SQ = BarteringFollow.PULL_RELEASE_DISTANCE * BarteringFollow.PULL_RELEASE_DISTANCE

local function releaseBump(zombie)
    if zombie:getActionStateName() == "bumped" and not BarteringTasks.GetBrain(zombie).windowOpening then
        zombie:setVariable("BumpAnimFinished", true)
        zombie:setBumpType("")
    end
end

local function recordPlayerWindow(zombie, player)
    if not player:isCurrentState(ClimbThroughWindowState.instance()) then
        return
    end
    local forward = player:getForwardDirection()
    local stepX, stepY = math.floor(forward:getX() + 0.5), math.floor(forward:getY() + 0.5)
    local here = player:getSquare()
    local cell = getCell()
    local ahead = cell:getGridSquare(here:getX() + stepX, here:getY() + stepY, here:getZ())
    local behind = cell:getGridSquare(here:getX() - stepX, here:getY() - stepY, here:getZ())
    local window = here:getWindowTo(ahead) or behind:getWindowTo(here)
    if window then
        BarteringTasks.GetBrain(zombie).followWindowKey = BarteringAIUtils.openableKey(window)
    end
end

local function applyFollowWalk(zombie, walkType, sprintSpeed)
    BarteringAIUtils.setVariableIfChanged(zombie, "MovementSpeed",
        tostring(walkType == "BartererSprint" and sprintSpeed or 1.00))
    if zombie:getVariableString("BartererWalkType") ~= walkType then
        BarteringAIUtils.setBartererWalkType(zombie, walkType)
    end
    BarteringAIUtils.setVariableIfChanged(zombie, "BartererState", "Follow")
end

function BarteringFollow.getFollowGoal(entry, player)
    local px, py = player:getX(), player:getY()
    local trail = entry.followTrail
    if not trail then
        trail = {}
        entry.followTrail = trail
    end
    local newest = trail[#trail]
    if not newest or BarteringAIUtils.distanceSq(px, py, newest.x, newest.y)
        >= BarteringFollow.FOLLOW_TRAIL_SAMPLE_DISTANCE * BarteringFollow.FOLLOW_TRAIL_SAMPLE_DISTANCE then
        trail[#trail + 1] = { x = px, y = py }
    end

    local remaining = BarteringFollow.FOLLOW_DISTANCE
    local ax, ay = px, py
    for i = #trail, 1, -1 do
        local point = trail[i]
        local dx, dy = point.x - ax, point.y - ay
        local len = math.sqrt(dx * dx + dy * dy)
        if len >= remaining then
            for _ = 1, i - 1 do
                table.remove(trail, 1)
            end
            local t = remaining / len
            return ax + dx * t, ay + dy * t, player:getZ()
        end
        remaining = remaining - len
        ax, ay = point.x, point.y
    end
    return ax, ay, player:getZ()
end

function BarteringFollow.holdForWarning(entry, zombie)
    if entry.hireWarningStopped then
        return
    end
    entry.hireWarningStopped = true
    BarteringAIUtils.clearGoal(zombie, "hire.warning")
    BarteringTasks.StopTasks(zombie)
    BarteringAIUtils.setVariableIfChanged(zombie, "BartererState", "Follow")
end

function BarteringFollow.updateFollow(entry, zombie, player)
    if not player or player:isDead() then
        return
    end

    releaseBump(zombie)
    recordPlayerWindow(zombie, player)

    if entry.combatTask ~= nil or entry.retreatActive then
        return
    end

    local distSq = BarteringAIUtils.distanceSqBetween(zombie, player)

    local catchingUp = entry.hireCatchUp == true
    if distSq > BarteringFollow.FOLLOW_CATCHUP_DISTANCE_SQ then
        catchingUp = true
    elseif distSq <= BarteringFollow.FOLLOW_SETTLED_DISTANCE_SQ then
        catchingUp = false
    end
    entry.hireCatchUp = catchingUp

    local goalX, goalY, goalZ = BarteringFollow.getFollowGoal(entry, player)
    if not entry.followTileX
        or math.abs(goalX - (entry.followTileX + 0.5)) > BarteringFollow.FOLLOW_GOAL_HYSTERESIS
        or math.abs(goalY - (entry.followTileY + 0.5)) > BarteringFollow.FOLLOW_GOAL_HYSTERESIS then
        entry.followTileX, entry.followTileY = math.floor(goalX), math.floor(goalY)
    end
    goalX, goalY = entry.followTileX + 0.5, entry.followTileY + 0.5
    if catchingUp or distSq < BarteringFollow.FOLLOW_TOO_CLOSE_DISTANCE_SQ then
        BarteringAIUtils.publishGoal(zombie, goalX, goalY, goalZ, "hire.follow")
    else
        BarteringAIUtils.clearGoal(zombie, "hire.follow.settled")
    end

    local walkType
    if zombie:getHealth() < 0.8 then
        walkType = "BartererLimp"
    elseif player:isSneaking() then
        walkType = player:IsRunning() and "BartererSneakRun" or "BartererSneak"
    elseif player:IsRunning() then
        walkType = "BartererSprint"
    else
        walkType = "BartererWalk"
    end
    applyFollowWalk(zombie, walkType, BarteringFollow.FOLLOW_SPRINT_MOVEMENT_SPEED)
end

function BarteringFollow.pullToMaster(entry, zombie, player, sprintSpeed)
    if not player or player:isDead() then
        return
    end

    releaseBump(zombie)
    recordPlayerWindow(zombie, player)

    if entry.combatTask ~= nil or entry.retreatActive then
        return
    end

    BarteringAIUtils.publishGoal(zombie, player:getX(), player:getY(), player:getZ(), "hire.pull")
    applyFollowWalk(zombie, zombie:getHealth() < 0.8 and "BartererLimp" or "BartererSprint", sprintSpeed)
end

return BarteringFollow
