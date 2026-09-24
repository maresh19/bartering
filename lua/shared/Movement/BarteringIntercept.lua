local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local BarteringDialogue = require "BarteringDialogue"
local print = require("BarteringPathTrace").log

local BarteringIntercept = {}

BarteringIntercept.RADIUS_SQ = 30 * 30
BarteringIntercept.MEET_DISTANCE_SQ = 3 * 3

local UNSAFE_LATCH_MS = 15000
local MEET_TIMEOUT_MS = 13000
local DIALOG_GRACE_MS = 4000
local LOST_SIGHT_GRACE_MS = 5000

function BarteringIntercept.nearestAlongRoute(route, x, y)
    local points, lengths = route.points, route.lengths
    local best, bestDist = 0, math.huge
    local sx, sy = points[1].x, points[1].y
    for i = 2, #points do
        local ex, ey = points[i].x, points[i].y
        local dx, dy = ex - sx, ey - sy
        local spanSq = dx * dx + dy * dy
        local t = spanSq > 0 and ((x - sx) * dx + (y - sy) * dy) / spanSq or 0
        t = math.max(0, math.min(1, t))
        local px, py = sx + t * dx, sy + t * dy
        local ox, oy = x - px, y - py
        local d = ox * ox + oy * oy
        if d < bestDist then
            bestDist = d
            best = lengths[i - 1] + t * (lengths[i] - lengths[i - 1])
        end
        sx, sy = ex, ey
    end
    return best
end

local SCAN_RADIUS_SQ = 20 * 20
local MAX_ZOMBIES = 30
local AGGRO_LIMIT = 3

function BarteringIntercept.getRefusal(player, zombie)
    local px, py, level = player:getX(), player:getY(), math.floor(player:getZ())
    local nearPlayer, targetingPlayer, targetingZombie = 0, 0, 0
    BarteringAIUtils.forEachZombie(function(other)
        if math.floor(other:getZ()) == level
            and BarteringAIUtils.distanceSq(other:getX(), other:getY(), px, py) <= SCAN_RADIUS_SQ then
            nearPlayer = nearPlayer + 1
        end
        if not other:isDead() and not BarteringAIUtils.isBartererZombie(other) then
            local target = other:getTarget()
            if target == player and BarteringAIUtils.distanceSqBetween(other, player) <= SCAN_RADIUS_SQ then
                targetingPlayer = targetingPlayer + 1
            elseif target == zombie and BarteringAIUtils.distanceSqBetween(other, zombie) <= SCAN_RADIUS_SQ then
                targetingZombie = targetingZombie + 1
            end
        end
    end)

    if nearPlayer > MAX_ZOMBIES then
        return BarteringDialogue.Intercept.tooCrowded
    end

    if targetingPlayer > AGGRO_LIMIT or targetingZombie > AGGRO_LIMIT then
        return BarteringDialogue.Intercept.tooManyAggroed
    end

    return nil
end

function BarteringIntercept.isInterceptedBy(zombie, player)
    return zombie:getVariableBoolean("BartererIntercepted")
        and zombie:getVariableString("BartererMasterName") == player:getUsername()
end

function BarteringIntercept.findPlayerNear(x, y)
    return BarteringAIUtils.findPlayer(function(player)
        return BarteringAIUtils.distanceSq(player:getX(), player:getY(), x, y) <= BarteringIntercept.RADIUS_SQ
    end)
end

function BarteringIntercept.isMeeting(entry)
    return entry.interceptMeet == true
        and not entry.returningAfterMeeting
        and not entry.hasArrived
end

function BarteringIntercept.getMeetTarget(entry, master)
    return master:getX(), master:getY()
end

function BarteringIntercept.isAtMeetDistance(zombie, x, y)
    return BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), x, y) <= BarteringIntercept.MEET_DISTANCE_SQ
end

function BarteringIntercept.new(config)
    local state = config.state

    local function setMeeting(record, meeting)
        local ignoreCombat = not meeting
        if record.interceptMeet == meeting and record.ignoreCombat == ignoreCombat then
            return
        end
        record.interceptMeet = meeting
        record.ignoreCombat = ignoreCombat
        Bartering.bumpLiveRev(record)
    end

    local function resumeToMeetup(record, call)
        record.interceptMeet = false
        record.ignoreCombat = true
        record.approachTargetX = call.targetX
        record.approachTargetY = call.targetY
        record.approachTargetZ = call.targetZ
        record.returningToPost = false
        record.hasArrived = false
        record.continuingTrip = true
        local route = Bartering.RoadRoute.ensure(call)
        if route.status == "ready" and route.total > 0 then
            record.routeStartX, record.routeStartY = call.startX, call.startY
            record.routeTargetX, record.routeTargetY = call.targetX, call.targetY
            record.routeStandoff = call.standoff
        else
            record.routeStartX, record.routeStartY, record.routeTargetX, record.routeTargetY = nil, nil, nil, nil
            record.routeStandoff = nil
        end
        Bartering.bumpLiveRev(record)
    end

    local function begin(bartererId, call, x, y)
        local routeTrip = call.route and call.route.status == "ready" and call or nil
        local record = config.spawnBarterer(call.player, call.barterer,
            math.floor(x), math.floor(y), 0, false, nil,
            call.targetX, call.targetY, call.targetZ, routeTrip)
        if not record then
            return
        end
        record.intercepted = true
        record.ignoreCombat = true
        Bartering.bumpLiveRev(record)

        call.intercepted = true
        config.setBartererETA(call.player, bartererId, 0, true)
        print(string.format("[Bartering][Intercept] barterer %s intercepted en route at %.0f,%.0f",
            tostring(bartererId), x, y))
    end

    local function clearInterception(bartererId, record)
        local st = config.serverStateFor(bartererId)
        st.interceptWaitTickMs = nil
        st.interceptWaitedMs = nil
        if not record.intercepted and not record.interceptMeet and not record.ignoreCombat then
            return
        end
        record.intercepted = false
        record.ignoreCombat = false
        record.interceptMeet = false
        Bartering.bumpLiveRev(record)
    end

    local function updateMeetTimeout(bartererId, record, zombie, call, now)
        local st = config.serverStateFor(bartererId)
        if not record.interceptMeet or record.state ~= "Waiting" then
            st.interceptWaitTickMs = nil
            st.interceptWaitedMs = nil
            return
        end

        local previous = st.interceptWaitTickMs
        st.interceptWaitTickMs = now

        local dialogOpen = not BarteringTiming.hasElapsed(st.interceptDialogAtMs, DIALOG_GRACE_MS)
        if previous and not dialogOpen then
            st.interceptWaitedMs = (st.interceptWaitedMs or 0) + BarteringTiming.accumulate(previous, now)
        end

        if (st.interceptWaitedMs or 0) >= MEET_TIMEOUT_MS then
            call.interceptDeclined = true
            resumeToMeetup(record, call)
            config.setBartererETA(call.player, bartererId, call.arrivalAtMs, true,
                zombie:getX(), zombie:getY(), call.targetX, call.targetY, BarteringTiming.now())
            BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Intercept.timedOut)
            print(string.format(
                "[Bartering][Intercept] barterer %s meetup timed out; continuing to %d,%d | pos=%.1f,%.1f",
                tostring(bartererId), call.targetX, call.targetY, zombie:getX(), zombie:getY()))
        end
    end

    local function update(bartererId, call, now)
        local record = Bartering.getLiveRecord(bartererId)
        local zombie = state.serverZombies[bartererId]
        if not record or record.unloaded or not zombie then
            return "consumed"
        end

        if record.hasArrived or record.returningAfterMeeting
            or BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(),
                call.targetX, call.targetY) <= BarteringIntercept.RADIUS_SQ then
            clearInterception(bartererId, record)
            config.setBartererETA(call.player, bartererId, 0, true)
            return "consumed"
        end

        local st = config.serverStateFor(bartererId)
        local nearCaller =
            BarteringAIUtils.distanceSqBetween(call.player, zombie) <= BarteringIntercept.RADIUS_SQ

        if not nearCaller then
            call.interceptDeclined = false
            call.interceptUnsafeUntilMs = nil
            setMeeting(record, false)

        elseif call.interceptDeclined then
            setMeeting(record, false)

        else
            local refusal = BarteringIntercept.getRefusal(call.player, zombie)
            if refusal then
                call.interceptUnsafeUntilMs = now + UNSAFE_LATCH_MS
            end

            if call.interceptUnsafeUntilMs and now < call.interceptUnsafeUntilMs then
                setMeeting(record, false)
                if st.interceptStatus ~= "unsafe" then
                    BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Intercept.unsafe)
                    print(string.format(
                        "[Bartering][Intercept] barterer %s refusing to stop; area unsafe (%s), running for the meetup | zombiesNearPlayer=%d targetingPlayer=%d targetingBarterer=%d",
                        tostring(bartererId), tostring(refusal),
                        BarteringAIUtils.countZombiesNear(call.player:getX(), call.player:getY(), call.player:getZ(), SCAN_RADIUS_SQ),
                        BarteringAIUtils.countZombiesTargeting(call.player, SCAN_RADIUS_SQ),
                        BarteringAIUtils.countZombiesTargeting(zombie, SCAN_RADIUS_SQ)))
                end
            else
                setMeeting(record, true)
            end
        end

        updateMeetTimeout(bartererId, record, zombie, call, now)

        local status
        if not nearCaller then
            status = "waitingForCaller"
        elseif call.interceptDeclined then
            status = "declined"
        elseif record.interceptMeet then
            status = "meeting"
        else
            status = "unsafe"
        end

        if st.interceptStatus ~= status then
            st.interceptStatus = status
            print(string.format("[Bartering][Intercept] %s -> %s | dist=%.0f",
                tostring(bartererId), status,
                math.sqrt(BarteringAIUtils.distanceSqBetween(call.player, zombie))))
        end
        return "active"
    end

    local function shouldExpire(bartererId, record)
        local st = config.serverStateFor(bartererId)
        if st.visible or st.playerNear then
            st.lostSightAt = nil
            return false
        end

        local now = BarteringTiming.now()
        if not st.lostSightAt then
            st.lostSightAt = now
            return false
        end
        return BarteringTiming.hasElapsed(st.lostSightAt, LOST_SIGHT_GRACE_MS)
    end

    local function resumeTrip(bartererId, record, zombie)
        local call = config.pendingCalls[bartererId]
        local barterer = Bartering.Barterers[bartererId]
        local now = BarteringTiming.now()
        local travelSeconds = BarteringTiming.travelSeconds(
            zombie:getX(), zombie:getY(), call.targetX, call.targetY, barterer.travelSecondsPerTile)

        call.startX = zombie:getX()
        call.startY = zombie:getY()
        call.startedAtMs = now
        call.arrivalAtMs = now + math.floor(travelSeconds * 1000)
        call.intercepted = false
        call.route = nil

        Bartering.setRegistryRecord(config.callRegistry, bartererId,
            config.buildCallRecord(call.player, barterer, call.startedAtMs,
                call.targetX, call.targetY, call.targetZ, call.arrivalModeLocation, call.arrivalAtMs))
        config.setBartererETA(call.player, bartererId, call.arrivalAtMs, true,
            call.startX, call.startY, call.targetX, call.targetY, call.startedAtMs)
        config.despawnBarterer(bartererId)

        print(string.format(
            "[Bartering][Intercept] barterer %s lost sight while intercepted; resuming trip from %.0f,%.0f in %.0fs",
            tostring(bartererId), call.startX, call.startY, travelSeconds))
    end

    local function noteDialog(player, bartererId)
        config.serverStateFor(bartererId).interceptDialogAtMs = BarteringTiming.now()
    end

    local function decline(player, bartererId)
        local call = config.pendingCalls[bartererId]
        if not call or not call.intercepted then
            return
        end

        local record = Bartering.getLiveRecord(bartererId)
        local zombie = state.serverZombies[bartererId]
        if not record or record.unloaded or not zombie then
            return
        end

        BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Intercept.declined)
        call.interceptDeclined = true
        resumeToMeetup(record, call)

        config.setBartererETA(call.player, bartererId, call.arrivalAtMs, true,
            zombie:getX(), zombie:getY(), call.targetX, call.targetY, BarteringTiming.now())
    end

    local function stayHere(player, bartererId)
        local record = Bartering.getLiveRecord(bartererId)
        local zombie = state.serverZombies[bartererId]
        if not record or not record.intercepted or not zombie then
            return
        end

        clearInterception(bartererId, record)
        record.approachTargetX, record.approachTargetY, record.approachTargetZ = nil, nil, nil
        record.routeStartX, record.routeStartY, record.routeTargetX, record.routeTargetY = nil, nil, nil, nil
        record.routeStandoff = nil
        record.postX, record.postY, record.postZ =
            math.floor(zombie:getX()), math.floor(zombie:getY()), zombie:getZ()
        record.returningToPost = false
        record.hasArrived = true
        record.departureAtHours = BarteringTiming.createCalledInDepartureHours()
        Bartering.bumpLiveRev(record)

        local call = config.pendingCalls[bartererId]
        config.consumePendingCall(bartererId)
        config.setBartererETA(call and call.player or player, bartererId, 0, true)

        print(string.format("[Bartering][Intercept] barterer %s staying at %d,%d; meetup abandoned",
            tostring(bartererId), record.postX, record.postY))
    end

    return {
        begin = begin,
        clear = clearInterception,
        update = update,
        shouldExpire = shouldExpire,
        resumeTrip = resumeTrip,
        noteDialog = noteDialog,
        decline = decline,
        stayHere = stayHere,
    }
end

return BarteringIntercept
