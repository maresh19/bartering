local getCell = _G["getCell"]
local ZombRand = _G["ZombRand"]
local instanceof = _G["instanceof"]
local LosUtil = _G["LosUtil"]
local InventoryItemFactory = _G["InventoryItemFactory"]
local getTimeInMillis = _G["getTimeInMillis"]
local BarteringAIUtils = require "BarteringAIUtils"

local BarteringAICombat = {}

local PISTOL_DAMAGE = 0.20
local KNIFE_DAMAGE_MULTIPLIER = 1.25
local KNIFE_START_DISTANCE = 1.75
local KNIFE_START_DISTANCE_SQ = KNIFE_START_DISTANCE * KNIFE_START_DISTANCE
local KNIFE_HIT_DISTANCE = 1.90
local KNIFE_HIT_DISTANCE_SQ = KNIFE_HIT_DISTANCE * KNIFE_HIT_DISTANCE
local THREAT_ALWAYS_NOTICED_DISTANCE_SQ = 9
local THREAT_SPRINT_DISTANCE_SQ = 64
local CALLED_IN_AGGRO_TILE_DISTANCE_SQ = 100
local BARTERER_AGGRO_LOCK_DISTANCE_SQ = 9
local BARTERER_AGGRO_SCAN_INTERVAL_TICKS = 10
local BARTERER_BITE_DISTANCE_SQ = 0.64
local BARTERER_BITE_WINDUP_TICKS = 20
local BARTERER_BITE_RESET_TICKS = 100
local BARTERER_BITE_DAMAGE = 1.01
local BARTERER_ZOMBIFY_HEALTH = 0.05
local BARTERER_ZOMBIFY_TRIGGER = 0.1
local BARTERER_BITE_WEAPON = "Base.RollingPin"
local PISTOL_AIM_MIN_TICKS = 18
local PISTOL_AIM_PER_TILE_TICKS = 5
local PISTOL_RAISE_TICKS = 10
local PISTOL_FIRE_TICKS = 14
local PISTOL_RELOAD_TICKS = 45
local PLAYER_KILL_CAUSE_TIMEOUT_MS = 15000

function BarteringAICombat.new(config)
    local state = config.state
    local getClosestNearbyPlayer = config.getClosestNearbyPlayer
    local logDebug = config.logBartererServerDebug

    local function clearCombatTask(entry)
        entry.combatTask = nil
    end

    local suppressZombieCombat = BarteringAIUtils.suppressZombieCombat

    local function equipWeapon(zombie, weapon, weaponType)
        zombie:setPrimaryHandItem(weapon)
        zombie:setVariable("BartererWeapon", weaponType)
        if weaponType == "Pistol" then
            zombie:setVariable("BartererPrimaryType", "handgun")
        elseif weaponType == "Rifle" then
            zombie:setVariable("BartererPrimaryType", "rifle")
        elseif weaponType == "Knife" then
            zombie:setVariable("BartererPrimaryType", "onehanded")
        else
            zombie:setVariable("BartererPrimaryType", "item")
        end
    end

    local function hasClearLineTo(zombie, target)
        return tostring(LosUtil.lineClear(zombie:getCell(),
            zombie:getX(), zombie:getY(), zombie:getZ(),
            target:getX(), target:getY(), target:getZ(), false)) ~= "Blocked"
    end

    local function isThreatInterestedInBarterer(threat, zombie, hostilePlayer, distanceSq)
        if threat:getTarget() == zombie then
            return true
        end

        if threat:getAttackedBy() == zombie then
            return true
        end

        local target = threat:getTarget()
        if target and instanceof(target, "IsoPlayer") and target ~= hostilePlayer then
            return true
        end

        if distanceSq <= 64 then
            return true
        end

        local action = threat:getActionStateName() or ""
        if action == "lunge" or action == "attack" or action == "face-target" then
            return true
        end

        return false
    end

    local function gunTypeFor(entry)
        return Bartering.getBartererWeapon(entry.bartererId).weaponType
    end

    local function isThreatInFront(zombie, threat)
        return not threat:isBehind(zombie)
    end

    local function findKnifeRangeThreat(zombie)
        local best, bestDist = nil, nil
        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distanceSq, _, _, sameLevel)
            if sameLevel and distanceSq <= KNIFE_START_DISTANCE_SQ
                and (not bestDist or distanceSq < bestDist) then
                best, bestDist = threat, distanceSq
            end
            return false
        end)
        return best, bestDist
    end

    local function isThreatMeleeReachable(zombie, threat)
        local from = zombie:getSquare()
        local to = threat:getSquare()
        if from == nil or to == nil then
            return false
        end
        if from == to then
            return true
        end
        return not from:isSomethingTo(to)
    end

    local function scanThreats(zombie)
        local nearest
        local inFront, behind = 0, 0
        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distance, _, _, sameLevel)
            if not nearest or distance < nearest then
                nearest = distance
            end
            if sameLevel and distance <= BarteringAIUtils.MELEE_THREAT_DISTANCE_SQ then
                if isThreatInFront(zombie, threat) then
                    inFront = inFront + 1
                else
                    behind = behind + 1
                end
            end
            return false
        end)
        return nearest, inFront, behind
    end

    local function getClosestMeleeThreat(zombie)
        local closestThreat
        local closestDistance
        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distance, _, _, sameLevel)
            if not sameLevel or distance > BarteringAIUtils.MELEE_THREAT_DISTANCE_SQ then
                return false
            end
            if closestDistance and distance >= closestDistance then
                return false
            end
            if distance <= BARTERER_BITE_DISTANCE_SQ or hasClearLineTo(zombie, threat) then
                closestThreat = threat
                closestDistance = distance
            end
            return false
        end)
        return closestThreat, closestDistance
    end

    local function getClosestThreat(zombie, hostilePlayer)
        local meleeThreat, meleeDistance = getClosestMeleeThreat(zombie)
        if meleeThreat then
            return meleeThreat, meleeDistance
        end

        local closestThreat
        local closestDistance = 144
        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distance)
            if distance >= closestDistance then
                return false
            end
            local noticed = hasClearLineTo(zombie, threat)
                and (distance <= THREAT_ALWAYS_NOTICED_DISTANCE_SQ or zombie:CanSee(threat))
            if noticed and isThreatInterestedInBarterer(threat, zombie, hostilePlayer, distance) then
                closestThreat = threat
                closestDistance = distance
            end
            return false
        end)
        return closestThreat, closestDistance
    end


    local function getHostilePlayer(entry, zombie)
        local player = entry.hostilePlayer
        if not player or player:isDead() then
            return nil
        end

        local distance = BarteringAIUtils.distanceSqBetween(player, zombie)
        if distance > 144 or not zombie:CanSee(player) then
            return nil
        end
        return player, distance
    end

    local function getRangedAimTicks(distance)
        local aimTicks = PISTOL_AIM_MIN_TICKS + math.floor(distance * PISTOL_AIM_PER_TILE_TICKS)
        if aimTicks > 60 then
            aimTicks = 60
        end
        return aimTicks
    end

    local function getRangedCooldownTicks(weapon, distance)
        local recoilDelay = weapon and weapon:getRecoilDelay() or 30
        local cooldown = recoilDelay + math.floor(distance ^ 1.1)
        if cooldown < 20 then
            cooldown = 20
        end
        return cooldown
    end

    local function playRangedShotVisuals(shooter)
        shooter:startMuzzleFlash()
        Bartering.spawnMuzzleFlashLight(shooter)
    end

    local function interruptThreatBite(entry, threat)
        if entry.biteStates and entry.biteStates[threat] then
            entry.biteStates[threat] = nil
            threat:setVariable("BumpAnimFinished", true)
            threat:setBumpType("")
        end
    end

    local function applyCombatHit(attacker, target, weapon, damage, isRanged)
        if target:isDead() then
            return
        end

        local fakeZombie = getCell():getFakeZombieForHit()
        local behind = attacker:isBehind(target)
        target:setHitFromBehind(behind)
        target:setAttackedBy(attacker)

        if instanceof(target, "IsoZombie") then
            local targetOnGround = BarteringAIUtils.isDowned(target)

            if isRanged and targetOnGround then
                local healthAfterHit = math.max(0, target:getHealth() - damage)
                target:setHealth(healthAfterHit)
                target:setHitReaction("")
                target:setHitHeadWhileOnFloor(1)
                target:setHitLegsWhileOnFloor(true)
                return
            end

            target:setHitAngle(attacker:getForwardDirection())
            target:setPlayerAttackPosition(target:testDotSide(attacker))
            target:setHitHeadWhileOnFloor(targetOnGround and 1 or 0)
            target:setHitLegsWhileOnFloor(targetOnGround)
            if isRanged then
                if targetOnGround then
                    target:setHitReaction("")
                else
                    target:setHitReaction("ShotBelly")
                end
            end

            local hitForce = (isRanged and targetOnGround) and 0 or 1
            target:Hit(weapon, fakeZombie, damage, false, hitForce, false)
            return
        end

        target:Hit(weapon, fakeZombie, damage, false, 1, false)
    end

    local function loadClipFromReserve(zombie, entry, capacity)
        local ammoItem = Bartering.getBartererWeapon(entry.bartererId).ammoItem
        local inventory = zombie:getInventory()
        local loaded = 0
        while loaded < capacity and inventory:getCountTypeRecurse(ammoItem) > 0 do
            inventory:RemoveOneOf(ammoItem)
            loaded = loaded + 1
        end
        return loaded
    end

    local function beginCombatTask(entry, zombie, weapon, weaponType)
        BarteringAIUtils.clearPathing(zombie)
        equipWeapon(zombie, weapon, weaponType)
        suppressZombieCombat(zombie)
        local equipped = zombie:getPrimaryHandItem()
        logDebug(zombie, string.format("combat start %s wanted=%s equipped=%s cooldown=%d",
            weaponType,
            tostring(weapon and weapon:getType() or "nil"),
            tostring(equipped and equipped:getType() or "none"),
            entry.attackCooldown or 0), weaponType == "Knife" and "DefendKnife" or "DefendPistol")
    end

    local function startKnifeCombatTask(entry, zombie, threat)
        beginCombatTask(entry, zombie, entry.knife, "Knife")
        entry.combatTask = {
            kind = "knife",
            target = threat,
            time = 50,
            attackTime = 20,
            hitDone = false,
            anim = "AttackKnife",
            started = false,
        }
        zombie:setVariable("BartererState", "DefendKnife")
    end

    local function startPistolCombatTask(entry, zombie, threat, actualDistance)
        beginCombatTask(entry, zombie, entry.gun, gunTypeFor(entry))
        local totalAimTicks = getRangedAimTicks(actualDistance)
        local raiseTicks = math.min(totalAimTicks, PISTOL_RAISE_TICKS)
        local recoilTime = getRangedCooldownTicks(entry.gun, actualDistance)
        local clipCapacity = entry.gun:getMaxAmmo() or 30
        entry.combatTask = {
            kind = "pistol",
            target = threat,
            phase = "raise",
            time = raiseTicks,
            aimTime = math.max(totalAimTicks - raiseTicks, 1),
            fireTime = PISTOL_FIRE_TICKS,
            recoilTime = recoilTime,
            recoilHoldTime = math.max(2, math.min(6, math.floor(recoilTime * 0.25))),
            anim = "IdleToAimPistol",
            shotDone = false,
            started = false,
            shotsFired = 0,
            clipCapacity = loadClipFromReserve(zombie, entry, clipCapacity),
        }
        zombie:setVariable("BartererState", "DefendPistol")
    end

    local function abortCombat(entry)
        clearCombatTask(entry)
        entry.attackCooldown = 20
        return false
    end

    local function finishCombatTask(entry, zombie, cooldownTicks)
        clearCombatTask(entry)
        entry.attackCooldown = cooldownTicks
        entry.combatEndedAt = getTimeInMillis()
        zombie:setVariable("BumpAnimFinished", true)
        return false
    end

    local function holdPositionFacing(zombie, targetX, targetY)
        zombie:setVariable("MovementSpeed", "1.00")
        zombie:faceLocationF(targetX, targetY)
    end

    local function maintainTaskAnim(zombie, task, anim)
        if not task.started then
            task.started = true
            zombie:setVariable("BumpAnimFinished", false)
            zombie:setBumpType(anim)
        end
        if zombie:getBumpType() ~= anim then
            zombie:setBumpType(anim)
        end
    end

    local function advanceTaskPhase(task, phase, time)
        task.phase = phase
        task.time = time
        task.started = false
        task.anim = "AimPistol"
    end

    local function processCombatTask(entry, zombie)
        local task = entry.combatTask
        if not task then
            return false
        end

        local target = task.target
        if not target or target:isDead() then
            clearCombatTask(entry)
            return false
        end

        if BarteringAIUtils.isDowned(zombie) then
            return abortCombat(entry)
        end

        if BarteringAIUtils.STAGGER_ACTION_STATES[zombie:getActionStateName()] then
            if task.kind == "knife" and not task.hitDone then
                task.started = false
                return false
            end
            return abortCombat(entry)
        end

        if task.kind == "pistol" then
            local meleeThreat, pDistSq = findKnifeRangeThreat(zombie)
            if meleeThreat
                and isThreatInFront(zombie, meleeThreat)
                and isThreatMeleeReachable(zombie, meleeThreat) then
                zombie:setVariable("BumpAnimFinished", true)
                zombie:setBumpType("")
                clearCombatTask(entry)
                entry.attackCooldown = 0
                logDebug(zombie, string.format("target closed to knife range distSq=%.2f; dropping gun task", pDistSq), "DefendKnife")
                return false
            end
        end

        suppressZombieCombat(zombie)
        holdPositionFacing(zombie, target:getX(), target:getY())

        if task.kind == "knife" then
            zombie:setVariable("BartererState", "DefendKnife")
            maintainTaskAnim(zombie, task, task.anim)

            task.time = task.time - 1
            if not task.hitDone and task.time <= task.attackTime then
                local targetDx = target:getX() - zombie:getX()
                local targetDy = target:getY() - zombie:getY()
                local targetDistSq = targetDx * targetDx + targetDy * targetDy
                if targetDistSq <= KNIFE_HIT_DISTANCE_SQ then
                    task.hitDone = true
                    local knifeDamage = entry.knife:getMaxDamage() * KNIFE_DAMAGE_MULTIPLIER
                    local hpBefore = target:getHealth()
                    applyCombatHit(zombie, target, entry.knife, knifeDamage, false)
                    interruptThreatBite(entry, target)
                    logDebug(zombie, string.format("knife HIT dist=%.2f dmg=%.2f weapon=%s hp %.2f->%.2f",
                        math.sqrt(targetDistSq), knifeDamage,
                        tostring(entry.knife:getType()),
                        hpBefore, target:getHealth()), "DefendKnife")
                elseif not task.loggedMiss then
                    task.loggedMiss = true
                    logDebug(zombie, string.format("knife OUT OF RANGE dist=%.2f need=%.2f",
                        math.sqrt(targetDistSq), KNIFE_HIT_DISTANCE), "DefendKnife")
                end
            end

            if task.time <= 0 then
                return finishCombatTask(entry, zombie, 20)
            end

            return true
        end

        zombie:setVariable("BartererState", "DefendPistol")
        if zombie:getPrimaryHandItem() ~= entry.gun then
            equipWeapon(zombie, entry.gun, gunTypeFor(entry))
        end
        if task.phase == "raise" then
            maintainTaskAnim(zombie, task, task.anim)

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "aim", task.aimTime)
            end

            return true
        end

        if task.phase == "aim" then
            maintainTaskAnim(zombie, task, "AimPistol")

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "fire", task.fireTime)
                task.shotDone = false
            end

            return true
        end

        if task.phase == "fire" then
            maintainTaskAnim(zombie, task, "AimPistol")

            task.time = task.time - 1
            if not task.shotDone and task.time <= math.floor(task.fireTime / 2) then
                if not hasClearLineTo(zombie, target) then
                    return finishCombatTask(entry, zombie, 10)
                end

                task.shotDone = true
                zombie:setBumpType("AimPistol")
                local emitter = zombie:getEmitter()
                emitter:playSound(entry.gun:getSwingSound())
                entry.soundCooldown = (entry.soundCooldown or 0) - 1
                if entry.soundCooldown <= 0 then
                    addSound(zombie,
                        math.floor(zombie:getX()),
                        math.floor(zombie:getY()),
                        math.floor(zombie:getZ()),
                        entry.gun:getSoundRadius(),
                        entry.gun:getSoundVolume())
                    entry.soundCooldown = 5
                end
                playRangedShotVisuals(zombie)
                zombie:setVariable("BartererMuzzleFlashAt", tostring(getTimeInMillis()))
                for p = 1, entry.projectileCount or 1 do
                    if ZombRand(100) < 75 then
                        applyCombatHit(zombie, target, entry.gun, PISTOL_DAMAGE, true)
                        interruptThreatBite(entry, target)
                    end
                end
                task.shotsFired = task.shotsFired + 1
            end

            if task.time <= 0 then
                advanceTaskPhase(task, "recover_fire", math.max(1, task.recoilHoldTime))
            end

            return true
        end

        if task.phase == "recover_fire" then
            maintainTaskAnim(zombie, task, "AimPistol")

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "recover_aim", math.max(1, task.recoilTime - task.recoilHoldTime))
            end

            return true
        end

        if task.phase == "recover_aim" then
            maintainTaskAnim(zombie, task, "AimPistol")

            task.time = task.time - 1
            if task.time <= 0 then
                if not target:isDead() then
                    if task.shotsFired >= task.clipCapacity then
                        advanceTaskPhase(task, "reload", PISTOL_RELOAD_TICKS)
                        task.started = false
                        return true
                    end
                    advanceTaskPhase(task, "aim", math.max(math.floor(task.aimTime * 0.5), 4))
                    task.shotDone = false
                    return true
                end

                return finishCombatTask(entry, zombie, math.max(math.floor(task.recoilTime * 0.5), 8))
            end

            return true
        end

        if task.phase == "reload" then
            maintainTaskAnim(zombie, task, "AimPistol")

            task.time = task.time - 1
            if task.time <= 0 then
                task.clipCapacity = loadClipFromReserve(zombie, entry, entry.gun:getMaxAmmo() or 30)
                task.shotsFired = 0
                task.shotDone = false
                if task.clipCapacity <= 0 then
                    logDebug(zombie, "out of ammo; holstering gun", "Defend")
                    return finishCombatTask(entry, zombie, PISTOL_RELOAD_TICKS)
                end
                if not target:isDead() then
                    advanceTaskPhase(task, "aim", math.max(math.floor(task.aimTime * 0.5), 4))
                    return true
                end
                return finishCombatTask(entry, zombie, math.max(math.floor(task.recoilTime * 0.5), 8))
            end

            return true
        end

        return true
    end

    local function defend(entry, zombie, threat, distance)
        if BarteringAIUtils.isDowned(zombie) then
            return abortCombat(entry)
        end

        local staggered = BarteringAIUtils.STAGGER_ACTION_STATES[zombie:getActionStateName()] == true
        local inKnifeReach = distance <= KNIFE_START_DISTANCE_SQ and isThreatInFront(zombie, threat)
        local knifeRange = inKnifeReach and isThreatMeleeReachable(zombie, threat)
        if inKnifeReach and not knifeRange and not entry.loggedKnifeBlocked then
            entry.loggedKnifeBlocked = true
            logDebug(zombie, string.format("knife blocked by obstruction distSq=%.2f", distance), "Defend")
        elseif knifeRange then
            entry.loggedKnifeBlocked = nil
        end

        if entry.combatTask then
            local activeTask = entry.combatTask
            local committed = false
            if activeTask.kind == "knife" and not activeTask.hitDone
                and activeTask.target and not activeTask.target:isDead() then
                local tdx = activeTask.target:getX() - zombie:getX()
                local tdy = activeTask.target:getY() - zombie:getY()
                committed = (tdx * tdx + tdy * tdy) <= KNIFE_HIT_DISTANCE_SQ
            end

            if activeTask.target ~= threat and not committed then
                clearCombatTask(entry)
            elseif activeTask.kind == "pistol" and knifeRange then
                zombie:setVariable("BumpAnimFinished", true)
                zombie:setBumpType("")
                clearCombatTask(entry)
                entry.attackCooldown = 0
                logDebug(zombie, "switching pistol to knife at contact range", "DefendKnife")
            else
                return processCombatTask(entry, zombie)
            end
        end

        if entry.attackCooldown > 0 then
            entry.attackCooldown = entry.attackCooldown - 1
            entry.cooldownLogTicks = (entry.cooldownLogTicks or 0) - 1
            if entry.cooldownLogTicks <= 0 then
                entry.cooldownLogTicks = 20
                logDebug(zombie, string.format("holding fire, attackCooldown=%d distSq=%.2f",
                    entry.attackCooldown, distance), "Defend")
            end
            return
        end

        if staggered then
            return
        end

        holdPositionFacing(zombie, threat:getX(), threat:getY())

        if knifeRange then
            startKnifeCombatTask(entry, zombie, threat)
        else
            startPistolCombatTask(entry, zombie, threat, math.sqrt(distance))
        end

        return processCombatTask(entry, zombie)
    end


    local toothlessThreats = {}

    local function releaseBartererThreats(bartererZombie)
        for threat, owner in pairs(toothlessThreats) do
            if owner == bartererZombie or threat:isDead() then
                threat:setNoTeeth(false)
                if threat:getTarget() == owner then
                    threat:setTarget(nil)
                    threat:setTargetSeenTime(0)
                end
                if threat:getAttackedBy() == owner then
                    threat:setAttackedBy(nil)
                end
                threat:clearAggroList()
                toothlessThreats[threat] = nil
            end
        end
    end

    local function releaseThreatsTargetingBarterer(bartererZombie)
        local released = 0
        BarteringAIUtils.forEachThreatZombie(bartererZombie, function(threat)
            local cleared = false
            if threat:getTarget() == bartererZombie then
                threat:setTarget(nil)
                threat:setTargetSeenTime(0)
                cleared = true
            end
            if threat:getAttackedBy() == bartererZombie then
                threat:setAttackedBy(nil)
                cleared = true
            end
            if threat:getThumpTarget() == bartererZombie then
                threat:setThumpTarget(nil)
                threat:setTimeThumping(0)
                cleared = true
            end
            if cleared then
                threat:clearAggroList()
                released = released + 1
            end
            return false
        end)
        return released
    end

    local function updateZombieTargetPriorityForBarterer(bartererZombie)
        BarteringAIUtils.forEachThreatZombie(bartererZombie, function(threat, distanceSq, _, _, sameLevel)
            if not sameLevel then
                return false
            end

            local currentTarget = threat:getTarget()
            if distanceSq <= CALLED_IN_AGGRO_TILE_DISTANCE_SQ
                and isThreatMeleeReachable(threat, bartererZombie) then
                if not getClosestNearbyPlayer(threat, 4) then
                    if distanceSq <= BARTERER_AGGRO_LOCK_DISTANCE_SQ then
                        threat:spotted(bartererZombie, true)
                        threat:setTarget(bartererZombie)
                        threat:setAttackedBy(bartererZombie)
                    elseif threat:CanSee(bartererZombie) then
                        if currentTarget ~= bartererZombie then
                            threat:setTarget(bartererZombie)
                        end
                        threat:pathToCharacter(bartererZombie)
                    end
                end
            elseif currentTarget == bartererZombie then
                local nearbyPlayer = getClosestNearbyPlayer(threat, 400)
                threat:setTarget(nearbyPlayer)
            end

            currentTarget = threat:getTarget()
            if currentTarget and instanceof(currentTarget, "IsoZombie") and currentTarget:getVariableBoolean("Barterer") then
                toothlessThreats[threat] = currentTarget
                threat:setNoTeeth(true)
            elseif toothlessThreats[threat] then
                toothlessThreats[threat] = nil
                threat:setNoTeeth(false)
            end
            return false
        end)

        for threat in pairs(toothlessThreats) do
            if threat:isDead() then
                toothlessThreats[threat] = nil
            end
        end
    end

    local function applySimulatedZombieBite(threat, barterer)
        local teeth = InventoryItemFactory.CreateItem(BARTERER_BITE_WEAPON)
        if ZombRand(4) == 1 then
            threat:playSound("ZombieBite")
        else
            threat:playSound("ZombieScratch")
        end

        barterer:setHitFromBehind(threat:isBehind(barterer))
        barterer:setHitAngle(threat:getForwardDirection())
        barterer:setPlayerAttackPosition(barterer:testDotSide(threat))
        barterer:setHitReaction("")
        barterer:Hit(teeth, threat, math.min(BARTERER_BITE_DAMAGE, barterer:getHealth() - BARTERER_ZOMBIFY_HEALTH), false, 1, false)
        Bartering.clearEngineTarget(barterer)
    end

    local function updateZombieBitesOnBarterer(entry, barterer)
        entry.biteStates = entry.biteStates or {}
        local states = entry.biteStates

        BarteringAIUtils.forEachThreatZombie(barterer, function(threat, distanceSq, _, _, sameLevel)
            if not sameLevel then
                return false
            end

            local state = states[threat]
            if distanceSq <= BARTERER_BITE_DISTANCE_SQ then
                threat:faceThisObject(barterer)
                local biteAnim = barterer:isProne() and "BiteLow" or "Bite"
                local bump = threat:getBumpType()
                local biting = bump == "Bite" or bump == "BiteLow"
                if not state then
                    if not biting then
                        threat:setVariable("BumpAnimFinished", false)
                        threat:setBumpType(biteAnim)
                        states[threat] = { tick = 0 }
                    end
                else
                    state.tick = state.tick + 1
                    if not biting then
                        threat:setBumpType(biteAnim)
                    end
                    if state.tick == BARTERER_BITE_WINDUP_TICKS then
                        applySimulatedZombieBite(threat, barterer)
                        entry.retreatForced = true
                        clearCombatTask(entry)
                    elseif state.tick >= BARTERER_BITE_RESET_TICKS then
                        threat:setVariable("BumpAnimFinished", true)
                        states[threat] = nil
                    end
                end
            elseif state then
                threat:setVariable("BumpAnimFinished", true)
                states[threat] = nil
            end
            return false
        end)
    end

    local function resetBiteStates(entry)
        entry.biteStates = nil
    end

    local function getDeathCause(entry)
        if entry.lastPlayerAttackAt and getTimeInMillis() - entry.lastPlayerAttackAt <= PLAYER_KILL_CAUSE_TIMEOUT_MS then
            return "player"
        end
        return "zombie"
    end

    local function attackedBy(player, args)
        local hitId = args and args.id
        if not hitId or hitId == "" then
            return
        end

        local entry = BarteringAIUtils.findBartererEntry(state.barterers, hitId)
        if entry then
            entry.hostilePlayer = player
            entry.attackCooldown = 0
            entry.lastPlayerAttackAt = getTimeInMillis()
        end
    end

    local function shovedBy(player, args)
        local hitId = args and args.id
        if not hitId or hitId == "" then
            return
        end

        for _, entry in ipairs(state.barterers) do
            if entry.bartererId == hitId then
                entry.hostilePlayer = player
                entry.attackCooldown = 0
                entry.lastPlayerAttackAt = getTimeInMillis()
                if ZombRand(100) < 5 then
                    local zombie = entry.zombie
                    zombie:setStaggerBack(true)
                    zombie:setKnockedDown(true)
                    logDebug(zombie, "shoved by player - knocked down", "Shove")
                end
                return
            end
        end
    end

    return {
        clearCombatTask = clearCombatTask,
        getClosestThreat = getClosestThreat,
        scanThreats = scanThreats,
        getHostilePlayer = getHostilePlayer,
        processCombatTask = processCombatTask,
        defend = defend,
        equipWeapon = equipWeapon,
        releaseBartererThreats = releaseBartererThreats,
        releaseThreatsTargetingBarterer = releaseThreatsTargetingBarterer,
        updateZombieTargetPriorityForBarterer = updateZombieTargetPriorityForBarterer,
        updateZombieBitesOnBarterer = updateZombieBitesOnBarterer,
        resetBiteStates = resetBiteStates,
        getDeathCause = getDeathCause,
        attackedBy = attackedBy,
        shovedBy = shovedBy,
        THREAT_SPRINT_DISTANCE_SQ = THREAT_SPRINT_DISTANCE_SQ,
        BARTERER_AGGRO_SCAN_INTERVAL_TICKS = BARTERER_AGGRO_SCAN_INTERVAL_TICKS,
        BARTERER_ZOMBIFY_HEALTH = BARTERER_ZOMBIFY_HEALTH,
        BARTERER_ZOMBIFY_TRIGGER = BARTERER_ZOMBIFY_TRIGGER,
    }
end

return BarteringAICombat
