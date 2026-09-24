local isServer = _G["isServer"]
local getOnlinePlayers = _G["getOnlinePlayers"]
local getNumActivePlayers = _G["getNumActivePlayers"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getCell = _G["getCell"]
local instanceof = _G["instanceof"]
local IsoFlagType = _G["IsoFlagType"]
local ZombRand = _G["ZombRand"]

local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringTiming = require "BarteringTiming"

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

BarteringAIUtils.KNOCKED_OVER_STATE_PREFIXES = {
    "staggerback",
    "falldown",
    "knockeddown",
    "onground",
    "getup",
    "hitwhilestaggered",
    "hitreaction-onfloor",
    "hitreaction-gettingup",
}

function BarteringAIUtils.isKnockedOver(zombie)
    if zombie:isStaggerBack() or zombie:isKnockedDown() or BarteringAIUtils.isDowned(zombie) then
        return true
    end
    local actionState = string.lower(zombie:getActionStateName())
    for _, prefix in ipairs(BarteringAIUtils.KNOCKED_OVER_STATE_PREFIXES) do
        if string.sub(actionState, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

function BarteringAIUtils.isStandableSquare(square)
    if not square or not square:isFree(false) then
        return false
    end

    if square:has(IsoFlagType.solid) or square:has(IsoFlagType.solidtrans) then
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

function BarteringAIUtils.forEachZombie(callback)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        if callback(zombies:get(i)) then
            return true
        end
    end
    return false
end

function BarteringAIUtils.isBartererZombie(zombie)
    if zombie:getVariableBoolean("Barterer") then
        return true
    end
    return Bartering.resolveBartererRecord(zombie) ~= nil
end

function BarteringAIUtils.isOccupiedByOtherZombie(x, y, z, selfZombie)
    return BarteringAIUtils.forEachZombie(function(zed)
        return zed ~= selfZombie and not zed:isDead() and zed:getZ() == z
            and math.floor(zed:getX()) == x and math.floor(zed:getY()) == y
    end)
end

function BarteringAIUtils.hasZombiesAround(x, y, z, radiusSq, minCount)
    local count = 0
    return BarteringAIUtils.forEachZombie(function(other)
        if BarteringAIUtils.distanceSq(other:getX(), other:getY(), x + 0.5, y + 0.5) <= radiusSq
            and other:getZ() == z and not other:isDead() and not BarteringAIUtils.isBartererZombie(other) then
            count = count + 1
            return count >= minCount
        end
    end)
end

function BarteringAIUtils.countZombiesNear(x, y, z, radiusSq)
    local count = 0
    local level = math.floor(z)
    BarteringAIUtils.forEachZombie(function(other)
        if math.floor(other:getZ()) == level
            and BarteringAIUtils.distanceSq(other:getX(), other:getY(), x, y) <= radiusSq then
            count = count + 1
        end
    end)
    return count
end

function BarteringAIUtils.countZombiesTargeting(character, radiusSq)
    local count = 0
    BarteringAIUtils.forEachZombie(function(zombie)
        if not zombie:isDead() and not BarteringAIUtils.isBartererZombie(zombie)
            and zombie:getTarget() == character
            and BarteringAIUtils.distanceSqBetween(zombie, character) <= radiusSq then
            count = count + 1
        end
    end)
    return count
end

local threatSnapshots = {}
local threatSnapshotTick = 0

function BarteringAIUtils.advanceThreatSnapshots()
    for zombie, snapshot in pairs(threatSnapshots) do
        if snapshot.tick ~= threatSnapshotTick then
            threatSnapshots[zombie] = nil
        end
    end
    threatSnapshotTick = threatSnapshotTick + 1
end

local function isHostileBarterer(zombie)
    local _, bartererId = Bartering.resolveBartererRecord(zombie)
    return bartererId ~= nil and Bartering.Hostility.hasUnresolved(bartererId)
end

local function buildThreatSnapshot(selfZombie)
    local snapshot = threatSnapshots[selfZombie]
    if not snapshot then
        snapshot = { count = 0, threats = {}, distances = {}, dxs = {}, dys = {}, sameLevels = {} }
        threatSnapshots[selfZombie] = snapshot
    end
    snapshot.tick = threatSnapshotTick

    local threats, distances, dxs, dys, sameLevels =
        snapshot.threats, snapshot.distances, snapshot.dxs, snapshot.dys, snapshot.sameLevels
    local sx, sy, sz = selfZombie:getX(), selfZombie:getY(), selfZombie:getZ()
    local count = 0
    local selfHostile = isHostileBarterer(selfZombie)
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local other = zombies:get(i)
        if other ~= selfZombie and not other:isDead()
            and (not BarteringAIUtils.isBartererZombie(other) or isHostileBarterer(other) ~= selfHostile) then
            local dx = other:getX() - sx
            local dy = other:getY() - sy
            count = count + 1
            threats[count] = other
            distances[count] = dx * dx + dy * dy
            dxs[count] = dx
            dys[count] = dy
            sameLevels[count] = other:getZ() == sz
        end
    end
    for i = count + 1, snapshot.count do
        threats[i] = nil
    end
    snapshot.count = count
    return snapshot
end

function BarteringAIUtils.forEachThreatZombie(selfZombie, callback)
    BarteringPathTrace.counter(selfZombie, "scan.threatZombieList")
    local snapshot = threatSnapshots[selfZombie]
    if not snapshot or snapshot.tick ~= threatSnapshotTick then
        snapshot = buildThreatSnapshot(selfZombie)
    end
    local threats, distances, dxs, dys, sameLevels =
        snapshot.threats, snapshot.distances, snapshot.dxs, snapshot.dys, snapshot.sameLevels
    for i = 1, snapshot.count do
        if callback(threats[i], distances[i], dxs[i], dys[i], sameLevels[i]) then
            return true
        end
    end
    return false
end

function BarteringAIUtils.forEachPlayer(callback, includeDead)
    if isServer() or isClient() then
        local players = getOnlinePlayers()
        if players then
            for i = 0, players:size() - 1 do
                local player = players:get(i)
                if player and (includeDead or not player:isDead()) then
                    if callback(player) then return true end
                end
            end
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player and (includeDead or not player:isDead()) then
                if callback(player) then return true end
            end
        end
    end
    return false
end

function BarteringAIUtils.findPlayer(predicate)
    local found = nil
    BarteringAIUtils.forEachPlayer(function(player)
        if predicate(player) then
            found = player
            return true
        end
    end)
    return found
end

function BarteringAIUtils.getAnyAvailablePlayer()
    return BarteringAIUtils.findPlayer(function()
        return true
    end)
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

local ZOMBIE_VOICE_SOUNDS = {
    "MaleZombieVoiceA",
    "MaleZombieVoiceB",
    "MaleZombieVoiceC",
    "FemaleZombieVoiceA",
    "FemaleZombieVoiceB",
    "FemaleZombieVoiceC",
}

function BarteringAIUtils.silenceZombieVoice(zombie)
    local emitter = zombie:getEmitter()
    for _, sound in ipairs(ZOMBIE_VOICE_SOUNDS) do
        emitter:stopSoundByName(sound)
    end
end

function BarteringAIUtils.resistKnockdown(zombie, attacker)
    local fallChance = SandboxVars.Bartering.ShoveKnockdownChance
    if ZombRand(100) < fallChance then
        print(string.format("[Bartering][Shove] letting %s fall (%d%% chance)",
            tostring(zombie:getVariableString("BartererId")), fallChance))
        return false
    end

    attacker:setCriticalHit(false)
    zombie:setAlwaysKnockedDown(false)
    print(string.format("[Bartering][Shove] resisting knockdown on %s | state=%s onFloor=%s",
        tostring(zombie:getVariableString("BartererId")), tostring(zombie:getActionStateName()),
        tostring(zombie:isOnFloor())))
    return true
end

function BarteringAIUtils.keepBartererDocile(zombie)
    BarteringAIUtils.silenceZombieVoice(zombie)
    zombie:setNoTeeth(true)
    zombie:setVariable("NoLungeAttack", true)
    zombie:setZombiesDontAttack(true)
    BarteringAIUtils.resetPassiveState(zombie)
    zombie:setWalkType(zombie:getVariableString("BartererWalkType") or "BartererWalk")
    zombie:setSpeedMod(1)
end

function BarteringAIUtils.setBartererWalkType(zombie, walkType)
    zombie:setWalkType(walkType)
    zombie:setVariable("BartererWalkType", walkType)
end


function BarteringAIUtils.playScriptedBump(entry, zombie, bumpType)
    zombie:setVariable("BumpAnimFinished", false)
    zombie:setBumpType(bumpType)
    entry.scriptedBumpAtMs = BarteringTiming.now()
end

function BarteringAIUtils.sayBarterer(bartererId, text)
    if isServer() then
        sendServerCommand("Bartering", "bartererSay", { bartererId = bartererId, text = text })
        return
    end
    Bartering.showBartererSay(bartererId, text)
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), "Bartering", "relaySay", { bartererId = bartererId, text = text })
    end
end

function BarteringAIUtils.setVariableIfChanged(zombie, name, value)
    if zombie:getVariableString(name) == value then
        return
    end
    zombie:setVariable(name, value)
end

local goals = {}

function BarteringAIUtils.getGoal(zombie)
    local goal = goals[zombie:getVariableString("BartererId")]
    if not goal then
        return nil, nil, nil, false
    end
    return goal.x, goal.y, goal.z, goal.precise
end

function BarteringAIUtils.clearGoal(zombie, source)
    BarteringPathTrace.goalCleared(zombie, source)
    goals[zombie:getVariableString("BartererId")] = nil
end

local function setGoal(zombie, x, y, z, source, precise)
    BarteringPathTrace.goal(zombie, source, x, y, z)

    local bartererId = zombie:getVariableString("BartererId")
    local goal = goals[bartererId]
    if not goal then
        goal = {}
        goals[bartererId] = goal
    end
    goal.x, goal.y, goal.z, goal.precise = math.floor(x), math.floor(y), math.floor(z), precise
end

function BarteringAIUtils.publishGoal(zombie, x, y, z, source)
    setGoal(zombie, x, y, z, source, false)
end

function BarteringAIUtils.publishExactGoal(zombie, x, y, z, source)
    setGoal(zombie, x, y, z, source, true)
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

function BarteringAIUtils.openableKey(object)
    local className = object:getClass():getSimpleName()
    local kind = className == "IsoWindow" and "window"
        or ((className == "IsoDoor"
            or (className == "IsoThumpable" and object:isDoor() == true)) and "door" or "object")
    return string.format("%s:%d,%d,%d", kind, math.floor(object:getX()), math.floor(object:getY()), object:getZ())
end

local function isWindowObject(object)
    return object:getClass():getSimpleName() == "IsoWindow"
end

local function isDoorObject(object)
    return not isWindowObject(object)
        and (object:getClass():getSimpleName() == "IsoDoor"
            or (object:getClass():getSimpleName() == "IsoThumpable" and object:isDoor() == true))
end

function BarteringAIUtils.windowStateFor(zombie, window)
    if window:IsOpen() then
        return "open"
    end

    if window:isBarricaded() or window:isInvincible() then
        return "blocked"
    end

    if window:isLocked() then
        return "blocked"
    end

    return "openable"
end

function BarteringAIUtils.openWindowFor(zombie, window)
    local state = BarteringAIUtils.windowStateFor(zombie, window)
    if state ~= "openable" then
        return false
    end

    window:ToggleWindow(zombie)

    local square = window:getSquare()
    if square then
        square:InvalidateSpecialObjectPaths()
        square:RecalcProperties()
    end
    window:syncIsoObject(false, 1, nil, nil)

    return true
end

function BarteringAIUtils.isInteriorDoor(door)
    local cell = getCell()
    local doorX, doorY, z = math.floor(door:getX()), math.floor(door:getY()), door:getZ()
    local own = cell:getGridSquare(doorX, doorY, z)
    local across = cell:getGridSquare(door:getNorth() and doorX or (doorX - 1),
        door:getNorth() and (doorY - 1) or doorY, z)
    return own ~= nil and across ~= nil
        and own:getRoom() ~= nil and across:getRoom() ~= nil
end

function BarteringAIUtils.doorStateFor(object)
    if object:IsOpen() then
        return "open"
    end

    if object.isBarricaded and object:isBarricaded() then
        return "blocked"
    end

    if object.isObstructed and object:isObstructed() then
        return "blocked"
    end

    local locked = (object.isLocked and object:isLocked())
        or (object.isLockedByKey and object:isLockedByKey())
    if locked and not object:isHoppable() and not BarteringAIUtils.isInteriorDoor(object) then
        return "blocked"
    end

    return "openable"
end

function BarteringAIUtils.doorFlags(object)
    return string.format("open=%s locked=%s key=%s obstructed=%s barricaded=%s",
        tostring(object:IsOpen()), tostring(object:isLocked()), tostring(object:isLockedByKey()),
        tostring(object:isObstructed()), tostring(object:isBarricaded()))
end

local WALK_STEPS = {
    { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 },
    { x = 1, y = 1 }, { x = 1, y = -1 }, { x = -1, y = 1 }, { x = -1, y = -1 },
}

function BarteringAIUtils.squareWithinWalk(fromSquare, targetSquare, maxSteps)
    if not fromSquare or not targetSquare or fromSquare:getZ() ~= targetSquare:getZ() then
        return false
    end
    local targetX, targetY = targetSquare:getX(), targetSquare:getY()
    if fromSquare:getX() == targetX and fromSquare:getY() == targetY then
        return true
    end
    if math.abs(fromSquare:getX() - targetX) > maxSteps or math.abs(fromSquare:getY() - targetY) > maxSteps then
        return false
    end

    local cell = getCell()
    local z = fromSquare:getZ()
    local seen = { [fromSquare:getX() .. "," .. fromSquare:getY()] = true }
    local frontier = { fromSquare }
    for _ = 1, maxSteps do
        local nextFrontier = {}
        for _, square in ipairs(frontier) do
            local x, y = square:getX(), square:getY()
            for _, step in ipairs(WALK_STEPS) do
                local nx, ny = x + step.x, y + step.y
                local key = nx .. "," .. ny
                local neighbour = not seen[key] and cell:getGridSquare(nx, ny, z)
                if neighbour then
                    local open
                    if step.x ~= 0 and step.y ~= 0 then
                        local sideA = cell:getGridSquare(nx, y, z)
                        local sideB = cell:getGridSquare(x, ny, z)
                        open = (sideA and not square:isBlockedTo(sideA) and not sideA:isBlockedTo(neighbour))
                            or (sideB and not square:isBlockedTo(sideB) and not sideB:isBlockedTo(neighbour))
                    else
                        open = not square:isBlockedTo(neighbour)
                    end
                    if open then
                        if nx == targetX and ny == targetY then
                            return true
                        end
                        seen[key] = true
                        nextFrontier[#nextFrontier + 1] = neighbour
                    end
                end
            end
        end
        frontier = nextFrontier
    end
    return false
end

function BarteringAIUtils.doorSeparates(door, ax, ay, bx, by)
    local doorX = math.floor(door:getX())
    local doorY = math.floor(door:getY())
    local a, b, alongA, alongB, edge, spanStart
    if door:getNorth() then
        a, b, alongA, alongB, edge, spanStart = ay, by, ax, bx, doorY, doorX
    else
        a, b, alongA, alongB, edge, spanStart = ax, bx, ay, by, doorX, doorY
    end
    if (a - edge) * (b - edge) >= 0 then
        return false
    end
    local along = alongA + (alongB - alongA) * (edge - a) / (b - a)
    return along >= spanStart and along <= spanStart + 1
end

local function requestDoorState(object, fields)
    local square = object:getSquare()
    fields.x, fields.y, fields.z = square:getX(), square:getY(), square:getZ()
    sendClientCommand(getSpecificPlayer(0), "Bartering", "setDoorState", fields)
end

function BarteringAIUtils.findDoorOnSquare(square)
    local door = square:getIsoDoor()
    if door and isDoorObject(door) then
        return door
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if isDoorObject(object) then
            return object
        end
    end
    return nil
end

function BarteringAIUtils.openDoorObject(object)
    object:ToggleDoorSilent()

    local square = object:getSquare()
    if square then
        square:InvalidateSpecialObjectPaths()
        square:RecalcProperties()
    end
    object:syncIsoObject(false, 1, nil, nil)
    if isClient() then
        requestDoorState(object, { open = true })
    end
end

function BarteringAIUtils.unlockDoorFromInside(zombie, door)
    local here = zombie:getSquare()
    if not here or not here:getBuilding() or door:isBarricaded() or door:isObstructed() then
        return false
    end
    door:setLockedByKey(false)
    door:setIsLocked(false)
    if isClient() then
        requestDoorState(door, { unlock = true })
    end
    return true
end

local LOCKED_DOOR_SEARCH_RADIUS = 12
local DOOR_REACH_MAX_SQUARES = 4000
local DOOR_REACH_STEPS = { { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 } }
local ROUTE_DOOR_SCAN_TILES = 2

function BarteringAIUtils.exteriorOutwardStep(door, z)
    local doorX = math.floor(door:getX())
    local doorY = math.floor(door:getY())
    local stepX = door:getNorth() and 0 or 1
    local stepY = door:getNorth() and 1 or 0
    local ownSquare = getCell():getGridSquare(doorX, doorY, z)
    if ownSquare and ownSquare:getRoom() == nil then
        return stepX, stepY
    end
    return -stepX, -stepY
end

function BarteringAIUtils.doorStagingTile(door, z, maxOffset, minOffset)
    local cell = getCell()
    local doorX = math.floor(door:getX())
    local doorY = math.floor(door:getY())
    local stepX, stepY = BarteringAIUtils.exteriorOutwardStep(door, z)

    for offset = maxOffset, minOffset, -1 do
        local x = doorX + stepX * offset
        local y = doorY + stepY * offset
        local square = cell:getGridSquare(x, y, z)
        if square and square:getRoom() == nil
            and BarteringAIUtils.isStandableSquare(square) then
            return x, y, stepX, stepY
        end
    end

    return nil, nil, stepX, stepY
end

local DOOR_ROUTE_MARGIN = 2

function BarteringAIUtils.doorBuildingBox(door, z)
    local stepX, stepY = BarteringAIUtils.exteriorOutwardStep(door, z)
    local inside = getCell():getGridSquare(
        math.floor(door:getX()) - stepX, math.floor(door:getY()) - stepY, z)
    local building = inside and inside:getBuilding()
    if not building then
        return nil
    end
    local def = building:getDef()
    return def:getX(), def:getY(), def:getX2(), def:getY2()
end

function BarteringAIUtils.doorApproachRoute(door, z, fromX, fromY)
    local x1, y1, x2, y2 = BarteringAIUtils.doorBuildingBox(door, z)
    if not x1 then
        return nil, "door has no building"
    end
    local stepX, stepY = BarteringAIUtils.exteriorOutwardStep(door, z)
    local doorSideX = math.floor(door:getX()) + stepX * DOOR_ROUTE_MARGIN
    local doorSideY = math.floor(door:getY()) + stepY * DOOR_ROUTE_MARGIN
    local route, info = BarteringAIUtils.buildingRoute(x1, y1, x2, y2, fromX, fromY, doorSideX, doorSideY)
    return route, string.format("outward %d,%d %s", stepX, stepY, info)
end

function BarteringAIUtils.windowBuildingNear(zombie)
    local cell = getCell()
    local zx, zy, zz = math.floor(zombie:getX()), math.floor(zombie:getY()), zombie:getZ()
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = cell:getGridSquare(zx + dx, zy + dy, zz)
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if object:getClass():getSimpleName() == "IsoWindow" then
                        local across = object:getNorth()
                            and cell:getGridSquare(square:getX(), square:getY() - 1, zz)
                            or cell:getGridSquare(square:getX() - 1, square:getY(), zz)
                        local building = square:getBuilding() or (across and across:getBuilding())
                        if building then
                            return object, building
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

function BarteringAIUtils.buildingRoute(x1, y1, x2, y2, fromX, fromY, toX, toY)
    local corners = {
        { x = x1 - DOOR_ROUTE_MARGIN, y = y1 - DOOR_ROUTE_MARGIN },
        { x = x2 + DOOR_ROUTE_MARGIN, y = y1 - DOOR_ROUTE_MARGIN },
        { x = x2 + DOOR_ROUTE_MARGIN, y = y2 + DOOR_ROUTE_MARGIN },
        { x = x1 - DOOR_ROUTE_MARGIN, y = y2 + DOOR_ROUTE_MARGIN },
    }

    local function nearestCorner(x, y)
        local best, bestDistance
        for i = 1, 4 do
            local dx = corners[i].x - x
            local dy = corners[i].y - y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = i, distance
            end
        end
        return best
    end

    local startIndex = nearestCorner(fromX, fromY)
    local endIndex = nearestCorner(toX, toY)

    local info = string.format(
        "building %d,%d..%d,%d toward %d,%d corner %d->%d",
        x1, y1, x2, y2, math.floor(toX), math.floor(toY), startIndex, endIndex)

    if startIndex == endIndex then
        return nil, info
    end

    local route = { { x = corners[startIndex].x, y = corners[startIndex].y } }

    if math.abs(endIndex - startIndex) == 2 then
        local left = startIndex == 1 and 4 or startIndex - 1
        local right = startIndex == 4 and 1 or startIndex + 1
        local dxl = corners[left].x - fromX
        local dyl = corners[left].y - fromY
        local dxr = corners[right].x - fromX
        local dyr = corners[right].y - fromY
        local viaIndex = (dxl * dxl + dyl * dyl) <= (dxr * dxr + dyr * dyr) and left or right
        route[#route + 1] = { x = corners[viaIndex].x, y = corners[viaIndex].y }
    end

    route[#route + 1] = { x = corners[endIndex].x, y = corners[endIndex].y }

    return route, info
end

function BarteringAIUtils.doorInteriorTile(door, z)
    local doorX = math.floor(door:getX())
    local doorY = math.floor(door:getY())
    local ownSquare = getCell():getGridSquare(doorX, doorY, z)
    if ownSquare and ownSquare:getRoom() == nil then
        local stepX, stepY = BarteringAIUtils.exteriorOutwardStep(door, z)
        return doorX - stepX, doorY - stepY
    end
    return doorX, doorY
end

function BarteringAIUtils.segmentCrossesDoorBuilding(door, z, ax, ay, bx, by)
    local cell = getCell()
    local insideX, insideY = BarteringAIUtils.doorInteriorTile(door, z)
    local building = cell:getGridSquare(insideX, insideY, z):getBuilding()
    local dx, dy = bx - ax, by - ay
    local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) * 2))
    for i = 0, steps do
        local t = i / steps
        local square = cell:getGridSquare(math.floor(ax + dx * t), math.floor(ay + dy * t), z)
        if square and square:getBuilding() == building then
            return true
        end
    end
    return false
end

local function scanBuildingDoors(zombie, startSquare, goalBuilding, goalZ, goalX, goalY)
    local cell = getCell()
    local reachable = { [startSquare:getX() .. "," .. startSquare:getY()] = true }
    local queue = { startSquare }
    local head = 1
    while head <= #queue and #queue < DOOR_REACH_MAX_SQUARES do
        local square = queue[head]
        head = head + 1
        for _, step in ipairs(DOOR_REACH_STEPS) do
            local nx, ny = square:getX() + step.x, square:getY() + step.y
            local key = nx .. "," .. ny
            if not reachable[key] then
                local neighbour = cell:getGridSquare(nx, ny, goalZ)
                if neighbour and neighbour:getBuilding() == goalBuilding
                    and not square:isWindowTo(neighbour)
                    and (square:isDoorTo(neighbour) or not square:isBlockedTo(neighbour)) then
                    reachable[key] = true
                    queue[#queue + 1] = neighbour
                end
            end
        end
    end

    local function doorOn(square)
        local door = square:getIsoDoor()
        if door and isDoorObject(door) then
            return door
        end
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if isDoorObject(object) then
                return object
            end
        end
        return nil
    end

    local function isExteriorStandable(x, y)
        local square = cell:getGridSquare(x, y, goalZ)
        return square and square:getRoom() == nil
            and BarteringAIUtils.isStandableSquare(square)
    end

    local function exteriorApproachTile(door)
        local doorX = math.floor(door:getX())
        local doorY = math.floor(door:getY())

        local acrossX = door:getNorth() and doorX or (doorX - 1)
        local acrossY = door:getNorth() and (doorY - 1) or doorY

        if isExteriorStandable(doorX, doorY) then
            return doorX, doorY
        end
        if isExteriorStandable(acrossX, acrossY) then
            return acrossX, acrossY
        end

        local bestX, bestY, bestDistance
        for _, step in pairs({ { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 } }) do
            local x, y = doorX + step.x, doorY + step.y
            if isExteriorStandable(x, y) then
                local dx = x + 0.5 - zombie:getX()
                local dy = y + 0.5 - zombie:getY()
                local distance = dx * dx + dy * dy
                if not bestDistance or distance < bestDistance then
                    bestX, bestY, bestDistance = x, y, distance
                end
            end
        end
        return bestX, bestY
    end

    local function servesGoal(door)
        local doorX = math.floor(door:getX())
        local doorY = math.floor(door:getY())
        local ownSquare = cell:getGridSquare(doorX, doorY, goalZ)
        local acrossSquare = cell:getGridSquare(
            door:getNorth() and doorX or (doorX - 1),
            door:getNorth() and (doorY - 1) or doorY, goalZ)
        if not ownSquare or not acrossSquare
            or (ownSquare:getRoom() == nil) == (acrossSquare:getRoom() == nil) then
            return false, "sameSide"
        end
        local inside = ownSquare:getRoom() == nil and acrossSquare or ownSquare
        if reachable[inside:getX() .. "," .. inside:getY()] then
            return true, "ok"
        end
        return false, string.format("insideUnreached(%d,%d)", inside:getX(), inside:getY())
    end

    local here = zombie:getSquare()
    local notes = { string.format("around=%d,%d reach=%d self{has=%s out=%s room=%s}", goalX, goalY, #queue,
        tostring(here:has(IsoFlagType.exterior)), tostring(here:isOutside()), tostring(here:getRoom() ~= nil)) }
    local bestDoor, bestX, bestY, bestState, bestScore
    for dx = -LOCKED_DOOR_SEARCH_RADIUS, LOCKED_DOOR_SEARCH_RADIUS do
        for dy = -LOCKED_DOOR_SEARCH_RADIUS, LOCKED_DOOR_SEARCH_RADIUS do
            local square = cell:getGridSquare(goalX + dx, goalY + dy, goalZ)
            local door = square and doorOn(square)
            if door then
                local serves, why = servesGoal(door)
                local tileX, tileY = exteriorApproachTile(door)
                local state = BarteringAIUtils.doorStateFor(door)
                local doorX, doorY = math.floor(door:getX()), math.floor(door:getY())
                local own = cell:getGridSquare(doorX, doorY, goalZ)
                local across = cell:getGridSquare(door:getNorth() and doorX or (doorX - 1),
                    door:getNorth() and (doorY - 1) or doorY, goalZ)
                local function sideInfo(side)
                    return string.format("has=%s out=%s room=%s", tostring(side:has(IsoFlagType.exterior)),
                        tostring(side:isOutside()), tostring(side:getRoom() ~= nil))
                end
                notes[#notes + 1] = string.format("%d,%d%s %s %s tile=%s [%s] own{%s} across{%s}",
                    doorX, doorY, door:getNorth() and "N" or "W",
                    state, why, tileX and (tileX .. "," .. tileY) or "none", BarteringAIUtils.doorFlags(door),
                    sideInfo(own), sideInfo(across))
                if serves and tileX then
                    local ddx = door:getX() + 0.5 - zombie:getX()
                    local ddy = door:getY() + 0.5 - zombie:getY()
                    local score = ddx * ddx + ddy * ddy + (state == "blocked" and 1000000 or 0)
                    if not bestScore or score < bestScore then
                        bestDoor, bestX, bestY, bestState, bestScore = door, tileX, tileY, state, score
                    end
                end
            end
        end
    end

    local diag = table.concat(notes, " | ")
    if not bestDoor then
        return nil, nil, nil, "noDoor", diag
    end
    return bestDoor, bestX, bestY, bestState, diag
end

function BarteringAIUtils.findExteriorDoor(zombie, goalX, goalY, goalZ)
    local goalSquare = getCell():getGridSquare(goalX, goalY, goalZ)
    local goalBuilding = goalSquare and goalSquare:getBuilding()
    if not goalBuilding then
        return nil, nil, nil, "goalOutdoors", ""
    end
    local here = zombie:getSquare()
    if here and here:getBuilding() == goalBuilding then
        return nil, nil, nil, "alreadyInside", ""
    end
    return scanBuildingDoors(zombie, goalSquare, goalBuilding, goalZ, goalX, goalY)
end

function BarteringAIUtils.findExitDoor(zombie)
    local here = zombie:getSquare()
    local building = here:getBuilding()
    if not building then
        return nil, nil, nil, "outdoors", ""
    end
    return scanBuildingDoors(zombie, here, building, here:getZ(), here:getX(), here:getY())
end

function BarteringAIUtils.tryOpenNearbyDoor(entry, zombie)
    local zz = zombie:getZ()
    local goalX, goalY = BarteringAIUtils.getGoal(zombie)

    local blockedDoor = nil
    local blockedDoorDistance = nil

    local function routeDistance(object)
        local dx = object:getX() - zombie:getX()
        local dy = object:getY() - zombie:getY()
        local distance = dx * dx + dy * dy
        if goalX and goalY then
            local gx = goalX + 0.5 - zombie:getX()
            local gy = goalY + 0.5 - zombie:getY()
            local goalLength = math.sqrt(gx * gx + gy * gy)
            if goalLength > 0 then
                local routeAlignment = (dx * gx + dy * gy) / goalLength
                distance = distance + math.max(0, -routeAlignment) * 4
            end
        end
        return distance
    end

    local function noteBlocked(object)
        local distance = routeDistance(object)
        if not blockedDoorDistance or distance < blockedDoorDistance then
            blockedDoor = object
            blockedDoorDistance = distance
        end
    end

    local function openDoor(object, square, adjacent)
        local state = BarteringAIUtils.doorStateFor(object)
        if state == "blocked" and BarteringAIUtils.unlockDoorFromInside(zombie, object) then
            state = BarteringAIUtils.doorStateFor(object)
        end
        if state == "blocked" then
            if adjacent then
                noteBlocked(object)
            end
            return false
        end
        if state ~= "openable" then
            return false
        end

        BarteringAIUtils.openDoorObject(object)
        return true
    end

    local function scanDoorSquare(square, adjacent)
        if not square then
            return nil
        end

        local door = square:getIsoDoor()
        if door and isDoorObject(door) and openDoor(door, square, adjacent) then
            return "door"
        end

        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if isDoorObject(object) and openDoor(object, square, adjacent) then
                return "door"
            end
        end

        return nil
    end

    local zx = math.floor(zombie:getX())
    local zy = math.floor(zombie:getY())
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = getCell():getGridSquare(zx + dx, zy + dy, zz)
            if scanDoorSquare(square, true) then
                return "door", nil
            end
        end
    end

    if goalX and goalY then
        local routeX = goalX + 0.5 - zombie:getX()
        local routeY = goalY + 0.5 - zombie:getY()
        local routeDistance = math.sqrt(routeX * routeX + routeY * routeY)
        if routeDistance > 1 then
            routeX, routeY = routeX / routeDistance, routeY / routeDistance
            local steps = math.min(math.floor(routeDistance), ROUTE_DOOR_SCAN_TILES)
            for step = 1, steps do
                local centerX = math.floor(zombie:getX() + routeX * step)
                local centerY = math.floor(zombie:getY() + routeY * step)
                local sideX, sideY = -routeY, routeX
                for side = -1, 1 do
                    local square = getCell():getGridSquare(
                        math.floor(centerX + sideX * side),
                        math.floor(centerY + sideY * side), zz)
                    if scanDoorSquare(square, false) then
                        return "door", nil
                    end
                end
            end
        end
    end

    return nil, blockedDoor
end

return BarteringAIUtils
