local ZombieIdleState = _G["ZombieIdleState"]

require "Bartering"
local BarteringTasks = require "Movement/BarteringTasks"
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log

local BarteringClimbingUtils = {}

local CLIMB_ACTION_UNSTICK_TICKS = 150
local CLIMB_TIMEOUT_TICKS = 180
local CLIMB_COOLDOWN_TICKS = 30

BarteringClimbingUtils.CLIMB_COOLDOWN_TICKS = CLIMB_COOLDOWN_TICKS

BarteringClimbingUtils.CROSSING_STEPS = {
    { x = 1, y = 0 },
    { x = -1, y = 0 },
    { x = 0, y = 1 },
    { x = 0, y = -1 },
}

function BarteringClimbingUtils.logClimb(zombie, reason, detail)
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

function BarteringClimbingUtils.hasNonMoveTask(zombie)
    for _, task in pairs(BarteringTasks.GetBrain(zombie).tasks) do
        if task.action ~= "Move" then
            return true
        end
    end
    return false
end

function BarteringClimbingUtils.clearClimbLatch(brain)
    brain.fenceLatchX = nil
    brain.fenceLatchY = nil
    brain.fenceLatchTileX = nil
    brain.fenceLatchTileY = nil
    brain.fenceLatchState = nil
    brain.fenceLatchSrcX = nil
    brain.fenceLatchSrcY = nil
    brain.fenceLatchSrcZ = nil
end

function BarteringClimbingUtils.giveUpOnClimb(zombie, brain, reason)
    BarteringClimbingUtils.logClimb(zombie, "gave up on climb; cancelling", reason)
    BarteringPathTrace.counter(zombie, "fence.gaveUp")
    zombie:setCollidable(true)
    zombie:setVariable("hitreaction", "")
    zombie:setVariable("BartererClimbing", false)
    brain.windowClimbing = nil
    brain.windowClimbEntered = nil
    brain.fenceClimbTicks = nil
    brain.fenceAttempts = 0
    brain.fenceFaceTicks = 0
    brain.fenceClosingIn = nil
    brain.fenceCloseTicks = nil
    brain.fenceBlockedTicks = 0
    brain.fenceCooldown = CLIMB_COOLDOWN_TICKS
    brain.hopStepX, brain.hopStepY = nil, nil

    BarteringClimbingUtils.clearClimbLatch(brain)
    BarteringTasks.StopMovement(zombie)
    zombie:setStateMachineLocked(false)
    zombie:changeState(ZombieIdleState.instance())
end

function BarteringClimbingUtils.repathAfterClimb(zombie)
    BarteringPathTrace.counter(zombie, "climb.repathed")
    BarteringTasks.StopTasks(zombie)
    BarteringAIUtils.clearPathing(zombie)
end

function BarteringClimbingUtils.updateClimbRelease(zombie)
    local brain = BarteringTasks.GetBrain(zombie)

    if brain.fenceHighVaulting and zombie:getBumpType() ~= "ClimbFenceTall" then
        local vdx = zombie:getX() - brain.fenceHopX
        local vdy = zombie:getY() - brain.fenceHopY
        BarteringClimbingUtils.logClimb(zombie, "high fence: vault outcome", string.format("movedSinceHop=%.2f distAtHop=%.2f",
            math.sqrt(vdx * vdx + vdy * vdy), brain.fenceHopDistance or -1))
        brain.fenceHighVaulting = nil
        brain.fenceHopDistance = nil
        brain.fenceHopX = nil
        brain.fenceClimbTicks = nil
        zombie:setCollidable(true)
        zombie:setVariable("BartererClimbing", false)
        BarteringClimbingUtils.clearClimbLatch(brain)
        BarteringClimbingUtils.repathAfterClimb(zombie)
    end

    if brain.windowClimbing then
        if zombie:getActionStateName() == "climbwindow" then
            brain.windowClimbEntered = true
        elseif brain.windowClimbEntered then
            local wdx = zombie:getX() - brain.windowClimbX
            local wdy = zombie:getY() - brain.windowClimbY
            BarteringClimbingUtils.logClimb(zombie, "window climb outcome", string.format("movedSinceClimb=%.2f",
                math.sqrt(wdx * wdx + wdy * wdy)))
            brain.windowClimbing = nil
            brain.windowClimbEntered = nil
            brain.windowClimbX, brain.windowClimbY = nil, nil
            brain.fenceClimbTicks = nil
            zombie:setVariable("BartererClimbing", false)
            BarteringClimbingUtils.repathAfterClimb(zombie)
        end
    end

    if zombie:getVariableBoolean("BartererClimbing") then
        brain.fenceClimbTicks = (brain.fenceClimbTicks or 0) + 1
        if brain.fenceClimbTicks > CLIMB_TIMEOUT_TICKS then
            BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format(
                "climb timed out; releasing hold (ticks=%d action=%s windowClimb=%s entered=%s)",
                brain.fenceClimbTicks, tostring(zombie:getActionStateName()),
                tostring(brain.windowClimbing), tostring(brain.windowClimbEntered)))
        end
    end

    if brain.fenceCooldown and brain.fenceCooldown > 0 then
        brain.fenceCooldown = brain.fenceCooldown - 1
        if brain.fenceCooldown == 0 and brain.fenceHopX and not brain.fenceHighVaulting then
            local hdx = zombie:getX() - brain.fenceHopX
            local hdy = zombie:getY() - brain.fenceHopY
            BarteringClimbingUtils.logClimb(zombie, "hop outcome", string.format("movedSinceHop=%.2f distAtHop=%.2f",
                math.sqrt(hdx * hdx + hdy * hdy), brain.fenceHopDistance or -1))
            brain.fenceHopDistance = nil
            brain.fenceHopX = nil
            zombie:setCollidable(true)
            zombie:setVariable("hitreaction", "")
            zombie:setVariable("BartererClimbing", false)
            brain.fenceClimbTicks = nil
            BarteringClimbingUtils.clearClimbLatch(brain)
            BarteringClimbingUtils.repathAfterClimb(zombie)
        end
    end
end

function BarteringClimbingUtils.suppressClimbEngine(zombie)
    local driveAsn = zombie:getActionStateName()
    if zombie:getVariableBoolean("BartererClimbing")
        or driveAsn == "climbfence" or driveAsn == "climbwindow" then
        zombie:setUseless(true)
        Bartering.clearEngineTarget(zombie)
        zombie:setThumpTarget(nil)
        BarteringAIUtils.detachPath(zombie)
    end
end

function BarteringClimbingUtils.manageActionState(zombie)
    local asn = zombie:getActionStateName()

    if asn ~= "climbfence" and asn ~= "climbwindow" and asn ~= "hitreaction" then
        local brain = BarteringTasks.GetBrain(zombie)
        brain.climbActionTicks = nil
    end

    if asn == "pathfind" then
        zombie:setUseless(true)
        zombie:setTarget(nil)
        zombie:setTargetSeenTime(0)
        zombie:clearAggroList()
        if not BarteringTasks.HasTask(zombie) then
            BarteringPathTrace.counter(zombie, "drive.enginePathfindCancelled")
            BarteringAIUtils.clearPathing(zombie)
            zombie:changeState(ZombieIdleState.instance())
            return false, "enginePathfindCancelled"
        end
        return false, "enginePathfind"
    end

    if asn == "climbfence" or asn == "climbwindow" or asn == "hitreaction" then
        local brain = BarteringTasks.GetBrain(zombie)
        brain.climbActionTicks = (brain.climbActionTicks or 0) + 1
        if brain.climbActionTicks >= CLIMB_ACTION_UNSTICK_TICKS then
            BarteringPathTrace.counter(zombie, "drive.climbActionStuck")
            local stuckTicks = brain.climbActionTicks
            brain.climbActionTicks = nil
            BarteringClimbingUtils.giveUpOnClimb(zombie, brain, string.format(
                "climb action stuck in %s for %d ticks; releasing hold",
                asn, stuckTicks))
            zombie:changeState(ZombieIdleState.instance())
            return true
        end
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

    if asn == "eatbody" then
        BarteringPathTrace.counter(zombie, "drive.eatBodyCancelled")
        zombie:setEatBodyTarget(nil, false)
        zombie:changeState(ZombieIdleState.instance())
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

return BarteringClimbingUtils