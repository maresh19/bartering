local addZombiesInOutfit = _G["addZombiesInOutfit"]
local IsoDirections = _G["IsoDirections"]
local ModData = _G["ModData"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTiming = require "BarteringTiming"

local BarterSpawn = {}

BarterSpawn.DORMANT_DISTANCE = 40
BarterSpawn.DORMANT_DISTANCE_SQ = BarterSpawn.DORMANT_DISTANCE * BarterSpawn.DORMANT_DISTANCE
BarterSpawn.LOAD_DISTANCE = 30
BarterSpawn.LOAD_DISTANCE_SQ = BarterSpawn.LOAD_DISTANCE * BarterSpawn.LOAD_DISTANCE

local MAX_TILES_PER_TICK_SQ = 16
local STARTING_AMMO = 90
local SPAWN_SCAN_INTERVAL_TICKS = 60

function BarterSpawn.new(config)
    local state = config.state
    local log = config.logBartererServerDebug
    local scanTicks = 0
    local leftoverCleanupPending = {}

    local function despawnZombie(zombie)
        zombie:removeFromWorld()
        zombie:removeFromSquare()
    end

    local function hasTrackedBarterer(bartererId)
        return BarteringAIUtils.findBartererEntry(state.barterers, bartererId) ~= nil
    end


    local function trackBarterer(entry)
        local zombie = entry.zombie
        entry.attackCooldown = 0
        entry.returnFarTicks = 0
        entry.idleTurnTicks = config.idleTurnIntervalTicks
        entry.lastX, entry.lastY, entry.lastZ = zombie:getX(), zombie:getY(), zombie:getZ()
        table.insert(state.barterers, entry)
        return entry
    end

    local function untrackEntry(index)
        local entry = state.barterers[index]
        config.combat.releaseBartererThreats(entry.zombie)
        table.remove(state.barterers, index)
        return entry
    end

    local function noteLeftover(bartererId)
        leftoverCleanupPending[bartererId] = true
    end

    local function despawnBartererEntry(index)
        local entry = untrackEntry(index)
        leftoverCleanupPending[entry.bartererId] = nil
        despawnZombie(entry.zombie)
    end

    local function despawnBarterer(bartererId)
        for i = #state.barterers, 1, -1 do
            if state.barterers[i].bartererId == bartererId then
                despawnBartererEntry(i)
            end
        end
    end


    local function deprovisionBarterer(zombie)
        zombie:setVariable("Barterer", false)
        zombie:setVariable("BartererId", "")
        zombie:setVariable("BartererState", "")
        zombie:setPrimaryHandItem(nil)
        zombie:setSecondaryHandItem(nil)
        zombie:setUseless(false)
        zombie:setNoTeeth(false)
        zombie:setReanim(false)
        zombie:resetEquippedHandsModels()
        zombie:clearAttachedItems()
    end

    local function ownsZombie(entry)
        local zombie = entry.zombie
        if zombie:getVariableString("BartererId") ~= entry.bartererId then
            return false
        end

        local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
        if BarteringAIUtils.distanceSq(x, y, entry.lastX, entry.lastY) > MAX_TILES_PER_TICK_SQ
            or math.abs(z - entry.lastZ) > 1 then
            return false
        end

        entry.lastX, entry.lastY, entry.lastZ = x, y, z
        return true
    end

    local function releaseLostEntry(index)
        local entry = state.barterers[index]
        print(string.format(
            "[Bartering][ServerDebug] barterer %s no longer owns its zombie (engine reused the instance); releasing entry at %.2f,%.2f,%.2f",
            tostring(entry.bartererId), entry.zombie:getX(), entry.zombie:getY(), entry.zombie:getZ()))
        noteLeftover(entry.bartererId)
        untrackEntry(index)
        deprovisionBarterer(entry.zombie)
        entry.zombie:setZombiesDontAttack(false)
    end

    local function isPlayerNearTile(x, y, maxDistSq)
        return BarteringAIUtils.forEachPlayer(function(player)
            return BarteringAIUtils.distanceSqToTile(player:getX(), player:getY(), x, y) <= maxDistSq
        end)
    end

    local function findPlayerNearHome(barterer)
        local found = nil
        BarteringAIUtils.forEachPlayer(function(player)
            if Bartering.isNearAnySpawnLocation(barterer, player:getX(), player:getY(), BarterSpawn.LOAD_DISTANCE_SQ) then
                found = player
                return true
            end
        end)
        return found
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

    local function markBartererDeath(bartererId, cause)
        local lifeState = Bartering.getBartererLifeState(bartererId)
        Bartering.markBartererDataDirty(bartererId)
        lifeState.deathCause = cause
        if shouldRespawnForCause(cause) then
            lifeState.permanentlyDead = false
            lifeState.respawnAt = getGameTime():getWorldAgeHours() + Bartering.getSandboxNumber("RespawnHours", 6)
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
        Bartering.markBartererDataDirty(bartererId)
    end

    local function setBartererMaster(zombie, master)
        if not master then
            return
        end

        zombie:setVariable("BartererMaster", tostring(master:getOnlineID()))
        zombie:setVariable("BartererMasterName", tostring(master:getUsername()))
    end

    local function equipBartererZombie(zombie, barterer, master)
        local weapon = Bartering.getBartererWeapon(barterer.id)
        local inventory = zombie:getInventory()
        local gun = inventory:getFirstTypeRecurse(weapon.item) or inventory:AddItem(weapon.item)
        local knife = inventory:getFirstTypeRecurse(barterer.equipment.knife)
            or inventory:AddItem(barterer.equipment.knife)

        if inventory:getCountTypeRecurse(weapon.ammoItem) == 0 then
            for _ = 1, STARTING_AMMO do
                inventory:AddItem(weapon.ammoItem)
            end
        end

        Bartering.syncBartererStockToContainer(Bartering.getBartererBag(zombie), barterer.id, master)
        config.combat.equipWeapon(zombie, gun, weapon.weaponType)

        return gun, knife, weapon
    end

    local function createBartererZombie(params)
        local barterer = params.barterer
        local identity = Bartering.ensureBartererIdentity(barterer.id, params.forceNewIdentity)
        local z = params.spawnZ
        local x, y = config.findSpawnLocation(params.spawnX, params.spawnY, z)

        local femaleChance = barterer.gender == "female" and 100 or 0
        local zombieList = addZombiesInOutfit(x, y, z, 1, "Naked1", femaleChance)
        print("[Bartering] Spawning " .. Bartering.getBartererDisplayName(barterer.id) .. " at " .. tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z) .. "; result count " .. tostring(zombieList:size()))
        if zombieList:size() == 0 then
            return nil
        end

        local zombie = zombieList:get(0)
        Bartering.applyBartererIdentityToZombie(zombie, barterer.id)

        zombie:setNoTeeth(true)
        zombie:setUseless(params.useless == true)
        zombie:setReanim(false)
        zombie:clearAggroList()
        zombie:setVariable("Barterer", true)
        zombie:setVariable("BartererId", barterer.id)
        zombie:setVariable("BartererCalledIn", params.calledIn)
        zombie:setVariable("BartererDepartureAtMs", tostring(params.departureAtMs))
        zombie:setVariable("BartererMuzzleFlashAt", "0")

        setBartererMaster(zombie, params.master)

        zombie:setWalkType("BartererWalk")
        zombie:setVariable("BartererWalkType", "BartererWalk")
        zombie:setVariable("ZombieHitReaction", "Chainsaw")
        zombie:resetEquippedHandsModels()
        zombie:clearAttachedItems()
        zombie:setTurnAlertedValues(-5, 5)
        BarteringAIUtils.resetPassiveState(zombie)
        zombie:setDir(IsoDirections.S)
        zombie:setVariable("MovementSpeed", "1.00")
        zombie:setVariable("BartererState", params.bartererState)
        zombie:setVariable("BartererVisualsApplied", false)

        Bartering.dressBartererZombie(zombie, identity)
        Bartering.storeBartererIdentityOnZombie(zombie, barterer.id)

        local gun, knife = equipBartererZombie(zombie, barterer, params.master)

        return zombie, gun, knife, x, y
    end

    local function spawnBarterer(player, barterer, spawnX, spawnY, spawnZ, homeResident, forceNewIdentity, approachTargetX, approachTargetY, approachTargetZ)
        clearBartererDeath(barterer.id)
        despawnBarterer(barterer.id)
        Bartering.setRegistryRecord(Bartering.Registries.ReturningHome, barterer.id, nil)

        local targetX = spawnX
        local targetY = spawnY
        if not targetX or not targetY then
            local dx = player:getX() - barterer.x
            local dy = player:getY() - barterer.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance == 0 then
                dx = 1
                dy = 0
                distance = 1
            end
            targetX = math.floor(player:getX() - dx / distance * 20)
            targetY = math.floor(player:getY() - dy / distance * 20)
        end
        local z = spawnZ or player:getZ()

        local departureAtMs = 0
        if not homeResident then
            departureAtMs = BarteringTiming.createCalledInDeparture()
        end

        local zombie, gun, knife, x, y = createBartererZombie({
            barterer = barterer,
            master = player,
            spawnX = targetX,
            spawnY = targetY,
            spawnZ = z,
            calledIn = not homeResident,
            departureAtMs = departureAtMs,
            bartererState = "Approach",
            useless = false,
            forceNewIdentity = forceNewIdentity,
        })
        if not zombie then
            return
        end

        if homeResident then
            Bartering.setRegistryRecord(Bartering.Registries.Call, barterer.id, nil)
            requestLeftoverCleanup(barterer.id, x, y, z)
        else
            Bartering.setRegistryRecord(Bartering.Registries.Call, barterer.id, {
                barterer = barterer,
                playerName = player and player:getUsername() or nil,
                playerOnlineId = player and player:getOnlineID() or nil,
                startedAtMs = getTimeInMillis(),
                targetX = approachTargetX,
                targetY = approachTargetY,
                targetZ = approachTargetZ,
                arrivalModeLocation = approachTargetX ~= nil and approachTargetY ~= nil and approachTargetZ ~= nil,
                arrivalAtMs = departureAtMs,
            })
        end

        trackBarterer({
            zombie = zombie,
            bartererId = barterer.id,
            master = player,
            gun = gun,
            knife = knife,
            projectileCount = Bartering.getBartererWeapon(barterer.id).projectileCount or 1,
            homeResident = homeResident,
            hasArrived = homeResident,
            postX = homeResident and x,
            postY = homeResident and y,
            postZ = homeResident and z,
            approachTargetX = approachTargetX,
            approachTargetY = approachTargetY,
            approachTargetZ = approachTargetZ,
            departureAtMs = homeResident and nil or departureAtMs,
        })

        if player and not spawnX then
            player:Say(Bartering.getBartererDisplayName(barterer.id) .. " is approaching")
        end
    end

    local function unloadEntry(entry, zombie)
        config.calls.persistActiveCalledInEntry(entry, zombie, true)
        config.combat.clearCombatTask(entry)
        config.combat.releaseBartererThreats(zombie)
        log(zombie, "no player in range; unloading until a player returns", "Unloaded")
        leftoverCleanupPending[entry.bartererId] = nil
        despawnZombie(zombie)
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
        end

        local readyToRespawn = lifeState.respawnAt ~= nil and worldAgeHours >= lifeState.respawnAt
        Bartering.ensureBartererIdentity(barterer.id, readyToRespawn)
        local x, y, z = Bartering.pickSpawnLocationNear(barterer, player, BarterSpawn.LOAD_DISTANCE_SQ)
        spawnBarterer(player, barterer, x, y, z, true, readyToRespawn)
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
        local now = getTimeInMillis()
        local activeCalledIn = ModData.getOrCreate(Bartering.Registries.ActiveCalledIn)

        for _, barterer in pairs(Bartering.Barterers) do
            if not hasTrackedBarterer(barterer.id)
                and not Bartering.isBartererPermanentlyDead(barterer.id)
                and not config.calls.hasPendingCall(barterer.id) then

                local returning = Bartering.getRegistryRecord(Bartering.Registries.ReturningHome, barterer.id)
                if returning and returning.arriveHomeAtMs and now >= tonumber(returning.arriveHomeAtMs) then
                    Bartering.setRegistryRecord(Bartering.Registries.ReturningHome, barterer.id, nil)
                    returning = nil
                end

                if not returning then
                    local record = activeCalledIn[barterer.id]
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

        state.barterers = {}
        config.calls.bootstrapPersistedCalls()
        config.calls.pruneActiveCalledInRecords()

        leftoverCleanupPending = {}
        for _, barterer in pairs(Bartering.Barterers) do
            Bartering.restoreBartererHome(barterer)
            leftoverCleanupPending[barterer.id] = true
        end

        state.residentsInitialized = true
        scanTicks = 0
    end

    local function resetBootstrap()
        state.barterers = {}
        state.residentsInitialized = false
        config.calls.resetState()
    end

    return {
        despawnZombie = despawnZombie,
        despawnBarterer = despawnBarterer,
        despawnBartererEntry = despawnBartererEntry,
        untrackEntry = untrackEntry,
        trackBarterer = trackBarterer,
        hasTrackedBarterer = hasTrackedBarterer,
        ownsZombie = ownsZombie,
        releaseLostEntry = releaseLostEntry,
        noteLeftover = noteLeftover,
        unloadEntry = unloadEntry,
        createBartererZombie = createBartererZombie,
        spawnBarterer = spawnBarterer,
        deprovisionBarterer = deprovisionBarterer,
        markBartererDeath = markBartererDeath,
        clearBartererDeath = clearBartererDeath,
        updateSpawns = updateSpawns,
        bootstrap = bootstrap,
        resetBootstrap = resetBootstrap,
    }
end

return BarterSpawn
