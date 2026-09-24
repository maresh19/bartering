Bartering = Bartering or {}

local sendServerCommand = _G["sendServerCommand"]
local triggerEvent = _G["triggerEvent"]
local isServer = _G["isServer"]
local getCell = _G["getCell"]
local ModData = _G["ModData"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local BarteringIntercept = require "Movement/BarteringIntercept"
local BarteringDialogue = require "BarteringDialogue"
local BarteringHire = require "BarteringHire"
local BarteringReturn = require "Movement/BarteringReturn"
local print = require("BarteringPathTrace").log
local CALL_REGISTRY = Bartering.Registries.Call
local RETURNING_HOME_REGISTRY = Bartering.Registries.ReturningHome

local pendingCalls = {}
local calledInCleanups = {}
local callRegistryInitialized = false

local CALLED_IN_CLEANUP_WINDOW_MS = 8000
local CALL_PROGRESS_PERSIST_MS = 2000
local CALLED_IN_CLEANUP_RADIUS_SQ = 4
local MEETUP_WAIT_HOLD_MS = BarteringTiming.CALLED_IN_LIFETIME_MS

function Bartering.getBartererCallWindowHours(bartererId)
    local idSuffix = tostring(bartererId or "")
    local startHour = Bartering.getSandboxNumber(idSuffix .. "CallStartHour", 10)
    local endHour = Bartering.getSandboxNumber(idSuffix .. "CallEndHour", 22)
    return startHour, endHour
end

function Bartering.isBartererCallOpenIn(bartererId, seconds)
    if Bartering.getSandboxBoolean("DebugMode", false) then
        return true
    end

    local startHour, endHour = Bartering.getBartererCallWindowHours(bartererId)
    local hour = (getGameTime():getTimeOfDay() + seconds / BarteringTiming.realSecondsPerGameHour()) % 24

    if startHour == endHour then
        return true
    end

    if startHour < endHour then
        return hour >= startHour and hour < endHour
    end

    return hour >= startHour or hour < endHour
end

function Bartering.isBartererCallOpenNow(bartererId)
    return Bartering.isBartererCallOpenIn(bartererId, 0)
end

function Bartering.areCallWindowsIdentical()
    local firstStart, firstEnd
    for bartererId in pairs(Bartering.Barterers) do
        local s, e = Bartering.getBartererCallWindowHours(bartererId)
        if not firstStart then
            firstStart, firstEnd = s, e
        elseif s ~= firstStart or e ~= firstEnd then
            return false
        end
    end
    return true
end

function Bartering.getCallBlockReason(player, bartererId, formatHours)
    local hostile = Bartering.Hostility.isHostileTo(bartererId, player)
    local known = Bartering.isBartererKnown(player, bartererId)
    if Bartering.getSandboxBoolean("EnableRelationships", true)
        and Bartering.Relations.getStarCount(player, bartererId) < SandboxVars.Bartering.CallRelationshipStars and not hostile then
        local blocked = string.format(BarteringDialogue.Blocked.relationshipTooLow, SandboxVars.Bartering.CallRelationshipStars)
        if not known then
            return blocked .. ". Also requires meeting in person"
        end
        return blocked
    end
    if not known then
        return "Meet this barterer in person before radio calls are unlocked"
    end

    local displayName = Bartering.getBartererDisplayName(bartererId)
    if not Bartering.isBartererDeathHidden(bartererId) then
        if Bartering.isBartererPermanentlyDead(bartererId) then
            return displayName .. " is dead and cannot respawn with the current sandbox settings"
        end
        local respawnHours = BarteringTiming.remainingHours(Bartering.getBartererLifeState(bartererId).respawnAt)
        if respawnHours > 0 then
            return displayName .. " is dead and will be replaced with a new barterer in " .. formatHours(respawnHours)
        end
    end
    return nil
end

local BarteringCalls = {}

function BarteringCalls.new(config)
    local state = config.state
    local intercept
    local returnLogic

    local function sendToClient(player, command, args)
        if not player then
            return
        end
        if isServer() then
            sendServerCommand(player, "Bartering", command, args)
            return
        end
        triggerEvent("OnServerCommand", "Bartering", command, args)
    end

    local function setBartererAvailability(player, bartererId, available, permanentlyDead)
        sendToClient(player, "setBartererAvailability", {
            bartererId = bartererId,
            available = available,
            permanentlyDead = permanentlyDead,
        })
    end

    local function setBartererETA(player, bartererId, arrivalAtMs, calledOut, startX, startY, targetX, targetY, startedAtMs, waiting)
        local now = BarteringTiming.now()
        local arrival = arrivalAtMs or 0
        sendToClient(player, "setBartererETA", {
            bartererId = bartererId,
            remainingMs = arrival > 0 and math.max(1, arrival - now) or 0,
            elapsedMs = startedAtMs and math.max(0, now - startedAtMs) or 0,
            calledOut = calledOut == true,
            startX = startX,
            startY = startY,
            targetX = targetX,
            targetY = targetY,
            waiting = waiting == true,
        })
    end

    local function clearBartererETA(player, bartererId)
        setBartererETA(player, bartererId, 0, false)
    end

    local ZONE_SCAN_RADIUS_SQ = 20 * 20
    local ZONE_SCAN_MAX_ZOMBIES = 30
    local GRACE_PERIOD_MS = 120000

    local function getCallTargetLocation(player)
        local targetX = math.floor(player:getX())
        local targetY = math.floor(player:getY())
        local targetZ = player:getZ()

        for bartererId, record in pairs(Bartering.getLiveRecords()) do
            local zombie = state.serverZombies[bartererId]
            if zombie and record.state == "BlockedByDoor" then
                local baseX = math.floor(zombie:getX())
                local baseY = math.floor(zombie:getY())
                local offsets = {
                    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
                    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
                }
                for _, offset in ipairs(offsets) do
                    local square = getCell():getGridSquare(baseX + offset[1], baseY + offset[2], zombie:getZ())
                    if square and square:isFree(false) then
                        return baseX + offset[1], baseY + offset[2], zombie:getZ()
                    end
                end
            end
        end

        return targetX, targetY, targetZ
    end

    local function pendingCallPosition(call)
        call.startX = call.startX or call.barterer.x
        call.startY = call.startY or call.barterer.y

        return Bartering.RoadRoute.positionFor(call,
            BarteringTiming.progress(call.startedAtMs, call.arrivalAtMs))
    end

    local function setPendingCall(bartererId, player, barterer, startedAtMs, targetX, targetY, targetZ, arrivalModeLocation, arrivalAtMs)
        pendingCalls[bartererId] = {
            player = player,
            barterer = barterer,
            startedAtMs = startedAtMs,
            targetX = targetX,
            targetY = targetY,
            targetZ = targetZ,
            arrivalModeLocation = arrivalModeLocation == true,
            arrivalAtMs = arrivalAtMs,
            standoff = Bartering.RoadRoute.ARRIVAL_STANDOFF,
        }
        print(string.format(
            "[Bartering][Call] %s registered | arrivalInMs=%s target=%s,%s mode=%s",
            tostring(bartererId), tostring((arrivalAtMs or 0) - BarteringTiming.now()),
            tostring(targetX), tostring(targetY), tostring(arrivalModeLocation == true)))
    end

    local function consumePendingCall(bartererId)
        pendingCalls[bartererId] = nil
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
    end

    local function persistCallProgress(bartererId, call, now, x, y)
        if now - (call.persistedAtMs or 0) < CALL_PROGRESS_PERSIST_MS then
            return
        end
        call.persistedAtMs = now

        local record = Bartering.getRegistryRecord(CALL_REGISTRY, bartererId)
        if not record then
            return
        end

        record.remainingMs = math.max(0, call.arrivalAtMs - now)
        if x then
            record.startX = x
            record.startY = y
        end
    end

    local function bootstrapPersistedCalls()
        if callRegistryInitialized then
            return
        end

        local now = BarteringTiming.now()
        for bartererId, record in pairs(ModData.getOrCreate(CALL_REGISTRY)) do
            if record and record.barterer and not pendingCalls[bartererId] then
                local startedAtMs = record.startedAtMs
                local arrivalAtMs = record.arrivalAtMs
                if record.remainingMs then
                    startedAtMs = now
                    arrivalAtMs = now + record.remainingMs
                end

                setPendingCall(bartererId, config.resolvePlayerFromRecord(record), record.barterer, startedAtMs,
                    record.targetX, record.targetY, record.targetZ, record.arrivalModeLocation, arrivalAtMs)

                local call = pendingCalls[bartererId]
                call.startX = record.startX
                call.startY = record.startY
                if record.waitingAtMeetup then
                    call.waitingAtMeetup = true
                end

                print(string.format(
                    "[Bartering][Call] restored %s with %.0fs of travel left from %s,%s",
                    tostring(bartererId), (arrivalAtMs - now) / 1000,
                    tostring(record.startX), tostring(record.startY)))
            end
        end

        returnLogic.restoreReturningHome(now)

        callRegistryInitialized = true
    end

    local function hasCalledInEntry(bartererId)
        local record = Bartering.getLiveRecord(bartererId)
        return record ~= nil and not record.homeResident
    end

    local function homewardPosition(bartererId)
        local live = Bartering.getLiveRecord(bartererId)
        if live and not live.homeResident then
            if live.returningAfterMeeting then
                return live.x, live.y
            end
            return nil
        end
        local trip = Bartering.getRegistryRecord(RETURNING_HOME_REGISTRY, bartererId)
        if not trip then
            return nil
        end
        local left = math.max(0, trip.arriveHomeAtMs - BarteringTiming.now()) / trip.totalMs
        return trip.homeX + (trip.fromX - trip.homeX) * left, trip.homeY + (trip.fromY - trip.homeY) * left
    end

    local function otherMeetupEtaSeconds(player, bartererId)
        local call = pendingCalls[bartererId]
        if call then
            if call.player == player or call.waitingAtMeetup then
                return nil
            end
            return math.max(0, (call.arrivalAtMs - BarteringTiming.now()) / 1000)
        end
        local live = Bartering.getLiveRecord(bartererId)
        if not live or live.homeResident or live.returningAfterMeeting or live.hasArrived
            or live.master == player:getUsername() then
            return nil
        end
        local targetX, targetY = live.approachTargetX, live.approachTargetY
        if not targetX then
            local master = Bartering.findOnlinePlayer(live.master)
            targetX, targetY = master:getX(), master:getY()
        end
        return BarteringTiming.travelSeconds(live.x, live.y, targetX, targetY,
            Bartering.Barterers[bartererId].travelSecondsPerTile)
    end

    local function radioStatus(player, bartererId)
        local status, seconds
        local call = pendingCalls[bartererId]
        local live = Bartering.getLiveRecord(bartererId)
        if call then
            if call.player ~= player then
                status = call.waitingAtMeetup and "waiting" or "meetup"
                seconds = math.max(0, (call.arrivalAtMs - BarteringTiming.now()) / 1000)
            end
        elseif homewardPosition(bartererId) then
            status = "home"
        elseif live and not live.homeResident and live.master ~= player:getUsername() then
            status = live.hasArrived and "waiting" or "meetup"
            seconds = live.hasArrived and Bartering.getBartererDepartureRemainingSeconds(bartererId) or nil
        end
        sendToClient(player, "radioStatus", { bartererId = bartererId, status = status, seconds = seconds })
    end

    local function buildCallRecord(player, barterer, startedAtMs, targetX, targetY, targetZ, arrivalModeLocation, arrivalAtMs)
        return {
            barterer = barterer,
            playerName = player:getUsername(),
            startedAtMs = startedAtMs,
            targetX = targetX,
            targetY = targetY,
            targetZ = targetZ,
            arrivalModeLocation = arrivalModeLocation,
            arrivalAtMs = arrivalAtMs,
        }
    end

    local function refuseCall(player, bartererId, reason, clearEta, template, live)
        if clearEta then
            clearBartererETA(player, bartererId)
        end
        sendToClient(player, "callRefused", {
            bartererId = bartererId,
            reason = reason,
            template = template,
            live = live,
        })
    end

    local function callBarterer(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        local lifeState = Bartering.getBartererLifeState(bartererId)
        if Bartering.isBartererDeathHidden(bartererId) then
            lifeState.deathDiscovered = true
            Bartering.markBartererDataDirty(bartererId)
            clearBartererETA(player, bartererId)
            sendToClient(player, "callNoAnswer", {
                bartererId = bartererId,
                message = BarteringDialogue.Call.noAnswer,
            })
            return
        end
        local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
        if respawnRemainingHours > 0 then
            refuseCall(player, bartererId,
                string.format(BarteringDialogue.Call.injured, BarteringTiming.formatDurationHours(respawnRemainingHours)), true,
                "injured", "respawn")
            return
        end
        if Bartering.isBartererPermanentlyDead(bartererId) then
            refuseCall(player, bartererId, BarteringDialogue.Call.permanentlyDead, true)
            return
        end
        if BarteringHire.isHired(bartererId) and not BarteringHire.isHiredBy(player, bartererId) then
            refuseCall(player, bartererId, BarteringDialogue.Hire.workingRefusal, true, "working", nil)
            return
        end
        local otherEta = otherMeetupEtaSeconds(player, bartererId)
        if otherEta then
            local backIn = otherEta + BarteringTiming.CALLED_IN_LIFETIME_MS / 1000
            if Bartering.isBartererCallOpenIn(bartererId, backIn) then
                refuseCall(player, bartererId, string.format(BarteringDialogue.Call.otherMeetup,
                    BarteringTiming.formatArrivalEstimateHumanized(backIn)), true)
            else
                refuseCall(player, bartererId, BarteringDialogue.Call.tooLateAfterMeetup, true)
            end
            return
        end
        local pending = pendingCalls[bartererId]
        if pending then
            local etaSeconds = math.max(0, (pending.arrivalAtMs - BarteringTiming.now()) / 1000)
            refuseCall(player, bartererId,
                string.format(BarteringDialogue.Call.alreadyEnRoute, BarteringTiming.formatDuration(etaSeconds)), false,
                "alreadyEnRoute", "eta")
            return
        end
        if Bartering.getSandboxBoolean("EnableRelationships", true)
            and not Bartering.Hostility.isHostileTo(bartererId, player)
            and Bartering.Relations.getStarCount(player, bartererId) < SandboxVars.Bartering.CallRelationshipStars then
            refuseCall(player, bartererId, BarteringDialogue.Call.relationshipTooLow, true)
            return
        end
        if not Bartering.isBartererCallOpenNow(bartererId) then
            if homewardPosition(bartererId) then
                refuseCall(player, bartererId, BarteringDialogue.Call.tooLateHeadingHome, true)
            else
                refuseCall(player, bartererId, BarteringDialogue.Call.sleepingNoAnswer, true, "sleeping", nil)
            end
            return
        end

        if not Bartering.isBartererKnown(player, bartererId) then
            refuseCall(player, bartererId, BarteringDialogue.Call.strangerOnRadio, true)
            return
        end

        local fromX, fromY = homewardPosition(bartererId)
        if not fromX and hasCalledInEntry(bartererId) then
            refuseCall(player, bartererId, BarteringDialogue.Call.alreadyHere, true)
            return
        end

        if fromX then
            lifeState.returningHomeAt = nil
            Bartering.markBartererDataDirty(bartererId)
            Bartering.clearReturningHomeKnowledge(bartererId)
        else
            fromX, fromY = barterer.x, barterer.y
        end
        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, nil)

        local playerX, playerY, playerZ = getCallTargetLocation(player)
        if BarteringAIUtils.countZombiesNear(playerX, playerY, playerZ, ZONE_SCAN_RADIUS_SQ) > ZONE_SCAN_MAX_ZOMBIES then
            refuseCall(player, bartererId, BarteringDialogue.Call.areaInfested, true)
            return
        end
        config.despawnBarterer(bartererId)

        local arriveAtCallLocation = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1
        local targetX, targetY, targetZ = playerX, playerY, playerZ
        local travelSeconds = BarteringTiming.travelSeconds(fromX, fromY, targetX, targetY, barterer.travelSecondsPerTile)
        local startedAtMs = BarteringTiming.now()
        local arrivalAtMs = startedAtMs + travelSeconds * 1000

        local callRecord = buildCallRecord(player, barterer, startedAtMs, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs)
        callRecord.startX, callRecord.startY = fromX, fromY
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, callRecord)
        setPendingCall(bartererId, player, barterer, startedAtMs, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs)
        pendingCalls[bartererId].startX, pendingCalls[bartererId].startY = fromX, fromY
        setBartererETA(player, bartererId, arrivalAtMs, true, fromX, fromY, targetX, targetY, startedAtMs)
        local amendsPending = Bartering.Hostility.isAmendsPendingFor(bartererId, player)
        sendToClient(player, "callAccepted",
            { bartererId = bartererId, template = amendsPending and "amendsAccepted" or "accepted", live = "eta", message = string.format(BarteringDialogue.Call.accepted, BarteringTiming.formatArrivalEstimateHumanized(travelSeconds)) })
        if amendsPending then
            Bartering.Hostility.markAmendsCalled(bartererId)
        end
    end

    local function updateBartererCallLocation(player, bartererId)
        local call = pendingCalls[bartererId]
        local barterer = Bartering.Barterers[bartererId]
        if not call or not barterer or not call.arrivalModeLocation then
            return
        end

        local targetX, targetY, targetZ = getCallTargetLocation(player)
        local newTravelSeconds = BarteringTiming.travelSecondsTo(barterer, targetX, targetY)
        local elapsedSeconds = math.max(0, (BarteringTiming.now() - (call.startedAtMs or BarteringTiming.now())) / 1000)
        local adjustedRemainingSeconds = math.abs(newTravelSeconds - elapsedSeconds)

        call.player = player
        call.targetX = targetX
        call.targetY = targetY
        call.targetZ = targetZ
        call.route = nil
        call.arrivalAtMs = BarteringTiming.now() + adjustedRemainingSeconds * 1000
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId,
            buildCallRecord(player, barterer, call.startedAtMs, targetX, targetY, targetZ, true, call.arrivalAtMs))
        setBartererETA(player, bartererId, call.arrivalAtMs, true, barterer.x, barterer.y, targetX, targetY, call.startedAtMs)
        sendToClient(player, "callAccepted",
            { bartererId = bartererId, template = Bartering.Hostility.isAmendsPendingFor(bartererId, player) and "amendsAccepted" or "accepted", live = "eta", message = string.format(BarteringDialogue.Call.accepted, BarteringTiming.formatArrivalEstimateHumanized(adjustedRemainingSeconds)) })
    end

    local function debugCallBarterer(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        if not barterer then
            return
        end

        pendingCalls[bartererId] = nil
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, nil)
        config.despawnBarterer(bartererId)

        local arriveAtCallLocation = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1
        local targetX, targetY, targetZ
        if arriveAtCallLocation then
            targetX, targetY, targetZ = getCallTargetLocation(player)
        end
        local now = BarteringTiming.now()
        local arrivalAtMs = now + 2500
        setPendingCall(bartererId, player, barterer, now, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs)
        setBartererETA(player, bartererId, arrivalAtMs, true, barterer.x, barterer.y, targetX, targetY, now)
        sendToClient(player, "playerSay", { text = "Debug call sent for " .. Bartering.getBartererDisplayName(barterer.id) })
    end

    local function cancelBartererMeeting(player, bartererId)
        local call = pendingCalls[bartererId]
        if not call then
            return
        end

        local now = BarteringTiming.now()
        local elapsedSeconds = math.max(0, (now - call.startedAtMs) / 1000)
        local isGrace = (now - call.startedAtMs) <= GRACE_PERIOD_MS
        local amendsCancel = Bartering.Hostility.isAmendsPendingFor(bartererId, player)

        returnLogic.beginReturnHome(bartererId, { player, call.player }, state.serverZombies[bartererId], elapsedSeconds, amendsCancel)

        local targetPlayer = call.player or player
        local relationsEnabled = Bartering.getSandboxBoolean("EnableRelationships", true)

        local mainMessage
        local relationsDelta = 0

        if amendsCancel then
            mainMessage = "Whatever man.."
        elseif isGrace then
            mainMessage = "Oh I hadn't actually left yet, glad you called before I did"
        else
            mainMessage = "Next time figure out what your doing before you waste my time"
            if relationsEnabled then
                relationsDelta = -5
            end
        end

        local returnTrip
        if not isGrace then
            local barterer = call.barterer
            local currentX, currentY = pendingCallPosition(call)
            currentX = currentX or call.startX or barterer.x
            currentY = currentY or call.startY or barterer.y
            local travelSeconds = BarteringTiming.travelSeconds(
                currentX, currentY, barterer.x, barterer.y, barterer.travelSecondsPerTile)
            returnTrip = {
                bartererId = bartererId,
                startX = currentX,
                startY = currentY,
                targetX = barterer.x,
                targetY = barterer.y,
                elapsedMs = 0,
                remainingMs = math.floor(travelSeconds * 1000),
            }
        end

        pendingCalls[bartererId] = nil
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        setBartererETA(targetPlayer, bartererId, 0, false)
        setBartererAvailability(targetPlayer, bartererId, true)
        if returnTrip then
            sendToClient(targetPlayer, "returnTrip", returnTrip)
        end

        if relationsDelta ~= 0 then
            Bartering.Relations.add(targetPlayer, bartererId, relationsDelta)
        end

        sendToClient(targetPlayer, "meetupCanceled", {
            bartererId = bartererId,
            message = mainMessage,
            relationsDelta = relationsDelta,
            hostile = amendsCancel == true or nil,
        })
    end

    local function debugSpawnBartererAt(player, bartererId, x, y, z)
        local barterer = Bartering.Barterers[bartererId]
        Bartering.ensureBartererIdentity(bartererId)
        consumePendingCall(bartererId)
        config.despawnBarterer(bartererId)

        local targetX, targetY, targetZ
        if Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1 then
            targetX, targetY, targetZ = getCallTargetLocation(player)
        end
        config.spawnBarterer(player, barterer, x, y, z, false, nil, targetX, targetY, targetZ)
        setBartererETA(player, bartererId, 0, true)
    end

    local function debugSpawnBarterer(player, bartererId)
        debugSpawnBartererAt(player, bartererId, math.floor(player:getX()), math.floor(player:getY()), 0)
    end

    local function arrive(bartererId, call, spawnX, spawnY)
        local routeTrip = call.route and call.route.status == "ready" and call or nil
        local record
        if call.arrivalModeLocation then
            record = config.spawnBarterer(call.player, call.barterer, spawnX, spawnY, nil, false, nil,
                call.targetX, call.targetY, call.targetZ, routeTrip)
        else
            record = config.spawnBarterer(call.player, call.barterer, spawnX, spawnY, nil, false, nil,
                nil, nil, nil, routeTrip)
        end
        if record and call.waitingAtMeetup then
            record.meetupDeadlineHours = getGameTime():getWorldAgeHours()
                + math.max(0, call.arrivalAtMs - BarteringTiming.now()) / 1000 / BarteringTiming.realSecondsPerGameHour()
            record.departureAtHours = record.meetupDeadlineHours
            Bartering.bumpLiveRev(record)
        end
        consumePendingCall(bartererId)
        setBartererETA(call.player, bartererId, 0, true)
        sendToClient(call.player, "playerSay", { text = Bartering.getBartererDisplayName(call.barterer.id) .. " is approaching" })
    end

    local function holdBartererAtMeetup(bartererId, call, now)
        call.waitingAtMeetup = true
        call.intercepted = false
        call.route = nil
        call.startX = call.targetX
        call.startY = call.targetY
        call.startedAtMs = now
        call.arrivalAtMs = now + MEETUP_WAIT_HOLD_MS

        local record = Bartering.getRegistryRecord(CALL_REGISTRY, bartererId)
        if record then
            record.waitingAtMeetup = true
            record.startX = call.startX
            record.startY = call.startY
            record.remainingMs = MEETUP_WAIT_HOLD_MS
        end

        setBartererETA(call.player, bartererId, call.arrivalAtMs, true,
            call.startX, call.startY, call.targetX, call.targetY, now, true)
        print(string.format(
            "[Bartering][Call] %s reached the meetup %d,%d with no player in range; holding there",
            tostring(bartererId), call.targetX, call.targetY))
    end

    local function giveUpAtMeetup(bartererId, call)
        local barterer = call.barterer
        local travelSeconds = BarteringTiming.travelSeconds(
            call.targetX, call.targetY, barterer.x, barterer.y, barterer.travelSecondsPerTile)
        local arriveHomeAtMs = BarteringTiming.msFromSeconds(travelSeconds)

        returnLogic.beginReturnHome(bartererId, { call.player }, nil, travelSeconds)
        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, {
            arriveHomeAtMs = arriveHomeAtMs,
            remainingMs = math.max(0, arriveHomeAtMs - BarteringTiming.now()),
            fromX = call.targetX,
            fromY = call.targetY,
            homeX = barterer.x,
            homeY = barterer.y,
            totalMs = math.max(1, math.floor(travelSeconds * 1000)),
        })
        consumePendingCall(bartererId)
        setBartererAvailability(call.player, bartererId, true)
        setBartererETA(call.player, bartererId, 0, false)
        sendToClient(call.player, "returnTrip", {
            bartererId = bartererId,
            startX = call.targetX,
            startY = call.targetY,
            targetX = barterer.x,
            targetY = barterer.y,
            elapsedMs = 0,
            remainingMs = math.floor(travelSeconds * 1000),
        })
        print(string.format(
            "[Bartering][Call] %s gave up waiting at the meetup %d,%d; heading home in %.0fs",
            tostring(bartererId), call.targetX, call.targetY, travelSeconds))
    end

    local function updatePendingCalls()
        local now = BarteringTiming.now()
        for bartererId, call in pairs(pendingCalls) do
            if call.intercepted then
                if intercept.update(bartererId, call, now) == "consumed" then
                    consumePendingCall(bartererId)
                end

            elseif config.hasTrackedBarterer(bartererId) then
                consumePendingCall(bartererId)

            elseif call.player:isDead() then
                consumePendingCall(bartererId)
                setBartererAvailability(call.player, bartererId, true)
                setBartererETA(call.player, bartererId, 0, false)

            elseif now >= call.arrivalAtMs then
                if call.waitingAtMeetup then
                    giveUpAtMeetup(bartererId, call)
                elseif call.arrivalModeLocation
                    and not BarteringIntercept.findPlayerNear(call.targetX, call.targetY) then
                    holdBartererAtMeetup(bartererId, call, now)
                else
                    local fromX, fromY = pendingCallPosition(call)
                    arrive(bartererId, call, math.floor(fromX), math.floor(fromY))
                end

            else
                local x, y
                if call.waitingAtMeetup then
                    x, y = call.targetX, call.targetY
                else
                    x, y = pendingCallPosition(call)
                end
                persistCallProgress(bartererId, call, now, x, y)

                local nearby = x and BarteringIntercept.findPlayerNear(x, y)
                if nearby then
                    local markerNearMeetup =
                        BarteringAIUtils.distanceSq(x, y, call.targetX, call.targetY) <= BarteringIntercept.RADIUS_SQ
                    local playerNearMeetup =
                        BarteringAIUtils.distanceSq(nearby:getX(), nearby:getY(), call.targetX, call.targetY) <= BarteringIntercept.RADIUS_SQ
                    if markerNearMeetup or playerNearMeetup then
                        print(string.format(
                            "[Bartering][Call] %s arriving early at %.0f,%.0f; %s reached the path with %.0fs left",
                            tostring(bartererId), x, y, tostring(nearby:getUsername()), (call.arrivalAtMs - now) / 1000))
                        arrive(bartererId, call, math.floor(x), math.floor(y))
                    else
                        intercept.begin(bartererId, call, x, y)
                    end
                end
            end
        end
    end

    local function holdDepartureWhileBusy(bartererId, record)
        local st = config.serverStateFor(bartererId)
        local now = getGameTime():getWorldAgeHours()
        local previous = st.departureHeldAtHours
        st.departureHeldAtHours = now

        if not previous or not record.departureAtHours then
            return
        end

        local barterState = record.state or ""
        if barterState == "Waiting" or barterState == "BlockedByDoor" or barterState == "BlockedRoute" then
            return
        end

        record.departureAtHours = record.departureAtHours + (now - previous)
    end

    local function shouldExpire(bartererId, record)
        holdDepartureWhileBusy(bartererId, record)

        if record.intercepted then
            return intercept.shouldExpire(bartererId, record)
        end

        if record.returningAfterMeeting then
            return returnLogic.shouldExpireReturningHome(bartererId, record)
        end

        if record.homeResident then
            return false
        end

        return record.departureAtHours ~= nil and getGameTime():getWorldAgeHours() >= record.departureAtHours
    end

    intercept = BarteringIntercept.new({
        state = state,
        spawnBarterer = config.spawnBarterer,
        despawnBarterer = config.despawnBarterer,
        setBartererETA = setBartererETA,
        consumePendingCall = consumePendingCall,
        pendingCalls = pendingCalls,
        buildCallRecord = buildCallRecord,
        callRegistry = CALL_REGISTRY,
        serverStateFor = config.serverStateFor,
    })

    returnLogic = BarteringReturn.newSentHome({
        state = state,
        pendingCalls = pendingCalls,
        intercept = intercept,
        consumePendingCall = consumePendingCall,
        sendToClient = sendToClient,
        setBartererETA = setBartererETA,
        setBartererAvailability = setBartererAvailability,
        cancelBartererMeeting = cancelBartererMeeting,
        despawnBarterer = config.despawnBarterer,
        serverStateFor = config.serverStateFor,
        config = config,
    })

    local function handleExpiry(bartererId, record, zombie)
        if record.intercepted then
            intercept.resumeTrip(bartererId, record, zombie)
            return
        end

        if record.returningAfterMeeting then
            returnLogic.handleExpiryReturningHome(bartererId, record, zombie)
            return
        end

        returnLogic.startReturnHome(bartererId, record, Bartering.Barterers[bartererId])
    end

    local function registerCalledInCleanup(x, y, z)
        table.insert(calledInCleanups, {
            x = x,
            y = y,
            z = z,
            expiresAt = BarteringTiming.now() + CALLED_IN_CLEANUP_WINDOW_MS,
        })
    end

    local function processCalledInCleanups()
        if #calledInCleanups == 0 then
            return
        end

        local now = BarteringTiming.now()
        local zombies = getCell():getZombieList()
        for i = #calledInCleanups, 1, -1 do
            local cleanup = calledInCleanups[i]
            local resolved = false

            if now >= cleanup.expiresAt then
                resolved = true
            else
                local closest, closestDistSq
                for j = 0, zombies:size() - 1 do
                    local zombie = zombies:get(j)
                    if not zombie:isDead()
                        and not state.serverZombieIds[zombie]
                        and zombie:getZ() == cleanup.z then
                        local distSq = BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), cleanup.x, cleanup.y)
                        if distSq <= CALLED_IN_CLEANUP_RADIUS_SQ and (not closestDistSq or distSq < closestDistSq) then
                            closest = zombie
                            closestDistSq = distSq
                        end
                    end
                end

                if closest then
                    Bartering.removeZombieEverywhere(closest)
                    resolved = true
                end
            end

            if resolved then
                table.remove(calledInCleanups, i)
            end
        end
    end

    local function spawnRestoredCalledInBarterer(barterer, record, removeLeftover)
        config.clearBartererDeath(barterer.id)

        local restoredState = record.state
        if restoredState == nil or restoredState == "" then
            restoredState = record.hasArrived and "Waiting" or "Approach"
        end

        local z = record.z or 0
        local zombie, gun, knife, x, y = config.createBartererZombie({
            barterer = barterer,
            spawnX = record.x,
            spawnY = record.y,
            spawnZ = z,
            bartererState = restoredState,
            useless = record.hasArrived == true and not record.returningAfterMeeting,
        })
        if not zombie then
            return false
        end

        config.registerLive(barterer, zombie, gun, knife, record)

        if removeLeftover then
            registerCalledInCleanup(x, y, z)
        end

        print(string.format(
            "[Bartering][ServerDebug] restored called-in %s state=%s arrived=%s returning=%s departAtHours=%s",
            tostring(barterer.id), tostring(restoredState), tostring(record.hasArrived),
            tostring(record.returningAfterMeeting), tostring(record.departureAtHours)))

        return true
    end

    local function updateUnloaded(bartererId, record)
        if BarteringHire.isHired(bartererId) then
            return
        end
        local masterGone = record.master ~= nil and not Bartering.findOnlinePlayer(record.master)
        local departed = record.departureAtHours ~= nil and getGameTime():getWorldAgeHours() >= record.departureAtHours
        if not masterGone and not departed and not record.returningAfterMeeting then
            return
        end
        print(string.format("[Bartering][MP] unloaded %s heading home | masterGone=%s departed=%s returning=%s",
            tostring(bartererId), tostring(masterGone), tostring(departed), tostring(record.returningAfterMeeting)))
        consumePendingCall(bartererId)
        returnLogic.sendUnloadedHome(bartererId, record)
    end

    local function pruneLiveRecords()
        local records = Bartering.getLiveRecords()
        for bartererId, record in pairs(records) do
            local barterer = Bartering.Barterers[bartererId]
            local lifeState = Bartering.getBartererLifeState(bartererId)
            local awaitingRespawn = BarteringTiming.remainingHours(lifeState.respawnAt) > 0
            if not barterer or record.homeResident or Bartering.isBartererPermanentlyDead(bartererId) or awaitingRespawn then
                records[bartererId] = nil
            else
                record.unloaded = true
                record.zid = nil
                print("[Bartering] Called-in barterer " .. tostring(bartererId)
                    .. " will reload at " .. tostring(record.x) .. "," .. tostring(record.y) .. "," .. tostring(record.z)
                    .. " state=" .. tostring(record.state) .. " arrived=" .. tostring(record.hasArrived))
            end

            pendingCalls[bartererId] = nil
            Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        end
        Bartering.markLiveDirty()
    end

    local function clearPendingCall(bartererId)
        consumePendingCall(bartererId)
    end

    local function hasPendingCall(bartererId)
        return pendingCalls[bartererId] ~= nil
    end

    local function resetState()
        for bartererId in pairs(pendingCalls) do
            pendingCalls[bartererId] = nil
        end
        calledInCleanups = {}
        callRegistryInitialized = false
    end

    return {
        shouldExpire = shouldExpire,
        handleExpiry = handleExpiry,
        clearIntercept = intercept.clear,
        processCalledInCleanups = processCalledInCleanups,
        pruneLiveRecords = pruneLiveRecords,
        updateUnloaded = updateUnloaded,
        spawnRestoredCalledInBarterer = spawnRestoredCalledInBarterer,
        clearPendingCall = clearPendingCall,
        hasPendingCall = hasPendingCall,
        registerCalledInCleanup = registerCalledInCleanup,
        resetState = resetState,
        sendToClient = sendToClient,
        setBartererAvailability = setBartererAvailability,
        setBartererETA = setBartererETA,
        bootstrapPersistedCalls = bootstrapPersistedCalls,
        callBarterer = callBarterer,
        radioStatus = radioStatus,
        updateBartererCallLocation = updateBartererCallLocation,
        debugCallBarterer = debugCallBarterer,
        cancelBartererMeeting = cancelBartererMeeting,
        sendBartererHome = returnLogic.sendBartererHome,
        sendPlayerBarterersHome = returnLogic.sendPlayerBarterersHome,
        debugSpawnBarterer = debugSpawnBarterer,
        debugSpawnBartererAt = debugSpawnBartererAt,
        debugSendAllHomeNow = returnLogic.debugSendAllHomeNow,
        updatePendingCalls = updatePendingCalls,
        acceptStayHere = intercept.stayHere,
        declineTradeHere = intercept.decline,
        noteInterceptDialog = intercept.noteDialog,
    }
end

return BarteringCalls
