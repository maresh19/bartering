local isServer = _G["isServer"]
local getOnlinePlayers = _G["getOnlinePlayers"]
local getNumActivePlayers = _G["getNumActivePlayers"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getCell = _G["getCell"]
local instanceof = _G["instanceof"]
local IsoFlagType = _G["IsoFlagType"]

local BarteringPathTrace = require "BarteringPathTrace"

local BarteringAIUtils = {}
BarteringAIUtils.APPROACH_CROWD_DISTANCE = 3
BarteringAIUtils.APPROACH_CROWD_DISTANCE_SQ = BarteringAIUtils.APPROACH_CROWD_DISTANCE * BarteringAIUtils.APPROACH_CROWD_DISTANCE
BarteringAIUtils.APPROACH_CROWD_MIN = 1
BarteringAIUtils.APPROACH_FIGHT_RADIUS = 7
BarteringAIUtils.APPROACH_FIGHT_RADIUS_SQ = BarteringAIUtils.APPROACH_FIGHT_RADIUS * BarteringAIUtils.APPROACH_FIGHT_RADIUS
BarteringAIUtils.MELEE_THREAT_DISTANCE = 2
BarteringAIUtils.MELEE_THREAT_DISTANCE_SQ = BarteringAIUtils.MELEE_THREAT_DISTANCE * BarteringAIUtils.MELEE_THREAT_DISTANCE

BarteringAIUtils.DOWNED_ACTION_STATES = {
    ["onground"] = true,
    ["getup"] = true,
    ["getup-fromonback"] = true,
    ["getup-fromonfront"] = true,
    ["getup-fromsitting"] = true,
}

BarteringAIUtils.STAGGER_ACTION_STATES = {
    ["staggerback"] = true,
    ["staggerback-knockeddown"] = true,
}

BarteringAIUtils.HOSTILE_ACTION_STATES = {
    ["lunge"] = true,
    ["attack"] = true,
    ["face-target"] = true,
    ["thump"] = true,
}

function BarteringAIUtils.distanceSq(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return dx * dx + dy * dy
end

function BarteringAIUtils.distanceSqToTile(x, y, tileX, tileY)
    return BarteringAIUtils.distanceSq(x, y, tileX + 0.5, tileY + 0.5)
end

function BarteringAIUtils.distanceSqBetween(a, b)
    return BarteringAIUtils.distanceSq(a:getX(), a:getY(), b:getX(), b:getY())
end

function BarteringAIUtils.findBartererEntry(roster, bartererId)
    for _, entry in ipairs(roster) do
        if entry.bartererId == bartererId then
            return entry
        end
    end
    return nil
end

function BarteringAIUtils.isDownedActionState(actionState)
    return BarteringAIUtils.DOWNED_ACTION_STATES[actionState] == true
end

function BarteringAIUtils.isHostileActionState(actionState)
    return BarteringAIUtils.HOSTILE_ACTION_STATES[actionState] == true
end

function BarteringAIUtils.isDowned(zombie)
    return zombie:isProne() or BarteringAIUtils.isDownedActionState(zombie:getActionStateName())
end

function BarteringAIUtils.isStandableSquare(square)
    if not square or not square:isFree(false) then
        return false
    end

    if square:Is(IsoFlagType.solid) or square:Is(IsoFlagType.solidtrans) then
        return false
    end

    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local neighbour = getCell():getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
                if neighbour and neighbour:isFree(false) then
                    return true
                end
            end
        end
    end

    return false
end

function BarteringAIUtils.isOccupiedByOtherZombie(x, y, z, selfZombie)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local zed = zombies:get(i)
        if zed ~= selfZombie and not zed:isDead() and zed:getZ() == z then
            if math.floor(zed:getX()) == x and math.floor(zed:getY()) == y then
                return true
            end
        end
    end
    return false
end

function BarteringAIUtils.countZombiesAround(x, y, z, radiusSq)
    local count = 0
    local zombies = getCell():getZombieList()
    local centerX = x + 0.5
    local centerY = y + 0.5
    for i = 0, zombies:size() - 1 do
        local other = zombies:get(i)
        if not other:isDead() and not other:getVariableBoolean("Barterer") and other:getZ() == z then
            if BarteringAIUtils.distanceSq(other:getX(), other:getY(), centerX, centerY) <= radiusSq then
                count = count + 1
            end
        end
    end
    return count
end

function BarteringAIUtils.forEachThreatZombie(selfZombie, callback)
    BarteringPathTrace.counter(selfZombie, "scan.threatZombieList")
    local zombies = getCell():getZombieList()
    local sx, sy, sz = selfZombie:getX(), selfZombie:getY(), selfZombie:getZ()
    for i = 0, zombies:size() - 1 do
        local other = zombies:get(i)
        if other ~= selfZombie and not other:isDead() and not other:getVariableBoolean("Barterer") then
            local dx = other:getX() - sx
            local dy = other:getY() - sy
            if callback(other, dx * dx + dy * dy, dx, dy, other:getZ() == sz) then
                return true
            end
        end
    end
    return false
end

function BarteringAIUtils.forEachPlayer(callback)
    if isServer() then
        local players = getOnlinePlayers()
        if players then
            for i = 0, players:size() - 1 do
                local player = players:get(i)
                if player and not player:isDead() then
                    if callback(player) then return true end
                end
            end
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player and not player:isDead() then
                if callback(player) then return true end
            end
        end
    end
    return false
end

function BarteringAIUtils.getAnyAvailablePlayer()
    local found = nil
    BarteringAIUtils.forEachPlayer(function(player)
        found = player
        return true
    end)
    return found
end

function BarteringAIUtils.resetPassiveState(zombie)
    Bartering.clearEngineTarget(zombie)
    zombie:setEatBodyTarget(nil, false)
end

function BarteringAIUtils.clearPathing(zombie)
    BarteringPathTrace.counter(zombie, zombie:hasPath() and "path.clear.hadPath" or "path.clear.noPath")
    zombie:getPathFindBehavior2():cancel()
    zombie:getPathFindBehavior2():reset()
    zombie:setPath2(nil)
end

function BarteringAIUtils.detachPath(zombie)
    BarteringPathTrace.counter(zombie, zombie:hasPath() and "path.detach.hadPath" or "path.detach.noPath")
    zombie:getPathFindBehavior2():cancel()
    zombie:setPath2(nil)
end


function BarteringAIUtils.suppressZombieCombat(zombie)
    zombie:setZombiesDontAttack(true)
    zombie:setNoTeeth(true)
    Bartering.clearEngineTarget(zombie)
    zombie:setThumpTarget(nil)
    zombie:setTimeThumping(0)
end


function BarteringAIUtils.setVariableIfChanged(zombie, name, value)
    if zombie:getVariableString(name) == value then
        return
    end
    zombie:setVariable(name, value)
end

function BarteringAIUtils.clearGoal(zombie, source)
    BarteringPathTrace.goalCleared(zombie, source)

    if zombie:getVariableString("BartererGoalX") == ""
        and zombie:getVariableString("BartererGoalY") == ""
        and zombie:getVariableString("BartererGoalZ") == "" then
        return
    end

    zombie:setVariable("BartererGoalX", "")
    zombie:setVariable("BartererGoalY", "")
    zombie:setVariable("BartererGoalZ", "")
end

function BarteringAIUtils.publishGoal(zombie, x, y, z, source)
    BarteringPathTrace.goal(zombie, source, x, y, z)

    local goalX = tostring(math.floor(x))
    local goalY = tostring(math.floor(y))
    local goalZ = tostring(math.floor(z))

    if zombie:getVariableString("BartererGoalX") == goalX
        and zombie:getVariableString("BartererGoalY") == goalY
        and zombie:getVariableString("BartererGoalZ") == goalZ then
        return
    end

    zombie:setVariable("BartererGoalX", goalX)
    zombie:setVariable("BartererGoalY", goalY)
    zombie:setVariable("BartererGoalZ", goalZ)
end

function BarteringAIUtils.countZombiesWithin(zombie, radiusSq)
    local count = 0
    BarteringAIUtils.forEachThreatZombie(zombie, function(_, distanceSq, _, _, sameLevel)
        if sameLevel and distanceSq <= radiusSq then
            count = count + 1
        end
        return false
    end)
    return count
end

function BarteringAIUtils.tryOpenNearbyDoor(zombie, skipWindows)
    local zx = math.floor(zombie:getX())
    local zy = math.floor(zombie:getY())
    local zz = zombie:getZ()
    local currentSquare = zombie:getCurrentSquare()
    local insideBuilding = currentSquare and currentSquare:getRoom() ~= nil

    local function canOpenDoor(object)
        if not object or object:IsOpen() then
            return false
        end

        if object.isBarricaded and object:isBarricaded() then
            return false
        end

        if object.isObstructed and object:isObstructed() then
            return false
        end

        local forceLocked = false
        if object.getProperties then
            local props = object:getProperties()
            forceLocked = props and props:Is("forceLocked") or false
        end

        local locked = (object.isLocked and object:isLocked())
            or (object.isLockedByKey and object:isLockedByKey())
        if locked and (not insideBuilding or forceLocked) then
            return false
        end

        return true
    end

    local function openDoor(object, square)
        if not canOpenDoor(object) then
            return false
        end

        object:ToggleDoorSilent()

        if square then
            square:InvalidateSpecialObjectPaths()
            square:RecalcProperties()
        end
        object:syncIsoObject(false, 1, nil, nil)

        return true
    end

    local function canOpenWindow(window)
        if not window or window:IsOpen() then
            return false
        end

        if window:isBarricaded() or window:isInvincible() then
            return false
        end

        if window:isLocked() and not insideBuilding then
            return false
        end

        return true
    end

    local function openWindow(window, square)
        if not canOpenWindow(window) then
            return false
        end

        if window:isLocked() then
            window:setIsLocked(false)
        end
        window:ToggleWindow(zombie)

        if square then
            square:InvalidateSpecialObjectPaths()
            square:RecalcProperties()
        end

        window:syncIsoObject(false, 1, nil, nil)

        return true
    end

    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = getCell():getGridSquare(zx + dx, zy + dy, zz)
            if square then
                local door = square:getIsoDoor()
                if door and openDoor(door, square) then
                    return "door"
                end

                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if (instanceof(object, "IsoDoor") or (instanceof(object, "IsoThumpable") and object:isDoor() == true))
                        and openDoor(object, square) then
                        return "door"
                    end
                    if not skipWindows and instanceof(object, "IsoWindow") and openWindow(object, square) then
                        return "window"
                    end
                end
            end
        end
    end

    return nil
end

return BarteringAIUtils
