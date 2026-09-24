Bartering = Bartering or {}

local getCell = _G["getCell"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringPathTrace = require "BarteringPathTrace"
local BarteringDialogue = require "BarteringDialogue"
local BarteringIntercept = require "Movement/BarteringIntercept"

local BarteringApproach = {}

local TUNE = {}
TUNE.PLAYER_MEET_TILES = 2
TUNE.UNREACHABLE_GIVE_UP_ATTEMPTS = 3
TUNE.DOOR_REDIRECT_ENABLED = true
TUNE.LOCKED_DOOR_CHECK_DISTANCE_SQ = 20 * 20
TUNE.LOCKED_DOOR_STALL_TICKS = 180
TUNE.LOCKED_DOOR_WEDGE_TICKS = 45
TUNE.LOCKED_DOOR_STAGE_OFFSET = 8
TUNE.LOCKED_DOOR_STAGE_MIN_OFFSET = 4
TUNE.LOCKED_DOOR_STAGE_REACHED = 2.5
TUNE.THREAT_SPRINT_MOVEMENT_SPEED = 1.00
TUNE.APPROACH_TARGET_STALE_DISTANCE_SQ = 250 * 250
TUNE.APPROACH_ROUTE_STEP = 8
TUNE.APPROACH_ROUTE_REACH_SQ = 3 * 3

local clearGoal = BarteringAIUtils.clearGoal
local publishGoal = BarteringAIUtils.publishGoal
local publishExactGoal = BarteringAIUtils.publishExactGoal
local setVariableIfChanged = BarteringAIUtils.setVariableIfChanged

local function routeText(route)
    local text = ""
    for i = 1, #route do
        text = text .. string.format(" %d,%d", route[i].x, route[i].y)
    end
    return text
end

local function clearDoorProgress(entry)
    entry.lockedDoorBestDistance, entry.lockedDoorStallTicks = nil, nil
    entry.lockedDoorWedgeTicks = nil
end

local function clearDoorTarget(entry)
    entry.lockedDoorX, entry.lockedDoorY, entry.lockedDoorZ = nil, nil, nil
    entry.lockedDoor = nil
    entry.lockedDoorRoute, entry.lockedDoorRouteIndex = nil, nil
    clearDoorProgress(entry)
end

local function clearDoorThrough(entry)
    entry.lockedDoorThroughX, entry.lockedDoorThroughY = nil, nil
    entry.lockedDoorThroughDoor = nil
    clearDoorProgress(entry)
end

local function trackDoorProgress(entry, distance)
    if not entry.lockedDoorBestDistance or distance < entry.lockedDoorBestDistance - 0.5 then
        entry.lockedDoorBestDistance = distance
        entry.lockedDoorStallTicks = 0
    else
        entry.lockedDoorStallTicks = entry.lockedDoorStallTicks + 1
    end
    return entry.lockedDoorStallTicks
end

function BarteringApproach.new(deps, arriveLogic)
    local log = deps.logBartererServerDebug

    local function updateCrowding(entry, zombie)
        local hasApproachTarget = entry.approachTargetX ~= nil
            and entry.approachTargetY ~= nil
            and entry.approachTargetZ ~= nil
        local targetX = hasApproachTarget and entry.approachTargetX or (entry.master and entry.master:getX())
        local targetY = hasApproachTarget and entry.approachTargetY or (entry.master and entry.master:getY())
        local targetZ = hasApproachTarget and entry.approachTargetZ or (entry.master and entry.master:getZ())

        if targetX ~= nil then
            BarteringPathTrace.counter(zombie, "scan.approachCrowdList")
        end

        entry.approachCrowded = targetX ~= nil
            and BarteringAIUtils.hasZombiesAround(targetX, targetY, targetZ,
                BarteringAIUtils.APPROACH_CROWD_DISTANCE_SQ, BarteringAIUtils.APPROACH_CROWD_MIN)

        entry.withinApproachFightRange = false
        if targetX ~= nil then
            local dx = zombie:getX() - targetX
            local dy = zombie:getY() - targetY
            local dz = zombie:getZ() - targetZ
            entry.withinApproachFightRange = dx * dx + dy * dy + dz * dz <= BarteringAIUtils.APPROACH_FIGHT_RADIUS_SQ
        end
    end

    local function applyState(entry, zombie)
        local movementSpeed = entry.threatNearby and TUNE.THREAT_SPRINT_MOVEMENT_SPEED or 1.00
        setVariableIfChanged(zombie, "MovementSpeed", tostring(movementSpeed))
        setVariableIfChanged(zombie, "BartererState", "Approach")
    end

    local function neutralize(entry, zombie)
        local hostile, reset = deps.neutralizeHostileAction(entry, zombie)
        if hostile and (entry.hostileTicks == 1 or reset) then
            log(zombie, "approach hostile-state neutralized", "Approach")
        end
    end

    local function getTarget(entry, zombie, master)
        local hasApproachTarget = entry.approachTargetX ~= nil and entry.approachTargetY ~= nil
        if hasApproachTarget and not entry.intercepted then
            local staleX = master:getX() - entry.approachTargetX
            local staleY = master:getY() - entry.approachTargetY
            if staleX * staleX + staleY * staleY > TUNE.APPROACH_TARGET_STALE_DISTANCE_SQ then
                log(zombie, string.format(
                    "approach target %.0f,%.0f is stale; falling back to master",
                    entry.approachTargetX, entry.approachTargetY), "Approach")
                entry.approachTargetX, entry.approachTargetY, entry.approachTargetZ = nil, nil, nil
                hasApproachTarget = false
            end
        end

        local targetX = hasApproachTarget and entry.approachTargetX or master:getX()
        local targetY = hasApproachTarget and entry.approachTargetY or master:getY()
        local targetZ = hasApproachTarget and entry.approachTargetZ or master:getZ()

        return targetX, targetY, targetZ, hasApproachTarget
    end

    local function latchDoor(entry, zombie, goalX, goalY, goalZ, counterName, logPrefix)
        local door, tileX, tileY, doorState, doorNotes = BarteringAIUtils.findExteriorDoor(zombie, goalX, goalY, goalZ)
        log(zombie, "door candidates: " .. doorNotes, "Approach")
        if not door then
            BarteringPathTrace.counter(zombie, "approach.noDoorRedirect." .. doorState)
            log(zombie, "no door redirect: " .. doorState, "Approach")
            return false
        end
        entry.lockedDoorX, entry.lockedDoorY, entry.lockedDoorZ = tileX, tileY, goalZ
        entry.lockedDoor = door
        BarteringPathTrace.counter(zombie, counterName)
        log(zombie, string.format(
            "%s %s door %d,%d; heading there via %d,%d", logPrefix, doorState,
            math.floor(door:getX()), math.floor(door:getY()), tileX, tileY), "Approach")

        if BarteringAIUtils.segmentCrossesDoorBuilding(door, goalZ,
            zombie:getX(), zombie:getY(), tileX + 0.5, tileY + 0.5) then
            local route, routeInfo = BarteringAIUtils.doorApproachRoute(door, goalZ, zombie:getX(), zombie:getY())
            log(zombie, "straight line to the door crosses the building; route check: " .. routeInfo, "Approach")
            if route then
                entry.lockedDoorRoute, entry.lockedDoorRouteIndex = route, 1
                entry.lockedDoorStageTried = true
                BarteringPathTrace.counter(zombie, "lockedDoor.routeUpfront")
                log(zombie, "walking around the building via" .. routeText(route), "Approach")
            end
        end
        return true
    end

    local function reportUnreachableGoal(entry, zombie)
        entry.unreachableAttempts = 0
        local goalX, goalY = BarteringAIUtils.getGoal(zombie)

        if entry.intercepted then
            BarteringPathTrace.counter(zombie, "stuck.goalUnreachable.intercepted")
            log(zombie, string.format("cannot reach %s,%s while intercepted; retrying",
                tostring(goalX), tostring(goalY)), "Approach")
            return
        end

        if TUNE.DOOR_REDIRECT_ENABLED and goalX and goalY and not entry.lockedDoorGaveUp
            and latchDoor(entry, zombie, math.floor(goalX), math.floor(goalY), zombie:getZ(),
                "stuck.lockedDoorFound", "cannot get in; walking to") then
            return
        end

        entry.unreachableGoalX, entry.unreachableGoalY = goalX, goalY
        entry.blockedKind = "BlockedRoute"

        BarteringAIUtils.playScriptedBump(entry, zombie, "Blocked")
        local goalSquare = goalX and getCell():getGridSquare(math.floor(goalX), math.floor(goalY), zombie:getZ())
        BarteringAIUtils.sayBarterer(entry.bartererId, (goalSquare and goalSquare:getBuilding())
            and BarteringDialogue.Movement.noRouteIn or BarteringDialogue.Movement.noRoute)

        BarteringPathTrace.counter(zombie, "stuck.goalUnreachable")
        log(zombie, string.format(
            "cannot reach %s,%s; holding until the way opens",
            tostring(entry.unreachableGoalX), tostring(entry.unreachableGoalY)), "Blocked")
    end

    local function giveUpOnDoor(entry, zombie)
        clearDoorTarget(entry)
        entry.lockedDoorGaveUp = true
        local opened, blocked = deps.openNearbyDoor(entry, zombie)
        if opened then
            BarteringPathTrace.counter(zombie, "lockedDoor.gaveUpOpenedAdjacent")
            log(zombie, "gave up on the door but opened the one beside me; going through", "Approach")
            entry.stillTicks = 0
            entry.stuckSample = false
            entry.unreachableAttempts = 0
            BarteringPathTrace.aiStop(zombie, "move.approach.gaveUpOpenedDoor")
            return
        end
        if blocked then
            BarteringPathTrace.counter(zombie, "lockedDoor.gaveUpLockedAdjacent")
            log(zombie, string.format(
                "gave up on the door; the one beside me at %.0f,%.0f is locked",
                blocked:getX(), blocked:getY()), "Blocked")
            deps.reportDoorLocked(entry, zombie, blocked)
            BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorReached")
            return
        end
        reportUnreachableGoal(entry, zombie)
        deps.applyBlockedState(entry, zombie)
        BarteringPathTrace.aiStop(zombie, "move.approach.doorUnreachable")
    end

    local function routeAroundWindow(entry, zombie)
        local window, building = BarteringAIUtils.windowBuildingNear(zombie)
        if not window or entry.aroundBuilding == building then
            return false
        end
        entry.aroundBuilding = building
        local goalX, goalY = BarteringAIUtils.getGoal(zombie)
        local def = building:getDef()
        local route, routeInfo = BarteringAIUtils.buildingRoute(def:getX(), def:getY(), def:getX2(), def:getY2(),
            zombie:getX(), zombie:getY(), goalX, goalY)
        log(zombie, string.format("stuck at window %.0f,%.0f; route check: %s",
            window:getX(), window:getY(), routeInfo), "Approach")
        if not route then
            return false
        end
        entry.aroundRoute, entry.aroundRouteIndex = route, 1
        entry.aroundBest, entry.aroundStall = nil, nil
        BarteringPathTrace.counter(zombie, "approach.windowRouteAround")
        log(zombie, "walking around the building via" .. routeText(route), "Approach")
        return true
    end

    local function followAroundRoute(entry, zombie)
        local waypoint = entry.aroundRoute[entry.aroundRouteIndex]
        local wdx = waypoint.x + 0.5 - zombie:getX()
        local wdy = waypoint.y + 0.5 - zombie:getY()
        local distance = math.sqrt(wdx * wdx + wdy * wdy)

        if distance <= TUNE.LOCKED_DOOR_STAGE_REACHED then
            entry.aroundRouteIndex = entry.aroundRouteIndex + 1
            entry.aroundBest, entry.aroundStall = nil, nil
            if entry.aroundRouteIndex > #entry.aroundRoute then
                log(zombie, string.format("cleared the building at %d,%d; heading on", waypoint.x, waypoint.y), "Approach")
                entry.aroundRoute, entry.aroundRouteIndex = nil, nil
            end
            BarteringPathTrace.aiStop(zombie, "move.approach.aroundReached")
            return
        end

        if not entry.aroundBest or distance < entry.aroundBest - 0.5 then
            entry.aroundBest, entry.aroundStall = distance, 0
        else
            entry.aroundStall = entry.aroundStall + 1
        end
        if entry.aroundStall >= TUNE.LOCKED_DOOR_STALL_TICKS then
            log(zombie, string.format("cannot reach waypoint %d,%d; dropping the route", waypoint.x, waypoint.y), "Approach")
            BarteringPathTrace.counter(zombie, "approach.aroundStalled")
            entry.aroundRoute, entry.aroundRouteIndex = nil, nil
            entry.aroundBest, entry.aroundStall = nil, nil
            return
        end

        publishGoal(zombie, waypoint.x + 0.5, waypoint.y + 0.5, zombie:getZ(), "approach.around")
        BarteringPathTrace.aiStop(zombie, "move.approach.around")
    end

    local function handleStuck(entry, zombie)
        if not entry.stuckSample then
            entry.unreachableAttempts = 0
            return
        end

        local attempted, opened, blocked = deps.tryDoorsIfStuck(entry, zombie)
        if not attempted then
            return
        end

        if opened then
            entry.unreachableAttempts = 0
        elseif blocked then
            entry.unreachableAttempts = 0
            deps.reportBlockedOpenable(entry, zombie, blocked)
        elseif routeAroundWindow(entry, zombie) then
            entry.unreachableAttempts = 0
        else
            local goalX, goalY = BarteringAIUtils.getGoal(zombie)
            log(zombie, string.format("stuck with no door found; attempt %d/%d goal=%s,%s action=%s",
                (entry.unreachableAttempts or 0) + 1, TUNE.UNREACHABLE_GIVE_UP_ATTEMPTS,
                tostring(goalX), tostring(goalY),
                tostring(zombie:getActionStateName())), "Approach")
            BarteringPathTrace.counter(zombie, "stuck.noDoorFound")
            if (entry.unreachableAttempts or 0) >= TUNE.UNREACHABLE_GIVE_UP_ATTEMPTS then
                reportUnreachableGoal(entry, zombie)
            else
                entry.unreachableAttempts = (entry.unreachableAttempts or 0) + 1
            end
        end
    end

    local function followRoute(entry, zombie)
        local route = entry.approachRoute
        if not route then
            return false
        end

        local x, y = Bartering.RoadRoute.positionAt(route, entry.approachAlong / route.total)
        while entry.approachAlong < route.total
            and BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), x, y) <= TUNE.APPROACH_ROUTE_REACH_SQ do
            entry.approachAlong = math.min(route.total, entry.approachAlong + TUNE.APPROACH_ROUTE_STEP)
            x, y = Bartering.RoadRoute.positionAt(route, entry.approachAlong / route.total)
        end

        if entry.approachAlong >= route.total then
            log(zombie, "reached the end of the meetup route; heading straight to the target", "Approach")
            entry.approachRoute = nil
            entry.approachAlong = nil
            return false
        end

        publishGoal(zombie, x, y, 0, "approach.route")
        return true
    end

    local function meetPlayerIfClose(entry, zombie)
        local master = entry.master
        if entry.homeResident or entry.intercepted or not master or master:isDead()
            or zombie:getVariableBoolean("BartererClimbing")
            or zombie:getActionStateName() == "climbfence" or zombie:getActionStateName() == "climbwindow" then
            return false
        end

        if BarteringAIUtils.squareWithinWalk(zombie:getSquare(), master:getSquare(), TUNE.PLAYER_MEET_TILES) then
            arriveLogic.meetPlayer(entry, zombie, master)
            return true
        end
        return false
    end

    local function checkDoorAhead(entry, zombie)
        if not TUNE.DOOR_REDIRECT_ENABLED or entry.lockedDoorChecked or entry.lockedDoorGaveUp
            or not entry.approachTargetX or not entry.approachTargetY or not entry.approachTargetZ then
            return
        end
        local adx = entry.approachTargetX + 0.5 - zombie:getX()
        local ady = entry.approachTargetY + 0.5 - zombie:getY()
        if (adx * adx + ady * ady) <= TUNE.LOCKED_DOOR_CHECK_DISTANCE_SQ then
            entry.lockedDoorChecked = true
            latchDoor(entry, zombie, entry.approachTargetX, entry.approachTargetY, entry.approachTargetZ,
                "approach.lockedDoorAhead", "call location's way in is")
        end
    end

    local function stepThroughDoor(entry, zombie)
        local door = entry.lockedDoorThroughDoor
        local doorState = BarteringAIUtils.doorStateFor(door)
        if math.floor(zombie:getX()) == entry.lockedDoorThroughX
            and math.floor(zombie:getY()) == entry.lockedDoorThroughY then
            BarteringPathTrace.counter(zombie, "lockedDoor.through")
            log(zombie, string.format(
                "through door %d,%d; heading for the call location",
                math.floor(door:getX()), math.floor(door:getY())), "Approach")
            clearDoorThrough(entry)
            entry.approachRoute = nil
            entry.approachAlong = nil
            return false
        end

        if doorState == "blocked" then
            clearDoorThrough(entry)
            deps.reportDoorLocked(entry, zombie, door)
            BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorReached")
            return true
        end

        if doorState == "openable" then
            BarteringPathTrace.counter(zombie, "lockedDoor.reopened")
            BarteringAIUtils.openDoorObject(door)
        end
        local tdx = entry.lockedDoorThroughX + 0.5 - zombie:getX()
        local tdy = entry.lockedDoorThroughY + 0.5 - zombie:getY()
        if trackDoorProgress(entry, math.sqrt(tdx * tdx + tdy * tdy)) >= TUNE.LOCKED_DOOR_STALL_TICKS then
            BarteringPathTrace.counter(zombie, "lockedDoor.throughStalled")
            log(zombie, string.format(
                "could not step through door %d,%d to %d,%d; continuing on my own",
                math.floor(door:getX()), math.floor(door:getY()),
                entry.lockedDoorThroughX, entry.lockedDoorThroughY), "Approach")
            clearDoorThrough(entry)
            return false
        end

        publishExactGoal(zombie, entry.lockedDoorThroughX + 0.5, entry.lockedDoorThroughY + 0.5,
            zombie:getZ(), "approach.lockedDoorThrough")
        BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorThrough")
        return true
    end

    local function followDoorRoute(entry, zombie)
        local waypoint = entry.lockedDoorRoute[entry.lockedDoorRouteIndex]
        local sdx = waypoint.x + 0.5 - zombie:getX()
        local sdy = waypoint.y + 0.5 - zombie:getY()
        local stageDistance = math.sqrt(sdx * sdx + sdy * sdy)

        if stageDistance <= TUNE.LOCKED_DOOR_STAGE_REACHED then
            entry.lockedDoorRouteIndex = entry.lockedDoorRouteIndex + 1
            if entry.lockedDoorRouteIndex > #entry.lockedDoorRoute then
                log(zombie, string.format(
                    "cleared the building at %d,%d; heading for the door now",
                    waypoint.x, waypoint.y), "Approach")
                entry.lockedDoorRoute, entry.lockedDoorRouteIndex = nil, nil
            else
                local nextPoint = entry.lockedDoorRoute[entry.lockedDoorRouteIndex]
                log(zombie, string.format(
                    "reached waypoint %d,%d; next waypoint %d,%d",
                    waypoint.x, waypoint.y, nextPoint.x, nextPoint.y), "Approach")
            end
            clearDoorProgress(entry)
            BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorStageReached")
            return
        end

        if trackDoorProgress(entry, stageDistance) >= TUNE.LOCKED_DOOR_STALL_TICKS then
            log(zombie, string.format(
                "cannot reach waypoint %d,%d either; giving up on the door",
                waypoint.x, waypoint.y), "Blocked")
            BarteringPathTrace.counter(zombie, "lockedDoor.stageUnreachable")
            giveUpOnDoor(entry, zombie)
            return
        end

        publishGoal(zombie, waypoint.x + 0.5, waypoint.y + 0.5,
            entry.lockedDoorZ, "approach.lockedDoorStage")
        BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorStage")
    end

    local function reachDoorstep(entry, zombie)
        local reached = entry.lockedDoor
        clearDoorTarget(entry)

        local reachedState = BarteringAIUtils.doorStateFor(reached)
        if reachedState == "blocked" then
            deps.reportDoorLocked(entry, zombie, reached)
            BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorReached")
            return
        end

        if reachedState == "openable" then
            BarteringPathTrace.counter(zombie, "lockedDoor.openedOnArrival")
            log(zombie, string.format(
                "reached shut door %d,%d and it is not locked; opening it",
                math.floor(reached:getX()), math.floor(reached:getY())), "Approach")
            BarteringAIUtils.openDoorObject(reached)
        else
            BarteringPathTrace.counter(zombie, "lockedDoor.openOnArrival")
            log(zombie, string.format(
                "reached open door %d,%d", math.floor(reached:getX()), math.floor(reached:getY())),
                "Approach")
        end

        local insideX, insideY = BarteringAIUtils.doorInteriorTile(reached, zombie:getZ())
        entry.lockedDoorThroughX, entry.lockedDoorThroughY = insideX, insideY
        entry.lockedDoorThroughDoor = reached
        log(zombie, string.format("stepping through to %d,%d", insideX, insideY), "Approach")
        BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorThrough")
    end

    local function walkToDoor(entry, zombie)
        if entry.lockedDoorRoute then
            followDoorRoute(entry, zombie)
            return
        end

        if math.floor(zombie:getX()) == entry.lockedDoorX
            and math.floor(zombie:getY()) == entry.lockedDoorY then
            reachDoorstep(entry, zombie)
            return
        end

        local dx = entry.lockedDoorX + 0.5 - zombie:getX()
        local dy = entry.lockedDoorY + 0.5 - zombie:getY()
        local distance = math.sqrt(dx * dx + dy * dy)
        local stallTicks = trackDoorProgress(entry, distance)
        if stallTicks == 0 then
            entry.lockedDoorWedgeTicks = 0
        elseif zombie:isCollidedThisFrame() then
            entry.lockedDoorWedgeTicks = (entry.lockedDoorWedgeTicks or 0) + 1
        end

        local wedged = (entry.lockedDoorWedgeTicks or 0) >= TUNE.LOCKED_DOOR_WEDGE_TICKS
        if (wedged or stallTicks >= TUNE.LOCKED_DOOR_STALL_TICKS) and not entry.lockedDoorStageTried then
            entry.lockedDoorStageTried = true
            local route, routeInfo = BarteringAIUtils.doorApproachRoute(
                entry.lockedDoor, entry.lockedDoorZ, zombie:getX(), zombie:getY())
            log(zombie, string.format(
                "door %d,%d route check: %s", entry.lockedDoorX, entry.lockedDoorY, routeInfo), "Approach")
            if route then
                BarteringPathTrace.counter(zombie, wedged and "lockedDoor.routeRetryWedged" or "lockedDoor.routeRetry")
                log(zombie, string.format(
                    "cannot reach door tile %d,%d directly; walking around via%s",
                    entry.lockedDoorX, entry.lockedDoorY, routeText(route)), "Approach")
            else
                local stageX, stageY, stepX, stepY = BarteringAIUtils.doorStagingTile(
                    entry.lockedDoor, entry.lockedDoorZ, TUNE.LOCKED_DOOR_STAGE_OFFSET,
                    TUNE.LOCKED_DOOR_STAGE_MIN_OFFSET)
                if stageX then
                    route = { { x = stageX, y = stageY } }
                    BarteringPathTrace.counter(zombie, "lockedDoor.stageRetry")
                    log(zombie, string.format(
                        "cannot reach door tile %d,%d directly and no way around it; staging at %d,%d (outward %d,%d)",
                        entry.lockedDoorX, entry.lockedDoorY, stageX, stageY, stepX, stepY), "Approach")
                end
            end
            if route then
                entry.lockedDoorRoute, entry.lockedDoorRouteIndex = route, 1
                clearDoorProgress(entry)
                publishGoal(zombie, route[1].x + 0.5, route[1].y + 0.5,
                    entry.lockedDoorZ, "approach.lockedDoorStage")
                BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoorStage")
                return
            end
            BarteringPathTrace.counter(zombie, "lockedDoor.noStageTile")
            log(zombie, string.format(
                "no way around to door %d,%d from %.0f,%.0f",
                math.floor(entry.lockedDoor:getX()), math.floor(entry.lockedDoor:getY()),
                zombie:getX(), zombie:getY()), "Approach")
        end

        if stallTicks >= TUNE.LOCKED_DOOR_STALL_TICKS then
            log(zombie, string.format(
                "cannot reach door tile %d,%d from %.2f tiles away; giving up on it",
                entry.lockedDoorX, entry.lockedDoorY, distance), "Blocked")
            BarteringPathTrace.counter(zombie, "lockedDoor.unreachable")
            giveUpOnDoor(entry, zombie)
            return
        end

        publishExactGoal(zombie, entry.lockedDoorX + 0.5, entry.lockedDoorY + 0.5,
            entry.lockedDoorZ, "approach.lockedDoor")
        BarteringPathTrace.aiStop(zombie, "move.approach.lockedDoor")
    end

    local function holdIfUnreachable(entry, zombie)
        local goalX, goalY = BarteringAIUtils.getGoal(zombie)
        if goalX ~= entry.unreachableGoalX or goalY ~= entry.unreachableGoalY then
            log(zombie, "goal changed; retrying route", "Blocked")
            entry.unreachableGoalX, entry.unreachableGoalY = nil, nil
            deps.clearBlockedHold(entry)
            return false
        end

        deps.holdBlocked(entry, zombie, "unreachable.cancelledMove")
        BarteringPathTrace.aiStop(zombie, "move.waiting.goalUnreachable")
        return true
    end

    local function updateBlockers(entry, zombie)
        if meetPlayerIfClose(entry, zombie) then
            return true
        end

        checkDoorAhead(entry, zombie)

        if entry.lockedDoorThroughX and stepThroughDoor(entry, zombie) then
            return true
        end

        if entry.lockedDoorX then
            walkToDoor(entry, zombie)
            return true
        end

        if entry.aroundRoute then
            followAroundRoute(entry, zombie)
            return true
        end

        return entry.unreachableGoalX ~= nil and holdIfUnreachable(entry, zombie)
    end

    local function update(entry, zombie)
        local master = entry.master
        if not master or master:isDead() then
            clearGoal(zombie, "waiting")
            deps.applyWaitingState(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.waiting.noMaster")
            return
        end

        if BarteringIntercept.isMeeting(entry) then
            local callerX, callerY = BarteringIntercept.getMeetTarget(entry, master)

            if BarteringIntercept.isAtMeetDistance(zombie, callerX, callerY) then
                clearGoal(zombie, "interceptMeet")
                deps.applyWaitingState(entry, zombie)
                zombie:faceLocationF(callerX, callerY)
                BarteringPathTrace.aiStop(zombie, "move.waiting.interceptMeet")
                return
            end

            applyState(entry, zombie)
            neutralize(entry, zombie)
            publishGoal(zombie, callerX, callerY, zombie:getZ(), "interceptMeet")
            handleStuck(entry, zombie)
            BarteringPathTrace.aiStop(zombie, "move.approach.interceptMeet")
            return
        end

        applyState(entry, zombie)

        local targetX, targetY, targetZ, hasApproachTarget = getTarget(entry, zombie, master)
        if master and not master:isDead() and zombie:getZ() == master:getZ()
            and BarteringAIUtils.distanceSqBetween(master, zombie) <= TUNE.PLAYER_MEET_TILES * TUNE.PLAYER_MEET_TILES
            and not BarteringAIUtils.squareWithinWalk(zombie:getSquare(), master:getSquare(), TUNE.PLAYER_MEET_TILES) then
            targetX, targetY, targetZ, hasApproachTarget = master:getX(), master:getY(), master:getZ(), false
        end
        if arriveLogic.update(entry, zombie, targetX, targetY, targetZ, hasApproachTarget) then
            return
        end

        neutralize(entry, zombie)
        if followRoute(entry, zombie) then
            return
        end

        publishGoal(zombie,
            hasApproachTarget and (targetX + 0.5) or targetX,
            hasApproachTarget and (targetY + 0.5) or targetY,
            targetZ,
            hasApproachTarget and "approach.callTarget" or "approach.master")
        handleStuck(entry, zombie)
        BarteringPathTrace.aiStop(zombie, "move.approach.goal")
    end

    return {
        updateBlockers = updateBlockers,
        update = update,
        updateCrowding = updateCrowding,
    }
end

return BarteringApproach
