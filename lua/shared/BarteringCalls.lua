Bartering = Bartering or {}

local sendServerCommand = _G["sendServerCommand"]
local triggerEvent = _G["triggerEvent"]
local isServer = _G["isServer"]
local getCell = _G["getCell"]
local ModData = _G["ModData"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local CALL_REGISTRY = Bartering.Registries.Call
local ACTIVE_CALLED_IN_REGISTRY = Bartering.Registries.ActiveCalledIn
local RETURNING_HOME_REGISTRY = Bartering.Registries.ReturningHome

local pendingCalls = {}
local calledInCleanups = {}
local callRegistryInitialized = false

local ACTIVE_CALLED_IN_PERSIST_TICKS = 20
local CALLED_IN_CLEANUP_WINDOW_MS = 8000
local RETURN_OUT_OF_SIGHT_GRACE_MS = 5000
local CALLED_IN_CLEANUP_RADIUS_SQ = 4
local CALLED_IN_LIFETIME_HOURS = BarteringTiming.CALLED_IN_LIFETIME_HOURS

function Bartering.getBartererCallWindowHours(bartererId)
    local idSuffix = tostring(bartererId or "")
    local startHour = Bartering.getSandboxNumber(idSuffix .. "CallStartHour", 10)
    local endHour = Bartering.getSandboxNumber(idSuffix .. "CallEndHour", 22)
    return startHour, endHour
end

function Bartering.isBartererCallOpenNow(bartererId)
    local startHour, endHour = Bartering.getBartererCallWindowHours(bartererId)
    local currentHour = getGameTime():getTimeOfDay()

    if startHour == endHour then
        return true
    end

    if startHour < endHour then
        return currentHour >= startHour and currentHour < endHour
    end

    return currentHour >= startHour or currentHour < endHour
end

local BarteringCalls = {}

function BarteringCalls.new(config)
    local state = config.state

    local function sendToClient(player, command, args)
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

    local function setBartererETA(player, bartererId, arrivalAtMs, calledOut, startX, startY, targetX, targetY, startedAtMs)
        sendToClient(player, "setBartererETA", {
            bartererId = bartererId,
            arrivalAtMs = arrivalAtMs or 0,
            calledOut = calledOut == true,
            startX = startX,
            startY = startY,
            targetX = targetX,
            targetY = targetY,
            startedAtMs = startedAtMs,
        })
    end

    local function clearBartererETA(player, bartererId)
        setBartererETA(player, bartererId, 0, false)
    end

    local ZONE_SCAN_RADIUS = 20
    local ZONE_SCAN_MAX_ZOMBIES = 30
    local GRACE_PERIOD_MS = 120000

    local function countZombiesInRadius(x, y, z, radius)
        local count = 0
        local zombies = getCell():getZombieList()
        local radiusSq = radius * radius
        for i = 0, zombies:size() - 1 do
            local zombie = zombies:get(i)
            if math.floor(zombie:getZ()) == math.floor(z)
                and BarteringAIUtils.distanceSq(zombie:getX(), zombie:getY(), x, y) <= radiusSq then
                count = count + 1
            end
        end
        return count
    end

    local function getCallTargetLocation(player)
        return math.floor(player:getX()), math.floor(player:getY()), player:getZ()
    end

    local function getCallTravelSecondsToLocation(barterer, targetX, targetY)
        return BarteringTiming.calculateTravelSeconds(
            targetX,
            targetY,
            barterer.x,
            barterer.y,
            barterer.travelSecondsPerTile,
            Bartering.getSandboxNumber("TravelTimeMultiplier", 1)
        )
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
        }
    end

    local function bootstrapPersistedCalls()
        if callRegistryInitialized then
            return
        end

        for bartererId, record in pairs(ModData.getOrCreate(CALL_REGISTRY)) do
            if record and record.barterer and not pendingCalls[bartererId] then
                setPendingCall(bartererId, config.resolvePlayerFromRecord(record), record.barterer, record.startedAtMs,
                    record.targetX, record.targetY, record.targetZ, record.arrivalModeLocation, record.arrivalAtMs)
            end
        end

        callRegistryInitialized = true
    end

    local function hasCalledInEntry(bartererId)
        for _, entry in ipairs(state.barterers) do
            if entry.bartererId == bartererId and not entry.homeResident then
                return true
            end
        end
        return false
    end

    local function buildCallRecord(player, barterer, startedAtMs, targetX, targetY, targetZ, arrivalModeLocation, arrivalAtMs)
        return {
            barterer = barterer,
            playerName = player:getUsername(),
            playerOnlineId = player:getOnlineID(),
            startedAtMs = startedAtMs,
            targetX = targetX,
            targetY = targetY,
            targetZ = targetZ,
            arrivalModeLocation = arrivalModeLocation,
            arrivalAtMs = arrivalAtMs,
        }
    end

    local function refuseCall(player, bartererId, reason, clearEta)
        if clearEta then
            clearBartererETA(player, bartererId)
        end
        sendToClient(player, "callRefused", {
            bartererId = bartererId,
            reason = reason,
        })
    end

    local function callBarterer(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        local lifeState = Bartering.getBartererLifeState(bartererId)
        local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)
        if respawnRemainingHours > 0 then
            refuseCall(player, bartererId, "I'm laid up right now and won't be back in "
                .. BarteringTiming.formatDuration(respawnRemainingHours * 3600), true)
            return
        end
        if Bartering.isBartererPermanentlyDead(bartererId) then
            refuseCall(player, bartererId, "This channel's dead, buddy. Nothing's picking up.", true)
            return
        end
        local pending = pendingCalls[bartererId]
        if pending then
            local etaSeconds = math.max(0, (pending.arrivalAtMs - getTimeInMillis()) / 1000)
            refuseCall(player, bartererId, "I'm already on my way. I'll be there in "
                .. BarteringTiming.formatDuration(etaSeconds))
            return
        end
        if Bartering.Relations.getStarCount(player, bartererId) < 1 then
            refuseCall(player, bartererId, "I don't know you well enough for radio calls", true)
            return
        end
        if not Bartering.isBartererCallOpenNow(bartererId) then
            local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(bartererId)
            refuseCall(player, bartererId, string.format("%s only answers between %02d:00 and %02d:00",
                Bartering.getBartererDisplayName(bartererId), callStartHour, callEndHour), true)
            return
        end

        if not Bartering.isBartererKnown(player, bartererId) then
            refuseCall(player, bartererId, "Who is this? We ain't met. Come see me face to face.", true)
            return
        end

        if hasCalledInEntry(bartererId) then
            refuseCall(player, bartererId, "I'm already here, ain't I?", true)
            return
        end

        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, nil)

        local playerX, playerY, playerZ = getCallTargetLocation(player)
        if countZombiesInRadius(playerX, playerY, playerZ, ZONE_SCAN_RADIUS) > ZONE_SCAN_MAX_ZOMBIES then
            refuseCall(player, bartererId, "Last I heard that area was way too infested, sorry buddy", true)
            return
        end
        config.despawnBarterer(bartererId)

        local arriveAtCallLocation = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1
        local targetX, targetY, targetZ = playerX, playerY, playerZ
        local travelSeconds = getCallTravelSecondsToLocation(barterer, targetX, targetY)
        local startedAtMs = getTimeInMillis()
        local arrivalAtMs = startedAtMs + travelSeconds * 1000

        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId,
            buildCallRecord(player, barterer, startedAtMs, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs))
        setPendingCall(bartererId, player, barterer, startedAtMs, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs)
        setBartererETA(player, bartererId, arrivalAtMs, true, barterer.x, barterer.y, targetX, targetY, startedAtMs)
        sendToClient(player, "callAccepted",
            { bartererId = bartererId, message = "Yeah i can be there in about " .. BarteringTiming.formatArrivalEstimateHumanized(travelSeconds) })
    end

    local function updateBartererCallLocation(player, bartererId)
        local call = pendingCalls[bartererId]
        local barterer = Bartering.Barterers[bartererId]
        if not call or not barterer or not call.arrivalModeLocation then
            return
        end

        local targetX, targetY, targetZ = getCallTargetLocation(player)
        local newTravelSeconds = getCallTravelSecondsToLocation(barterer, targetX, targetY)
        local elapsedSeconds = math.max(0, (getTimeInMillis() - (call.startedAtMs or getTimeInMillis())) / 1000)
        local adjustedRemainingSeconds = math.abs(newTravelSeconds - elapsedSeconds)

        call.player = player
        call.targetX = targetX
        call.targetY = targetY
        call.targetZ = targetZ
        call.arrivalAtMs = getTimeInMillis() + adjustedRemainingSeconds * 1000
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId,
            buildCallRecord(player, barterer, call.startedAtMs, targetX, targetY, targetZ, true, call.arrivalAtMs))
        setBartererETA(player, bartererId, call.arrivalAtMs, true, barterer.x, barterer.y, targetX, targetY, call.startedAtMs)
        sendToClient(player, "callAccepted",
            { bartererId = bartererId, message = "Yeah i can be there in about " .. BarteringTiming.formatArrivalEstimateHumanized(adjustedRemainingSeconds) })
    end

    local function debugCallBarterer(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        if not barterer then
            return
        end

        pendingCalls[bartererId] = nil
        Bartering.setRegistryRecord(ACTIVE_CALLED_IN_REGISTRY, bartererId, nil)
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, bartererId, nil)
        config.despawnBarterer(bartererId)

        local arriveAtCallLocation = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1
        local targetX, targetY, targetZ
        if arriveAtCallLocation then
            targetX, targetY, targetZ = getCallTargetLocation(player)
        end
        local now = getTimeInMillis()
        local arrivalAtMs = now + 2500
        setPendingCall(bartererId, player, barterer, now, targetX, targetY, targetZ, arriveAtCallLocation, arrivalAtMs)
        setBartererETA(player, bartererId, arrivalAtMs, true, barterer.x, barterer.y, targetX, targetY, now)
        player:Say("Debug call sent for " .. Bartering.getBartererDisplayName(barterer.id))
    end

    local function startReturnHome(entry, barterer)
        local zombie = entry.zombie
        entry.hasArrived = true
        entry.returningToPost = true
        entry.returningAfterMeeting = true
        entry.lostSightAt = nil
        entry.postX, entry.postY = config.findSpawnLocation(barterer.x, barterer.y, barterer.z)
        entry.postZ = barterer.z
        entry.approachTargetX = nil
        entry.approachTargetY = nil
        entry.approachTargetZ = nil
        entry.arrivalTime = nil
        entry.departureAtMs = nil
        BarteringAIUtils.clearPathing(zombie)
        zombie:setVariable("BartererDepartureAtMs", "0")
        zombie:setVariable("BartererState", "Return")
    end

    local function cancelBartererMeeting(player, bartererId)
        local call = pendingCalls[bartererId]
        if not call then
            return
        end

        local now = getTimeInMillis()
        local elapsedSeconds = math.max(0, (now - call.startedAtMs) / 1000)
        local isGrace = (now - call.startedAtMs) <= GRACE_PERIOD_MS

        local lifeState = Bartering.getBartererLifeState(bartererId)
        local worldAgeHours = getGameTime():getWorldAgeHours()
        local cooldownGameHours = elapsedSeconds / BarteringTiming.realSecondsPerGameHour()
        lifeState.calledInCooldownAt = worldAgeHours + cooldownGameHours
        lifeState.returningHomeAt = worldAgeHours + cooldownGameHours
        Bartering.markBartererDataDirty(bartererId)

        local targetPlayer = call.player or player
        local relationsEnabled = Bartering.getSandboxBoolean("EnableRelationships", true)

        local mainMessage
        local relationsDelta = 0

        if isGrace then
            mainMessage = "Oh I hadn't actually left yet, glad you called before I did"
        else
            mainMessage = "Next time figure out what your doing before you waste my time"
            if relationsEnabled then
                relationsDelta = -5
            end
        end

        pendingCalls[bartererId] = nil
        Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        setBartererETA(targetPlayer, bartererId, 0, false)
        setBartererAvailability(targetPlayer, bartererId, true)

        if relationsDelta ~= 0 then
            Bartering.Relations.add(targetPlayer, bartererId, relationsDelta)
        end

        sendToClient(targetPlayer, "meetupCanceled", {
            bartererId = bartererId,
            message = mainMessage,
            relationsDelta = relationsDelta,
        })
    end

    local function sendBartererHome(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        if not barterer then
            return
        end

        if pendingCalls[bartererId] then
            cancelBartererMeeting(player, bartererId)
            return
        end

        for i = #state.barterers, 1, -1 do
            local entry = state.barterers[i]
            if entry.bartererId == bartererId and not entry.homeResident then
                local owner = entry.master or player
                startReturnHome(entry, barterer)
                owner:Say(Bartering.getBartererDisplayName(barterer.id) .. " is returning home")
                return
            end
        end
    end

    local function debugSpawnBarterer(player, bartererId)
        local barterer = Bartering.Barterers[bartererId]
        Bartering.ensureBartererIdentity(bartererId, true)
        pendingCalls[bartererId] = nil
        config.despawnBarterer(bartererId)

        local targetX, targetY, targetZ
        if Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1 then
            targetX, targetY, targetZ = getCallTargetLocation(player)
        end
        config.spawnBarterer(player, barterer, math.floor(player:getX()), math.floor(player:getY()), player:getZ(), false, nil,
            targetX, targetY, targetZ)
        setBartererETA(player, bartererId, 0, true)
    end

    local function debugSpawnBartererAt(player, bartererId, x, y, z)
        local barterer = Bartering.Barterers[bartererId]
        Bartering.ensureBartererIdentity(bartererId, true)
        pendingCalls[bartererId] = nil
        config.despawnBarterer(bartererId)

        local targetX, targetY, targetZ
        if Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1 then
            targetX, targetY, targetZ = getCallTargetLocation(player)
        end
        config.spawnBarterer(player, barterer, x, y, z, false, nil, targetX, targetY, targetZ)
        setBartererETA(player, bartererId, 0, true)
    end

    local function updatePendingCalls()
        local now = getTimeInMillis()
        for bartererId, call in pairs(pendingCalls) do
            if config.hasTrackedBarterer(bartererId) then
                pendingCalls[bartererId] = nil

            elseif call.player:isDead() then
                pendingCalls[bartererId] = nil
                setBartererAvailability(call.player, bartererId, true)
                setBartererETA(call.player, bartererId, 0, false)

            elseif now >= call.arrivalAtMs then
                if call.arrivalModeLocation then
                    config.spawnBarterer(call.player, call.barterer, nil, nil, nil, false, nil, call.targetX, call.targetY, call.targetZ)
                else
                    config.spawnBarterer(call.player, call.barterer)
                end
                pendingCalls[bartererId] = nil
                setBartererETA(call.player, bartererId, 0, true)
            end
        end
    end

    local function isVisibleToAnyPlayer(zombie)
        return BarteringAIUtils.forEachPlayer(function(player)
            if player:CanSee(zombie) then
                return true
            end
        end)
    end

    local function shouldExpire(entry)
        if entry.returningAfterMeeting then
            if entry.zombie and isVisibleToAnyPlayer(entry.zombie) then
                entry.lostSightAt = nil
                return false
            end
            local now = getTimeInMillis()
            if not entry.lostSightAt then
                entry.lostSightAt = now
                return false
            end
            if now - entry.lostSightAt < RETURN_OUT_OF_SIGHT_GRACE_MS then
                return false
            end
            print("[Bartering][ServerDebug] barterer " .. tostring(entry.bartererId)
                .. " out of sight " .. tostring(now - entry.lostSightAt) .. "ms while returning; expiring")
            return true
        end

        if entry.homeResident or not entry.arrivalTime then
            return false
        end

        local departureAtMs = entry.departureAtMs
        if (not departureAtMs or departureAtMs <= 0) and entry.zombie then
            departureAtMs = tonumber(entry.zombie:getVariableString("BartererDepartureAtMs")) or 0
            if departureAtMs > 0 then
                entry.departureAtMs = departureAtMs
            end
        end

        if departureAtMs and departureAtMs > 0 then
            return getTimeInMillis() >= departureAtMs
        end

        return BarteringTiming.minutesSince(entry.arrivalTime) >= math.floor(CALLED_IN_LIFETIME_HOURS * 60)
    end

    local function clearActiveCalledInEntry(entry)
        if not entry.homeResident then
            Bartering.setRegistryRecord(ACTIVE_CALLED_IN_REGISTRY, entry.bartererId, nil)
        end
    end

    local function handleExpiry(entry, zombie)
        if entry.returningAfterMeeting then
            local barterer = Bartering.Barterers[entry.bartererId]
            local homeX = entry.postX
            local homeY = entry.postY
            if not homeX then
                homeX = barterer and barterer.x
                homeY = barterer and barterer.y
            end
            local travelSeconds = 0
            local returnTrip
            if barterer and homeX and homeY then
                travelSeconds = BarteringTiming.calculateTravelSeconds(
                    zombie:getX(), zombie:getY(),
                    homeX + 0.5, homeY + 0.5,
                    barterer.travelSecondsPerTile,
                    Bartering.getSandboxNumber("TravelTimeMultiplier", 1))
                returnTrip = {
                    bartererId = entry.bartererId,
                    startX = zombie:getX(),
                    startY = zombie:getY(),
                    targetX = homeX + 0.5,
                    targetY = homeY + 0.5,
                    startedAtMs = getTimeInMillis(),
                    arrivalAtMs = getTimeInMillis() + math.floor(travelSeconds * 1000),
                }
            end
            local arriveHomeAtMs = getTimeInMillis() + math.floor(travelSeconds * 1000)

            Bartering.setRegistryRecord(RETURNING_HOME_REGISTRY, entry.bartererId, {
                arriveHomeAtMs = arriveHomeAtMs,
            })
            clearActiveCalledInEntry(entry)
            config.clearCombatTask(entry)
            setBartererAvailability(entry.master, entry.bartererId, true)
            setBartererETA(entry.master, entry.bartererId, 0, false)
            if returnTrip then
                sendToClient(entry.master, "returnTrip", returnTrip)
            end
            if zombie:getSquare() then
                config.despawnZombie(zombie)
            end

            print(string.format(
                "[Bartering][ServerDebug] barterer %s despawned returning home; finishes trip in %.0fs arriveHomeAtMs=%d",
                tostring(entry.bartererId), travelSeconds, arriveHomeAtMs))
            return false
        end

        local barterer = Bartering.Barterers[entry.bartererId]
        if barterer then
            startReturnHome(entry, barterer)
            config.clearCombatTask(entry)
        end
        return true
    end

    local function persistActiveCalledInEntry(entry, zombie, force)
        if entry.homeResident then
            return
        end

        if zombie:isDead() or zombie:getHealth() <= 0 then
            Bartering.setRegistryRecord(ACTIVE_CALLED_IN_REGISTRY, entry.bartererId, nil)
            print("[Bartering][ServerDebug] called-in barterer " .. tostring(entry.bartererId)
                .. " is dead; cleared active called-in record instead of persisting")
            return
        end

        entry.activeRecordCooldown = (entry.activeRecordCooldown or 0) - 1
        if entry.activeRecordCooldown > 0 and not force then
            return
        end
        entry.activeRecordCooldown = ACTIVE_CALLED_IN_PERSIST_TICKS

        local master = entry.master
        Bartering.setRegistryRecord(ACTIVE_CALLED_IN_REGISTRY, entry.bartererId, {
            bartererId = entry.bartererId,
            x = math.floor(zombie:getX()),
            y = math.floor(zombie:getY()),
            z = zombie:getZ(),
            state = zombie:getVariableString("BartererState") or "",
            hasArrived = entry.hasArrived == true,
            arrivalTime = entry.arrivalTime,
            returningToPost = entry.returningToPost == true,
            returningAfterMeeting = entry.returningAfterMeeting == true,
            postX = entry.postX,
            postY = entry.postY,
            postZ = entry.postZ,
            approachTargetX = entry.approachTargetX,
            approachTargetY = entry.approachTargetY,
            approachTargetZ = entry.approachTargetZ,
            departureAtMs = entry.departureAtMs,
            masterOnlineId = master and tostring(master:getOnlineID()) or nil,
            masterName = master and tostring(master:getUsername()) or nil,
        })
    end

    local function registerCalledInCleanup(x, y, z)
        table.insert(calledInCleanups, {
            x = x,
            y = y,
            z = z,
            expiresAt = getTimeInMillis() + CALLED_IN_CLEANUP_WINDOW_MS,
        })
    end

    local function processCalledInCleanups()
        if #calledInCleanups == 0 then
            return
        end

        local now = getTimeInMillis()
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
                        and not zombie:getVariableBoolean("Barterer")
                        and zombie:getZ() == cleanup.z then
                        local distSq = BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), cleanup.x, cleanup.y)
                        if distSq <= CALLED_IN_CLEANUP_RADIUS_SQ and (not closestDistSq or distSq < closestDistSq) then
                            closest = zombie
                            closestDistSq = distSq
                        end
                    end
                end

                if closest then
                    config.despawnZombie(closest)
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
        config.despawnBarterer(barterer.id)

        local master = config.resolvePlayerFromRecord({
            BartererMaster = record.masterOnlineId,
            BartererMasterName = record.masterName,
        })

        local z = record.z or (master and master:getZ()) or 0
        local departureAtMs = tonumber(record.departureAtMs) or 0
        local restoredState = record.state
        if restoredState == nil or restoredState == "" then
            restoredState = record.hasArrived and "Waiting" or "Approach"
        end

        local zombie, gun, knife = config.createBartererZombie({
            barterer = barterer,
            master = master,
            spawnX = record.x,
            spawnY = record.y,
            spawnZ = z,
            calledIn = true,
            departureAtMs = departureAtMs,
            bartererState = restoredState,
            useless = record.hasArrived == true and not record.returningAfterMeeting,
        })
        if not zombie then
            return false
        end

        config.trackBarterer({
            zombie = zombie,
            bartererId = barterer.id,
            master = master,
            gun = gun,
            knife = knife,
            projectileCount = Bartering.getBartererWeapon(barterer.id).projectileCount or 1,
            homeResident = false,
            hasArrived = record.hasArrived == true,
            returningToPost = record.returningToPost == true,
            returningAfterMeeting = record.returningAfterMeeting == true,
            postX = record.postX or record.x,
            postY = record.postY or record.y,
            postZ = record.postZ or z,
            approachTargetX = record.approachTargetX,
            approachTargetY = record.approachTargetY,
            approachTargetZ = record.approachTargetZ,
            arrivalTime = record.arrivalTime
                or (record.hasArrived and getGameTime():getMinutesStamp() or nil),
            departureAtMs = departureAtMs > 0 and departureAtMs or nil,
        })

        if removeLeftover then
            registerCalledInCleanup(record.x, record.y, z)
        end

        print(string.format(
            "[Bartering][ServerDebug] restored called-in %s state=%s arrived=%s returning=%s arrivalTime=%s departAtMs=%s",
            tostring(barterer.id), tostring(restoredState), tostring(record.hasArrived),
            tostring(record.returningAfterMeeting), tostring(record.arrivalTime),
            tostring(record.departureAtMs)))

        return true
    end

    local function pruneActiveCalledInRecords()
        for bartererId, record in pairs(ModData.getOrCreate(ACTIVE_CALLED_IN_REGISTRY)) do
            local barterer = Bartering.Barterers[bartererId]
            local lifeState = Bartering.getBartererLifeState(bartererId)
            local awaitingRespawn = BarteringTiming.remainingHours(lifeState.respawnAt) > 0
            local master = config.resolvePlayerFromRecord(record)
            if not barterer or Bartering.isBartererPermanentlyDead(bartererId) or awaitingRespawn
                or (master and master:isDead()) then
                Bartering.setRegistryRecord(ACTIVE_CALLED_IN_REGISTRY, bartererId, nil)
            else
                print("[Bartering] Called-in barterer " .. tostring(bartererId)
                    .. " will reload at " .. tostring(record.x) .. "," .. tostring(record.y) .. "," .. tostring(record.z)
                    .. " state=" .. tostring(record.state) .. " arrived=" .. tostring(record.hasArrived))
            end

            pendingCalls[bartererId] = nil
            Bartering.setRegistryRecord(CALL_REGISTRY, bartererId, nil)
        end
    end

    local function clearPendingCall(bartererId)
        pendingCalls[bartererId] = nil
    end

    local function hasPendingCall(bartererId)
        return pendingCalls[bartererId] ~= nil
    end

    local function resetState()
        pendingCalls = {}
        calledInCleanups = {}
        callRegistryInitialized = false
    end

    return {
        shouldExpire = shouldExpire,
        handleExpiry = handleExpiry,
        persistActiveCalledInEntry = persistActiveCalledInEntry,
        clearActiveCalledInEntry = clearActiveCalledInEntry,
        processCalledInCleanups = processCalledInCleanups,
        pruneActiveCalledInRecords = pruneActiveCalledInRecords,
        spawnRestoredCalledInBarterer = spawnRestoredCalledInBarterer,
        clearPendingCall = clearPendingCall,
        hasPendingCall = hasPendingCall,
        registerCalledInCleanup = registerCalledInCleanup,
        resetState = resetState,
        setBartererAvailability = setBartererAvailability,
        setBartererETA = setBartererETA,
        bootstrapPersistedCalls = bootstrapPersistedCalls,
        callBarterer = callBarterer,
        updateBartererCallLocation = updateBartererCallLocation,
        debugCallBarterer = debugCallBarterer,
        cancelBartererMeeting = cancelBartererMeeting,
        sendBartererHome = sendBartererHome,
        debugSpawnBarterer = debugSpawnBarterer,
        debugSpawnBartererAt = debugSpawnBartererAt,
        updatePendingCalls = updatePendingCalls,
    }
end

return BarteringCalls
