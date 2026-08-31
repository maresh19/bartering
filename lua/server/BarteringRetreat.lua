local getCell = _G["getCell"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"

local BarteringRetreat = {}

local TUNE = {}
TUNE.PROGRESS_EPSILON_SQ = 0.0001
TUNE.MAX_REGION_SIZE = 12
TUNE.MIN_REGION_SIZE = 3
TUNE.SEARCH_RADIUS = 12
TUNE.MOVEMENT_SPEED = 1.00
TUNE.SCAN_MAX_RING = 8
TUNE.SCAN_RINGS_PER_TICK = 3
TUNE.PLAYER_AVOID_DISTANCE_SQ = 100
TUNE.SCAN_TARGET_DISTANCE = 10
TUNE.STALL_REPATH_TICKS = 20
TUNE.REPATH_COOLDOWN_TICKS = 12
TUNE.STALL_ABANDON_REPATHS = 3
TUNE.ARRIVED_DISTANCE_SQ = 25
TUNE.SAFE_DISTANCE = 5
TUNE.SAFE_DISTANCE_SQ = TUNE.SAFE_DISTANCE * TUNE.SAFE_DISTANCE
TUNE.CLEAR_DISTANCE = TUNE.SAFE_DISTANCE + 3
TUNE.CLEAR_DISTANCE_SQ = TUNE.CLEAR_DISTANCE * TUNE.CLEAR_DISTANCE
TUNE.TRIGGER_DISTANCE_SQ = BarteringAIUtils.MELEE_THREAT_DISTANCE_SQ
TUNE.MAX_TICKS = 300
TUNE.RETRY_COOLDOWN_TICKS = 30
TUNE.TRIGGER_ADJACENT = 2
TUNE.MELEE_TRIGGER_DISTANCE = BarteringAIUtils.MELEE_THREAT_DISTANCE
TUNE.LOG_INTERVAL_TICKS = 30

TUNE.DIRECTIONS = {
    { x = 1, y = 0 },
    { x = -1, y = 0 },
    { x = 0, y = 1 },
    { x = 0, y = -1 },
    { x = 0.7071, y = 0.7071 },
    { x = 0.7071, y = -0.7071 },
    { x = -0.7071, y = 0.7071 },
    { x = -0.7071, y = -0.7071 },
}

local function advanceRetreatScan(entry, zombie, maxRing)
    local scan = entry.retreatScan
    if not scan or scan.z ~= zombie:getZ() then
        scan = {
            originX = math.floor(zombie:getX()),
            originY = math.floor(zombie:getY()),
            z = zombie:getZ(),
            ring = 1,
            scores = {},
            blocked = {},
        }
        for i = 1, #TUNE.DIRECTIONS do
            scan.scores[i] = 0
            scan.blocked[i] = false
        end
        entry.retreatScan = scan
    end

    local ring = scan.ring
    local weight = (maxRing + 1) - ring

    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        local other = zombies:get(i)
        if other ~= zombie and not other:isDead() and not other:getVariableBoolean("Barterer")
            and other:getZ() == scan.z then
            local ox = math.floor(other:getX()) - scan.originX
            local oy = math.floor(other:getY()) - scan.originY
            if math.max(math.abs(ox), math.abs(oy)) == ring then
                local len = math.sqrt(ox * ox + oy * oy)
                if len > 0 then
                    local nx, ny = ox / len, oy / len
                    local bestDir, bestDot = nil, -math.huge
                    for d = 1, #TUNE.DIRECTIONS do
                        local dir = TUNE.DIRECTIONS[d]
                        local dot = nx * dir.x + ny * dir.y
                        if dot > bestDot then
                            bestDot = dot
                            bestDir = d
                        end
                    end
                    if bestDir then
                        scan.scores[bestDir] = scan.scores[bestDir] + weight
                    end
                end
            end
        end
    end

    for d = 1, #TUNE.DIRECTIONS do
        if not scan.blocked[d] then
            local dir = TUNE.DIRECTIONS[d]
            local tx = scan.originX + math.floor(dir.x * ring + 0.5)
            local ty = scan.originY + math.floor(dir.y * ring + 0.5)
            local square = getCell():getGridSquare(tx, ty, scan.z)
            if not square or not square:isFree(false) then
                scan.blocked[d] = true
            end
        end
    end

    scan.ring = ring + 1
    if scan.ring > maxRing then
        return scan
    end
    return nil
end

local function chooseRetreatTargetFromScan(scan, maxDistance, avoidX, avoidY, playerX, playerY)
    local function pointsAt(d, ax, ay)
        if not ax then
            return false
        end
        local dir = TUNE.DIRECTIONS[d]
        local dx = ax - scan.originX
        local dy = ay - scan.originY
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then
            return false
        end
        return ((dx / len) * dir.x + (dy / len) * dir.y) > 0.85
    end

    local function pointsAtAvoided(d)
        return pointsAt(d, avoidX, avoidY) or pointsAt(d, playerX, playerY)
    end

    local bestDir, bestScore
    for d = 1, #TUNE.DIRECTIONS do
        if not scan.blocked[d] and not pointsAtAvoided(d) and (not bestScore or scan.scores[d] < bestScore) then
            bestScore = scan.scores[d]
            bestDir = d
        end
    end

    if not bestDir then
        for d = 1, #TUNE.DIRECTIONS do
            if not bestScore or scan.scores[d] < bestScore then
                bestScore = scan.scores[d]
                bestDir = d
            end
        end
    end

    if not bestDir then
        return nil
    end

    local dir = TUNE.DIRECTIONS[bestDir]
    local targetX, targetY
    for step = 1, maxDistance do
        local tx = scan.originX + math.floor(dir.x * step + 0.5)
        local ty = scan.originY + math.floor(dir.y * step + 0.5)
        local square = getCell():getGridSquare(tx, ty, scan.z)
        if square and square:isFree(false) then
            targetX, targetY = tx, ty
        end
    end

    if not targetX then
        return nil
    end
    return targetX + 0.5, targetY + 0.5
end

local function findSafeRetreatCenter(zombie, maxSize, minSize, searchRadius)
    local zx = math.floor(zombie:getX())
    local zy = math.floor(zombie:getY())
    local z = zombie:getZ()

    local threatTiles = {}
    local zombies = getCell():getZombieList()
    local scanRadius = searchRadius + maxSize
    for i = 0, zombies:size() - 1 do
        local other = zombies:get(i)
        if other ~= zombie and not other:isDead() and not other:getVariableBoolean("Barterer") and other:getZ() == z then
            local ox = math.floor(other:getX())
            local oy = math.floor(other:getY())
            if math.abs(ox - zx) <= scanRadius and math.abs(oy - zy) <= scanRadius then
                threatTiles[#threatTiles + 1] = { x = ox, y = oy }
            end
        end
    end

    local function windowIsSafe(originX, originY, size)
        for _, tile in ipairs(threatTiles) do
            if tile.x >= originX and tile.x < originX + size and tile.y >= originY and tile.y < originY + size then
                return false
            end
        end
        return true
    end

    for size = maxSize, minSize, -1 do
        local half = math.floor(size / 2)
        for ring = 0, searchRadius do
            for dx = -ring, ring do
                for dy = -ring, ring do
                    if math.max(math.abs(dx), math.abs(dy)) == ring then
                        local centerX = zx + dx
                        local centerY = zy + dy
                        local centerSquare = getCell():getGridSquare(centerX, centerY, z)
                        if centerSquare and centerSquare:isFree(false)
                            and windowIsSafe(centerX - half, centerY - half, size) then
                            local farX, farY = centerX, centerY
                            local stepX = (centerX >= zx) and 1 or -1
                            local stepY = (centerY >= zy) and 1 or -1
                            for offset = 1, half do
                                local tx = centerX + stepX * offset
                                local ty = centerY + stepY * offset
                                local square = getCell():getGridSquare(tx, ty, z)
                                if square and square:isFree(false) then
                                    farX, farY = tx, ty
                                else
                                    break
                                end
                            end
                            return farX + 0.5, farY + 0.5
                        end
                    end
                end
            end
        end
    end

    return nil, nil
end

function BarteringRetreat.isSwarmed(meleeThreatCount)
    return meleeThreatCount >= TUNE.TRIGGER_ADJACENT
end

function BarteringRetreat.new(config)
    local countZombiesWithin = BarteringAIUtils.countZombiesWithin
    local clearGoal = BarteringAIUtils.clearGoal
    local publishGoal = BarteringAIUtils.publishGoal

    local function movementDiagnostics(entry, zombie, targetSq)
        local movedX = zombie:getX() - (entry.diagX or zombie:getX())
        local movedY = zombie:getY() - (entry.diagY or zombie:getY())
        entry.diagX, entry.diagY = zombie:getX(), zombie:getY()

        local _, playerSq = config.getClosestNearbyPlayer(zombie, 1000000)
        playerSq = playerSq or -1
        local targetDelta = targetSq - (entry.diagTargetSq or targetSq)
        local playerDelta = playerSq - (entry.diagPlayerSq or playerSq)
        entry.diagTargetSq = targetSq
        entry.diagPlayerSq = playerSq

        local moved = math.sqrt(movedX * movedX + movedY * movedY)
        local faceInfo = "face=none"
        if moved > 0.01 then
            local travel = math.deg(math.atan2(movedY, movedX))
            local facing = zombie:getDirectionAngle()
            local delta = facing - travel
            while delta > 180 do delta = delta - 360 end
            while delta < -180 do delta = delta + 360 end
            faceInfo = string.format("travel=%.0f facing=%.0f off=%.0f dir=%s",
                travel, facing, delta, tostring(zombie:getDir()))
        end

        return string.format(
            "moved=%.2f toTarget=%.1f(%+.1f) toPlayer=%.1f(%+.1f) %s %s",
            moved,
            targetSq, targetDelta,
            playerSq, playerDelta,
            faceInfo,
            tostring(entry.pathDiag))
    end

    local function clearRetreatTracking(entry)
        entry.retreatStallTicks = 0
        entry.retreatStallRepaths = 0
        entry.retreatRepathCooldown = 0
        entry.retreatLastX = nil
        entry.retreatLastY = nil
        entry.retreatScan = nil
        entry.retreatLogTicks = 0
        entry.retreatTicks = 0
    end

    local function finishRetreat(entry, zombie, reason)
        entry.retreatActive = false
        entry.retreatBlockedX = nil
        entry.retreatBlockedY = nil
        entry.retreatCooldown = TUNE.RETRY_COOLDOWN_TICKS
        clearRetreatTracking(entry)
        clearGoal(zombie, "retreat")
        zombie:setVariable("MovementSpeed", "1.00")
        config.logBartererServerDebug(zombie, "retreat finished: " .. reason, "Retreat")
        BarteringPathTrace.counter(zombie, "retreat.finish." .. reason:gsub(" ", "-"))
        return false
    end

    local function updateRetreat(entry, zombie)
        if countZombiesWithin(zombie, TUNE.CLEAR_DISTANCE_SQ) == 0 then
            return finishRetreat(entry, zombie, "clear of threats")
        end

        entry.retreatTicks = (entry.retreatTicks or 0) + 1
        if entry.retreatTicks >= TUNE.MAX_TICKS then
            return finishRetreat(entry, zombie, "max duration")
        end

        local retreatAction = zombie:getActionStateName()
        zombie:setPathing(true)
        zombie:setVariable("MovementSpeed", tostring(TUNE.MOVEMENT_SPEED))
        zombie:setVariable("BartererState", "Retreat")
        zombie:setWalkType("BartererSprint")
        zombie:setVariable("BartererWalkType", "BartererSprint")
        BarteringAIUtils.suppressZombieCombat(zombie)
        zombie:setVariable("NoLungeAttack", true)
        if retreatAction == "lunge" then
            zombie:setUseless(true)
            zombie:clearAggroList()
            zombie:setTarget(nil)
        end
        if retreatAction == "bumped" or retreatAction == "lunge" or retreatAction == "attack" or retreatAction == "face-target" then
            if retreatAction == "bumped" then
                zombie:setVariable("BumpAnimFinished", true)
            end
            zombie:setBumpType("")
        end

        if zombie:getZ() == entry.retreatTargetZ
            and BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), entry.retreatTargetX, entry.retreatTargetY) <= TUNE.ARRIVED_DISTANCE_SQ then
            return finishRetreat(entry, zombie, "reached target")
        end
        if (entry.retreatRepathCooldown or 0) > 0 then
            entry.retreatRepathCooldown = entry.retreatRepathCooldown - 1
        end

        local moveDx = zombie:getX() - (entry.retreatLastX or zombie:getX())
        local moveDy = zombie:getY() - (entry.retreatLastY or zombie:getY())
        if moveDx * moveDx + moveDy * moveDy <= TUNE.PROGRESS_EPSILON_SQ then
            entry.retreatStallTicks = (entry.retreatStallTicks or 0) + 1
        else
            entry.retreatStallTicks = 0
            entry.retreatStallRepaths = 0
        end
        entry.retreatLastX = zombie:getX()
        entry.retreatLastY = zombie:getY()

        if entry.retreatStallTicks >= TUNE.STALL_REPATH_TICKS
            and (entry.retreatRepathCooldown or 0) <= 0 then
            entry.retreatStallTicks = 0
            entry.retreatRepathCooldown = TUNE.REPATH_COOLDOWN_TICKS
            entry.retreatStallRepaths = (entry.retreatStallRepaths or 0) + 1

            if BarteringAIUtils.tryOpenNearbyDoor(zombie, true) then
                entry.retreatStallRepaths = 0
                entry.retreatRepathCooldown = 0
                config.logBartererServerDebug(zombie, "retreat opened nearby door", "Retreat")
                BarteringPathTrace.counter(zombie, "retreat.doorOpened")
                return true
            end

            if entry.retreatStallRepaths >= TUNE.STALL_ABANDON_REPATHS then
                finishRetreat(entry, zombie, "target abandoned after repeated stalls")
                entry.retreatBlockedX = entry.retreatTargetX
                entry.retreatBlockedY = entry.retreatTargetY
                return false
            else
                config.logBartererServerDebug(zombie, "retreat repath after stall", "Retreat")
                BarteringPathTrace.counter(zombie, "retreat.stallRepath")
            end
        end

        publishGoal(zombie, entry.retreatTargetX, entry.retreatTargetY, entry.retreatTargetZ, "retreat")
        entry.pathDiag = string.format("action=%s curState=%s",
            tostring(zombie:getActionStateName()),
            tostring(zombie:getCurrentStateName()))

        entry.retreatLogTicks = (entry.retreatLogTicks or 0) - 1
        if entry.retreatLogTicks <= 0 then
            entry.retreatLogTicks = TUNE.LOG_INTERVAL_TICKS
            local nearTrigger = entry.meleeInFront + entry.meleeBehind
            local nearSafe = countZombiesWithin(zombie, TUNE.SAFE_DISTANCE_SQ)
            config.logBartererServerDebug(zombie, string.format(
                "retreat tick %s stall=%d repaths=%d near%d=%d near%d=%d target=%.1f,%.1f",
                movementDiagnostics(entry, zombie,
                    BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(),
                        entry.retreatTargetX, entry.retreatTargetY)),
                entry.retreatStallTicks or 0,
                entry.retreatStallRepaths or 0,
                TUNE.MELEE_TRIGGER_DISTANCE,
                nearTrigger,
                TUNE.SAFE_DISTANCE,
                nearSafe,
                entry.retreatTargetX or -1, entry.retreatTargetY or -1), "Retreat")
        end

        return true
    end

    local function tryStartRetreat(entry, zombie)
        if entry.retreatActive then
            return
        end
        if (entry.retreatCooldown or 0) > 0 then
            entry.retreatCooldown = entry.retreatCooldown - 1
            return
        end

        if (entry.meleeInFront + entry.meleeBehind) <= 1
            and entry.meleeBehind == 0
            and not entry.retreatForced then
            return
        end

        local completedScan = nil
        for _ = 1, TUNE.SCAN_RINGS_PER_TICK do
            completedScan = advanceRetreatScan(entry, zombie, TUNE.SCAN_MAX_RING)
            if completedScan then
                break
            end
        end
        if not completedScan then
            return
        end
        entry.retreatScan = nil

        local avoidPlayer = config.getClosestNearbyPlayer(zombie, TUNE.PLAYER_AVOID_DISTANCE_SQ)
        local centerX, centerY = chooseRetreatTargetFromScan(completedScan, TUNE.SCAN_TARGET_DISTANCE,
            entry.retreatBlockedX, entry.retreatBlockedY,
            avoidPlayer and avoidPlayer:getX(), avoidPlayer and avoidPlayer:getY())
        if not centerX then
            centerX, centerY = findSafeRetreatCenter(
                zombie, TUNE.MAX_REGION_SIZE, TUNE.MIN_REGION_SIZE, TUNE.SEARCH_RADIUS)
        end
        if not centerX then
            entry.retreatCooldown = TUNE.RETRY_COOLDOWN_TICKS
            BarteringPathTrace.counter(zombie, "retreat.noTargetFound")
            return
        end

        clearGoal(zombie, "retreat")
        entry.retreatActive = true
        entry.retreatForced = false
        entry.retreatTargetX = centerX
        entry.retreatTargetY = centerY
        entry.retreatTargetZ = zombie:getZ()
        clearRetreatTracking(entry)
        config.logBartererServerDebug(zombie, "retreating from zombie crowd", "Retreat")
        BarteringPathTrace.counter(zombie, "retreat.started")
    end

    return {
        updateRetreat = updateRetreat,
        tryStartRetreat = tryStartRetreat,
        isSwarmed = BarteringRetreat.isSwarmed,
    }
end

return BarteringRetreat
