Bartering = Bartering or {}

local getGameTime = _G["getGameTime"]
local getCell = _G["getCell"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local BarteringPathTrace = require "BarteringPathTrace"

local BarteringArrive = {}

BarteringArrive.ARRIVED_AT_POST_DISTANCE = 1.10
local CALLER_BLOCKING_DISTANCE_SQ = 2.25 * 2.25

local clearGoal = BarteringAIUtils.clearGoal

function BarteringArrive.new(deps)
    local function complete(entry, zombie, postX, postY, postZ, logReason, targetPX, targetPY)
        entry.postX, entry.postY, entry.postZ = postX, postY, postZ
        entry.returningToPost = false
        entry.hasArrived = true
        entry.returnFarTicks = 0
        entry.continuingTrip = false
        if entry.intercepted then
            entry.intercepted = false
            entry.ignoreCombat = false
            entry.interceptMeet = false
        end
        deps.cancelMove(zombie, "arrive.moveCancelled")
        deps.report(entry, "arrived", { postX = postX, postY = postY, postZ = postZ })

        deps.forceReturnNeutralState(entry, zombie)

        local here = zombie:getSquare()
        local targetSquare = getCell():getGridSquare(math.floor(targetPX), math.floor(targetPY), postZ)
        local door = targetSquare ~= here and here:getDoorTo(targetSquare)
        local doorState = door and BarteringAIUtils.doorStateFor(door)
        if doorState == "openable" then
            BarteringPathTrace.counter(zombie, "arrive.openedDoorToTarget")
            BarteringAIUtils.openDoorObject(door)
        end
        if doorState == "blocked" then
            clearGoal(zombie, "approach")
            deps.reportDoorLocked(entry, zombie, door)
            deps.logBartererServerDebug(zombie, logReason .. "; blocked openable", "BlockedByDoor")
            BarteringPathTrace.aiStop(zombie, "move.approach.arrivedBlockedOpenable")
            return
        end

        clearGoal(zombie, "approach")
        deps.applyWaitingState(entry, zombie)
        deps.logBartererServerDebug(zombie, logReason, "Waiting")
        deps.updateIdleFacing(entry, zombie)
    end

    local function update(entry, zombie, targetX, targetY, targetZ, hasApproachTarget)
        if hasApproachTarget then
            local adx = zombie:getX() - (targetX + 0.5)
            local ady = zombie:getY() - (targetY + 0.5)
            local onTile = math.floor(zombie:getX()) == targetX and math.floor(zombie:getY()) == targetY
            local arrivedSq = BarteringArrive.ARRIVED_AT_POST_DISTANCE * BarteringArrive.ARRIVED_AT_POST_DISTANCE
            local master = entry.master
            local callerOnTile = master ~= nil
                and math.floor(master:getX()) == targetX and math.floor(master:getY()) == targetY
                and BarteringAIUtils.distanceSqBetween(master, zombie) <= CALLER_BLOCKING_DISTANCE_SQ
            if zombie:getZ() == targetZ and (onTile or callerOnTile or (adx * adx + ady * ady) <= arrivedSq) then
                complete(entry, zombie,
                    onTile and targetX or math.floor(zombie:getX()),
                    onTile and targetY or math.floor(zombie:getY()),
                    targetZ,
                    callerOnTile and "arrived at call location; caller is standing on it"
                        or "arrived at call location",
                    targetX + 0.5, targetY + 0.5)
                BarteringPathTrace.aiStop(zombie, "move.approach.arrivedAtCallLocation")
                return true
            end
        end

        return false
    end

    local function meetPlayer(entry, zombie, player)
        complete(entry, zombie, math.floor(zombie:getX()), math.floor(zombie:getY()), zombie:getZ(),
            "met the player on the way", player:getX(), player:getY())
    end

    return {
        update = update,
        meetPlayer = meetPlayer,
    }
end

return BarteringArrive
