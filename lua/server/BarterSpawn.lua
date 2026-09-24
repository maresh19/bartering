local createZombie = _G["createZombie"]
local IsoDirections = _G["IsoDirections"]
local getCell = _G["getCell"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"
local BarteringIntercept = require "Movement/BarteringIntercept"
local BarteringReturn = require "Movement/BarteringReturn"
local print = require("BarteringPathTrace").log

local BarterSpawn = {}

BarterSpawn.DORMANT_DISTANCE = 40
BarterSpawn.DORMANT_DISTANCE_SQ = BarterSpawn.DORMANT_DISTANCE * BarterSpawn.DORMANT_DISTANCE
BarterSpawn.LOAD_DISTANCE = 30
BarterSpawn.LOAD_DISTANCE_SQ = BarterSpawn.LOAD_DISTANCE * BarterSpawn.LOAD_DISTANCE
BarterSpawn.STARTING_AMMO = 90
BarterSpawn.STARTING_MAGAZINES = 5

local MAX_TILES_PER_TICK_SQ = 16
local SPAWN_SCAN_INTERVAL_TICKS = 60
local PROBE_HOME_RADIUS_SQ = 6 * 6
local PROBE_HOME_TICKS = 60 * 90

function BarterSpawn.new(config)
    local state = config.state
    local scanTicks = 0
    local leftoverCleanupPending = {}
    local spawnCounter = 0

    local function despawnZombie(zombie)
        Bartering.removeZombieEverywhere(zombie)
    end

    local function trackBarterer(entry)
        entry.attackCooldown = 0
        entry.returnFarTicks = 0
        entry.blockedOpenables = {}
        entry.idleTurnTicks = config.idleTurnIntervalTicks
        table.insert(state.barterers, entry)
        return entry
    end

    local function untrackEntry(index)
        local entry = state.barterers[index]
        config.combat.releaseBartererThreats(entry.zombie)
        table.remove(state.barterers, index)
        return entry
    end

    local function localItem(zombie, itemType)
        local inventory = zombie:getInventory()
        return inventory:getFirstTypeRecurse(itemType) or inventory:AddItem(itemType)
    end

    local function attachController(zombie, bartererId, record)
        local weapon = Bartering.getBartererWeapon(bartererId)
        local entry = trackBarterer({
            zombie = zombie,
            bartererId = bartererId,
            seq = record.seq,
            zid = zombie:getOnlineID(),
            gun = localItem(zombie, weapon.item),
            knife = localItem(zombie, Bartering.Barterers[bartererId].equipment.knife),
            projectileCount = weapon.projectileCount or 1,
            lastX = zombie:getX(),
            lastY = zombie:getY(),
            lastZ = zombie:getZ(),
        })
        if entry.gun:getCurrentAmmoCount() == 0 then
            local capacity = entry.gun:getMaxAmmo()
            local loaded = math.min(capacity, record.ammo)
            if entry.gun:getMagazineType() and record.ammo % capacity > 0 then
                loaded = record.ammo % capacity
            end
            entry.gun:setCurrentAmmoCount(loaded)
        end
        entry.ammoReserve = record.ammo - entry.gun:getCurrentAmmoCount()
        print(string.format("[Bartering][Ammo] attach %s gun=%s loaded=%d max=%d recordAmmo=%d reserve=%d",
            bartererId, tostring(entry.gun), entry.gun:getCurrentAmmoCount(), entry.gun:getMaxAmmo(),
            record.ammo, entry.ammoReserve))
        config.applyRecord(entry, record)
        config.combat.equipWeapon(zombie, entry.gun, weapon.weaponType)
        return entry
    end

    local function hasTrackedBarterer(bartererId)
        local record = Bartering.getLiveRecord(bartererId)
        return record ~= nil and not record.unloaded
    end

    local function forgetServerZombie(bartererId)
        local zombie = state.serverZombies[bartererId]
        if zombie then
            state.serverZombieIds[zombie] = nil
        end
        state.serverZombies[bartererId] = nil
        state.serverItems[bartererId] = nil
        state.serverState[bartererId] = nil
    end

    local function removeLive(bartererId)
        forgetServerZombie(bartererId)
        Bartering.getLiveRecords()[bartererId] = nil
        Bartering.markLiveDirty()
    end

    local function despawnBarterer(bartererId)
        local zombie = state.serverZombies[bartererId]
        removeLive(bartererId)
        leftoverCleanupPending[bartererId] = nil
        if zombie then
            despawnZombie(zombie)
        end
    end

    local function markUnloaded(bartererId, record)
        forgetServerZombie(bartererId)
        if record.homeResident then
            Bartering.getLiveRecords()[bartererId] = nil
            Bartering.markLiveDirty()
            return
        end
        record.unloaded = true
        record.zid = nil
        Bartering.bumpLiveRev(record)
    end

    local function unloadBarterer(bartererId, record, zombie)
        print(string.format("[Bartering][MP] %s no player in range; unloading until a player returns", tostring(bartererId)))
        leftoverCleanupPending[bartererId] = nil
        markUnloaded(bartererId, record)
        despawnZombie(zombie)
    end

    local function noteLeftover(bartererId)
        leftoverCleanupPending[bartererId] = true
    end

    local function ownsServerZombie(bartererId, record, zombie)
        if isServer() then
            return zombie:getOnlineID() == record.zid
        end
        if zombie:getVariableString("BartererId") ~= bartererId then
            return false
        end
        local st = state.serverStateFor(bartererId)
        local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
        if st.lastX and (BarteringAIUtils.distanceSq(x, y, st.lastX, st.lastY) > MAX_TILES_PER_TICK_SQ
            or math.abs(z - st.lastZ) > 1) then
            return false
        end
        st.lastX, st.lastY, st.lastZ = x, y, z
        return true
    end

    local function releaseLost(bartererId, record, zombie, reason)
        print(string.format("[Bartering][MP] %s lost its zombie (%s); releasing at %.2f,%.2f,%.2f",
            tostring(bartererId), tostring(reason), zombie:getX(), zombie:getY(), zombie:getZ()))
        noteLeftover(bartererId)
        markUnloaded(bartererId, record)
    end

    local function isPlayerNearTile(x, y, maxDistSq)
        return BarteringAIUtils.forEachPlayer(function(player)
            return BarteringAIUtils.distanceSqToTile(player:getX(), player:getY(), x, y) <= maxDistSq
        end)
    end

    local function findPlayerNearHome(barterer)
        return BarteringAIUtils.findPlayer(function(player)
            return Bartering.isNearBartererHome(barterer, player:getX(), player:getY(), BarterSpawn.LOAD_DISTANCE_SQ)
        end)
    end

    local probeTicks = 0

    local function probeZombie(zombie)
        return string.format(
            "zid=%s pos=%.2f,%.2f,%.2f square=%s outfit=%s barterer=%s id=[%s] state=[%s] action=%s useless=%s visuals=[%s]",
            tostring(zombie:getOnlineID()), zombie:getX(), zombie:getY(), zombie:getZ(),
            tostring(zombie:getSquare() ~= nil),
            tostring(zombie:getPersistentOutfitID()),
            tostring(zombie:getVariableBoolean("Barterer")),
            tostring(zombie:getVariableString("BartererId")),
            tostring(zombie:getVariableString("BartererState")),
            tostring(zombie:getActionStateName()),
            tostring(zombie:isUseless()),
            Bartering.describeItemVisuals(zombie))
    end

    local function probeOnZombieCreate(zombie)
        print(string.format("[Bartering][Probe][Create] %s", probeZombie(zombie)))
    end

    local function probeHomes()
        probeTicks = probeTicks + 1
        if not state.residentsInitialized or probeTicks > PROBE_HOME_TICKS or (probeTicks % 60) ~= 0 then
            return
        end
        local zombies = getCell():getZombieList()
        for _, barterer in pairs(Bartering.Barterers) do
            local identity = Bartering.getBartererIdentityState(barterer.id)
            for i = 0, zombies:size() - 1 do
                local zombie = zombies:get(i)
                if zombie:getZ() == barterer.z
                    and BarteringAIUtils.distanceSqToTile(zombie:getX(), zombie:getY(), barterer.x, barterer.y) <= PROBE_HOME_RADIUS_SQ then
                    print(string.format(
                        "[Bartering][Probe][Home] t=%d %s home=%d,%d,%d wearsOutfit=%s expected=[%s] | %s",
                        probeTicks, tostring(barterer.id), barterer.x, barterer.y, barterer.z,
                        tostring(identity.clothing ~= nil
                            and Bartering.bartererVisualsMatch(zombie, identity.clothing)),
                        identity.clothing and table.concat(identity.clothing, ";") or "",
                        probeZombie(zombie)))
                end
            end
        end
    end

    local function requestLeftoverCleanup(bartererId, x, y, z)
        if not leftoverCleanupPending[bartererId] then
            return
        end
        leftoverCleanupPending[bartererId] = nil
        config.calls.registerCalledInCleanup(x, y, z)
    end

    local function shouldRespawnForCause(cause)
        if cause == "player" then
            return Bartering.getSandboxBoolean("RespawnAfterPlayerKill", true)
        end
        if cause == "zombie" then
            return Bartering.getSandboxBoolean("RespawnAfterZombieKill", true)
        end
        return true
    end

    local function markBartererDeath(bartererId, cause, witnessed)
        local lifeState = Bartering.getBartererLifeState(bartererId)
        Bartering.markBartererDataDirty(bartererId)
        lifeState.deathCause = cause
        lifeState.deathWitnessed = witnessed == true
        if shouldRespawnForCause(cause) then
            lifeState.permanentlyDead = false
            lifeState.respawnAt = getGameTime():getWorldAgeHours() + Bartering.getSandboxNumber("RespawnHours", 6)
            Bartering.clearBartererHome(bartererId)
            return false
        end

        lifeState.permanentlyDead = true
        lifeState.respawnAt = nil
        return true
    end

    local function clearBartererDeath(bartererId)
        local lifeState = Bartering.getBartererLifeState(bartererId)
        lifeState.permanentlyDead = false
        lifeState.deathCause = nil
        lifeState.respawnAt = nil
        lifeState.deathWitnessed = nil
        lifeState.deathDiscovered = nil
        Bartering.markBartererDataDirty(bartererId)
        Bartering.clearReturningHomeKnowledge(bartererId)
    end

    local function equipBartererZombie(zombie, barterer)
        local weapon = Bartering.getBartererWeapon(barterer.id)
        local inventory = zombie:getInventory()
        local gun = inventory:getFirstTypeRecurse(weapon.item) or inventory:AddItem(weapon.item)
        local knife = inventory:getFirstTypeRecurse(barterer.equipment.knife)
            or inventory:AddItem(barterer.equipment.knife)
        Bartering.syncBartererStockToContainer(Bartering.getBartererBag(zombie), barterer.id)
        return gun, knife
    end

    local function createBartererZombie(params)
        local barterer = params.barterer
        local identity = Bartering.ensureBartererIdentity(barterer.id, params.forceNewIdentity)
        local z = params.spawnZ
        local x, y = config.findSpawnLocation(math.floor(params.spawnX), math.floor(params.spawnY), z)

        print(string.format("[Bartering][Probe][SpawnPre] %s asking for %d,%d,%d", tostring(barterer.id), x, y, z))
        local zombie = createZombie(x, y, z, nil, 0, IsoDirections.S)
        print(string.format("[Bartering][Probe][SpawnPost] %s %s", tostring(barterer.id), probeZombie(zombie)))
        local square = getCell():getGridSquare(x, y, z)
        print(string.format(
            "[Bartering] Spawning %s at %s, %s, %s; created=%s | asked=%s,%s square=%s free=%s standable=%s",
            Bartering.getBartererDisplayName(barterer.id),
            tostring(x), tostring(y), tostring(z), tostring(zombie ~= nil),
            tostring(params.spawnX), tostring(params.spawnY),
            tostring(square ~= nil),
            tostring(square and square:isFree(false)),
            tostring(BarteringAIUtils.isStandableSquare(square))))
        if not zombie then
            return nil
        end

        Bartering.applyBartererIdentityToZombie(zombie, barterer.id)
        Bartering.provisionBartererZombie(zombie, barterer.id)
        zombie:setUseless(params.useless == true)
        zombie:setVariable("BartererState", params.bartererState)
        BarteringAIUtils.resetPassiveState(zombie)
        zombie:setDir(IsoDirections.S)

        Bartering.dressBartererZombie(zombie, identity)
        Bartering.captureBartererIdentity(zombie, barterer.id)

        local gun, knife = equipBartererZombie(zombie, barterer)
        print(string.format("[Bartering][Probe][SpawnDone] %s %s", tostring(barterer.id), probeZombie(zombie)))
        return zombie, gun, knife, x, y
    end

    local function registerLive(barterer, zombie, gun, knife, record)
        spawnCounter = spawnCounter + 1
        record.bartererId = barterer.id
        record.seq = BarteringTiming.now() + spawnCounter
        record.zid = zombie:getOnlineID()
        record.unloaded = nil
        record.x, record.y, record.z = zombie:getX(), zombie:getY(), zombie:getZ()
        record.ammo = record.ammo or (gun:getMagazineType()
            and gun:getMaxAmmo() * (BarterSpawn.STARTING_MAGAZINES + 1) - ZombRand(6) or BarterSpawn.STARTING_AMMO - ZombRand(6))
        Bartering.getLiveRecords()[barterer.id] = record
        Bartering.bumpLiveRev(record)
        Bartering.transmitGlobalNow(Bartering.Registries.Live)
        state.serverZombies[barterer.id] = zombie
        state.serverZombieIds[zombie] = barterer.id
        state.serverItems[barterer.id] = { gun = gun, knife = knife }
        state.serverState[barterer.id] = nil
        print(string.format("[Bartering][MP] registered %s zid=%s seq=%s resident=%s isServer=%s",
            tostring(barterer.id), tostring(record.zid), tostring(record.seq),
            tostring(record.homeResident == true), tostring(isServer())))
        return record
    end

    local function spawnBarterer(player, barterer, spawnX, spawnY, spawnZ, homeResident, forceNewIdentity, approachTargetX, approachTargetY, approachTargetZ, routeTrip)
        clearBartererDeath(barterer.id)
        despawnBarterer(barterer.id)
        Bartering.setRegistryRecord(Bartering.Registries.ReturningHome, barterer.id, nil)

        local targetX = spawnX
        local targetY = spawnY

        local z = homeResident and (spawnZ or barterer.z) or 0

        if homeResident then
            BarteringReturn.clearPostIntruders(targetX, targetY, z,
                BarteringReturn.RESIDENT_POST_CLEAR_DISTANCE, nil)
        end

        local zombie, gun, knife, x, y = createBartererZombie({
            barterer = barterer,
            spawnX = targetX,
            spawnY = targetY,
            spawnZ = z,
            bartererState = "Approach",
            useless = false,
            forceNewIdentity = forceNewIdentity,
        })
        if not zombie then
            return nil
        end

        local record = registerLive(barterer, zombie, gun, knife, {
            homeResident = homeResident == true,
            hasArrived = homeResident == true,
            returningToPost = false,
            returningAfterMeeting = false,
            postX = homeResident and x or nil,
            postY = homeResident and y or nil,
            postZ = homeResident and z or nil,
            approachTargetX = approachTargetX,
            approachTargetY = approachTargetY,
            approachTargetZ = approachTargetZ,
            routeStartX = routeTrip and routeTrip.startX or nil,
            routeStartY = routeTrip and routeTrip.startY or nil,
            routeTargetX = routeTrip and routeTrip.targetX or nil,
            routeTargetY = routeTrip and routeTrip.targetY or nil,
            routeStandoff = routeTrip and routeTrip.standoff or nil,
            departureAtHours = (not homeResident) and BarteringTiming.createCalledInDepartureHours() or nil,
            master = (not homeResident) and player and player:getUsername() or nil,
            state = "Approach",
        })

        if homeResident then
            Bartering.setRegistryRecord(Bartering.Registries.Call, barterer.id, nil)
            requestLeftoverCleanup(barterer.id, x, y, z)
        end

        if routeTrip and routeTrip.route and routeTrip.route.status == "ready" then
            print(string.format(
                "[Bartering][Call] %s spawned at %d,%d, %.0f of %.0f tiles along its road route; following it before heading to the meetup",
                tostring(barterer.id), x, y,
                BarteringIntercept.nearestAlongRoute(routeTrip.route, x + 0.5, y + 0.5), routeTrip.route.total))
        end

        return record
    end

    local function spawnResidentBarterer(player, barterer, worldAgeHours)
        local lifeState = Bartering.getBartererLifeState(barterer.id)
        if BarteringTiming.remainingHours(lifeState.respawnAt) > 0 then
            return
        end
        local returningRemaining = BarteringTiming.remainingHours(lifeState.returningHomeAt)
        if returningRemaining > 0 then
            return
        end
        if lifeState.returningHomeAt ~= nil then
            lifeState.returningHomeAt = nil
            Bartering.markBartererDataDirty(barterer.id)
            Bartering.clearReturningHomeKnowledge(barterer.id)
        end

        local readyToRespawn = lifeState.respawnAt ~= nil and worldAgeHours >= lifeState.respawnAt
        Bartering.ensureBartererIdentity(barterer.id, readyToRespawn)
        Bartering.ensureBartererHome(barterer)
        spawnBarterer(player, barterer, barterer.x, barterer.y, barterer.z, true, readyToRespawn)
    end

    local function updateSpawns()
        if not state.residentsInitialized then
            return
        end

        scanTicks = scanTicks - 1
        if scanTicks > 0 then
            return
        end
        scanTicks = SPAWN_SCAN_INTERVAL_TICKS

        local worldAgeHours = getGameTime():getWorldAgeHours()
        local now = BarteringTiming.now()

        for _, barterer in pairs(Bartering.Barterers) do
            if not hasTrackedBarterer(barterer.id)
                and not Bartering.isBartererPermanentlyDead(barterer.id)
                and not config.calls.hasPendingCall(barterer.id) then

                local returning = Bartering.getRegistryRecord(Bartering.Registries.ReturningHome, barterer.id)
                if returning and returning.arriveHomeAtMs then
                    if now >= tonumber(returning.arriveHomeAtMs) then
                        Bartering.setRegistryRecord(Bartering.Registries.ReturningHome, barterer.id, nil)
                        returning = nil
                    else
                        returning.remainingMs = tonumber(returning.arriveHomeAtMs) - now
                    end
                end

                if not returning then
                    local record = Bartering.getLiveRecord(barterer.id)
                    if record then
                        if isPlayerNearTile(record.x, record.y, BarterSpawn.LOAD_DISTANCE_SQ) then
                            config.calls.spawnRestoredCalledInBarterer(barterer, record,
                                leftoverCleanupPending[barterer.id] == true)
                            leftoverCleanupPending[barterer.id] = nil
                        end
                    else
                        local player = findPlayerNearHome(barterer)
                        if player then
                            spawnResidentBarterer(player, barterer, worldAgeHours)
                        end
                    end
                end
            end
        end
    end

    local function bootstrap()
        if state.residentsInitialized then
            return
        end

        local player = BarteringAIUtils.getAnyAvailablePlayer()
        if not player then
            return
        end

        config.calls.bootstrapPersistedCalls()
        config.calls.pruneLiveRecords()

        leftoverCleanupPending = {}
        for _, barterer in pairs(Bartering.Barterers) do
            Bartering.ensureBartererHome(barterer)
            leftoverCleanupPending[barterer.id] = true
        end

        state.residentsInitialized = true
        scanTicks = 0
    end

    local function resetBootstrap()
        state.serverZombies = {}
        state.serverZombieIds = {}
        state.serverItems = {}
        state.serverState = {}
        state.residentsInitialized = false
        config.calls.resetState()
    end

    return {
        despawnZombie = despawnZombie,
        despawnBarterer = despawnBarterer,
        removeLive = removeLive,
        untrackEntry = untrackEntry,
        attachController = attachController,
        hasTrackedBarterer = hasTrackedBarterer,
        ownsServerZombie = ownsServerZombie,
        releaseLost = releaseLost,
        noteLeftover = noteLeftover,
        unloadBarterer = unloadBarterer,
        markUnloaded = markUnloaded,
        createBartererZombie = createBartererZombie,
        registerLive = registerLive,
        spawnBarterer = spawnBarterer,
        markBartererDeath = markBartererDeath,
        clearBartererDeath = clearBartererDeath,
        updateSpawns = updateSpawns,
        bootstrap = bootstrap,
        resetBootstrap = resetBootstrap,
        probeOnZombieCreate = probeOnZombieCreate,
        probeHomes = probeHomes,
    }
end

return BarterSpawn
