local getCell = _G["getCell"]
local ZombRand = _G["ZombRand"]
local instanceof = _G["instanceof"]
local LosUtil = _G["LosUtil"]
local instanceItem = _G["instanceItem"]
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringTasks = require "Movement/BarteringTasks"
local BarteringFollow = require "Movement/BarteringFollow"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringTiming = require "BarteringTiming"

local BarteringAICombat = {}

local PISTOL_DAMAGE = 0.20
local KNIFE_DAMAGE_MULTIPLIER = 1.25
local LOW_AIM_DISTANCE_SQ = 2.5 * 2.5
local PISTOL_RELOAD_ANIM_MS = 1500
local RIFLE_RELOAD_ANIM_MS = 1733
local PISTOL_RACK_ANIM_MS = 1333
local RIFLE_RACK_ANIM_MS = 1767
local ANIM_BLEND_MS = 200
local SHOT_ANIM_MS = 333
local THREAT_ALWAYS_NOTICED_DISTANCE_SQ = 9
local THREAT_SPRINT_DISTANCE_SQ = 64
local THREAT_ENGAGE_DISTANCE_SQ = 144
local CALLED_IN_AGGRO_TILE_DISTANCE_SQ = 100
local BARTERER_AGGRO_LOCK_DISTANCE_SQ = 9
local BARTERER_AGGRO_SCAN_INTERVAL_TICKS = 10
local BARTERER_BITE_DISTANCE_SQ = 0.64
local BARTERER_BITE_WINDUP_TICKS = 20
local BARTERER_BITE_RESET_TICKS = 100
local BARTERER_BITE_DAMAGE = 1.01
local BARTERER_ZOMBIFY_HEALTH = 0.05
local BARTERER_BITE_WEAPON = "Base.RollingPin"
local PISTOL_AIM_MIN_TICKS = 18
local PISTOL_AIM_PER_TILE_TICKS = 5
local PISTOL_RAISE_TICKS = 10
local PISTOL_FIRE_TICKS = 14
local PISTOL_RELOAD_TICKS = 45

function BarteringAICombat.hitZombie(attacker, target, weapon, damage, isRanged)
    local fakeZombie = getCell():getFakeZombieForHit()
    target:setHitFromBehind(attacker:isBehind(target))
    target:setAttackedBy(attacker)

    local targetOnGround = BarteringAIUtils.isDowned(target)

    if BarteringAIUtils.isKnockedOver(target) and (isRanged or not targetOnGround) then
        target:setHealth(math.max(0, target:getHealth() - damage))
        target:setHitReaction("")
        target:setHitHeadWhileOnFloor(1)
        target:setHitLegsWhileOnFloor(true)
        return
    end

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
end

function BarteringAICombat.hitPlayer(attacker, target, weapon, damage)
    target:setHitFromBehind(attacker:isBehind(target))
    target:setAttackedBy(attacker)
    target:Hit(weapon, getCell():getFakeZombieForHit(), damage, false, 1, false)
end

function BarteringAICombat.new(config)
    local state = config.state
    local getClosestNearbyPlayer = config.getClosestNearbyPlayer
    local logDebug = config.logBartererServerDebug

    local function clearCombatTask(entry)
        entry.combatTask = nil
    end

    local suppressZombieCombat = BarteringAIUtils.suppressZombieCombat

    local function equipWeapon(zombie, weapon, weaponType)
        local held = zombie:getPrimaryHandItem()
        if not held or held:getFullType() ~= weapon:getFullType() then
            if held then
                Bartering.playBartererSound(zombie, held:getUnequipSound())
            end
            Bartering.playBartererSound(zombie, weapon:getEquipSound())
        end
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
        if BarteringAIUtils.isBartererZombie(threat) then
            return true
        end

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

        if distanceSq <= THREAT_ALWAYS_NOTICED_DISTANCE_SQ then
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

    local function findKnifeRangeThreat(zombie, knife)
        local best, bestDist = nil, nil
        local rangeSq = knife:getMaxRange() * knife:getMaxRange()
        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distanceSq, _, _, sameLevel)
            if sameLevel and distanceSq <= rangeSq
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
            if sameLevel and distance <= BarteringAIUtils.MELEE_THREAT_DISTANCE_SQ
                and hasClearLineTo(zombie, threat) then
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
            BarteringPathTrace.counter(zombie, "threat.engaged.melee")
            return meleeThreat, meleeDistance
        end

        local closestThreat
        local closestDistance = THREAT_ENGAGE_DISTANCE_SQ
        local rejectReason, rejectDistance
        local function reject(reason, distance)
            if not rejectDistance or distance < rejectDistance then
                rejectDistance = distance
                rejectReason = reason
            end
        end

        BarteringAIUtils.forEachThreatZombie(zombie, function(threat, distance)
            if distance >= closestDistance then
                return false
            end
            if not hasClearLineTo(zombie, threat) then
                reject("noLineOfSight", distance)
                return false
            end
            if distance > THREAT_ALWAYS_NOTICED_DISTANCE_SQ and not zombie:CanSee(threat) then
                reject("cannotSee", distance)
                return false
            end
            if not isThreatInterestedInBarterer(threat, zombie, hostilePlayer, distance) then
                reject("notInterested", distance)
                return false
            end
            closestThreat = threat
            closestDistance = distance
            return false
        end)

        if closestThreat then
            BarteringPathTrace.counter(zombie, "threat.engaged")
        elseif rejectReason then
            BarteringPathTrace.counter(zombie, "threat.rejected." .. rejectReason)
        end

        return closestThreat, closestDistance
    end


    local function getHostilePlayer(entry, zombie)
        local player = entry.hostilePlayer
        if player and not player:isDead() then
            local distance = BarteringAIUtils.distanceSqBetween(player, zombie)
            if distance <= THREAT_ENGAGE_DISTANCE_SQ and zombie:CanSee(player) then
                return player, distance
            end
        end

        local hostility = Bartering.getHostilityTable(entry.bartererId)
        local amendsPlayer = Bartering.getAmendsTable(entry.bartererId).player
        local closest, closestDistance
        BarteringAIUtils.forEachPlayer(function(candidate)
            if hostility[candidate:getUsername()] and candidate:getUsername() ~= amendsPlayer then
                local distance = BarteringAIUtils.distanceSqBetween(candidate, zombie)
                if distance <= THREAT_ENGAGE_DISTANCE_SQ and zombie:CanSee(candidate)
                    and (not closestDistance or distance < closestDistance) then
                    closest = candidate
                    closestDistance = distance
                end
            end
        end)
        return closest, closestDistance
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

        if instanceof(target, "IsoZombie") then
            if isClient() and target:isRemoteZombie() then
                config.relayZombieHit(attacker, target, weapon, damage, isRanged)
                return
            end
            BarteringAICombat.hitZombie(attacker, target, weapon, damage, isRanged)
            return
        end

        if isClient() then
            config.relayPlayerHit(attacker, target, weapon, damage, isRanged)
            return
        end
        BarteringAICombat.hitPlayer(attacker, target, weapon, damage)
    end

    local function loadClipFromReserve(zombie, entry, capacity)
        local loaded = math.max(0, math.min(capacity, entry.ammoReserve))
        entry.ammoReserve = entry.ammoReserve - loaded
        return loaded
    end

    local function hasReserveAmmo(entry, zombie)
        return entry.ammoReserve > 0
    end

    local function emptyGunPhase(entry)
        if entry.gunMagOut or not entry.gun:getMagazineType() then
            return "reload"
        end
        return "unload"
    end

    local function dropMagazine(entry, zombie)
        config.report(entry, "dropMagazine", {
            item = entry.gun:getMagazineType(),
            x = zombie:getX(),
            y = zombie:getY(),
            z = zombie:getZ(),
        })
    end

    local function beginCombatTask(entry, zombie, weapon, weaponType)
        BarteringAIUtils.clearGoal(zombie, "combat")
        BarteringTasks.StopMovement(zombie)
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
        Bartering.playBartererSound(zombie, entry.knife:getSwingSound())
        Bartering.playBartererSound(zombie, zombie:isFemale() and "VoiceFemaleMeleeAttack" or "VoiceMaleMeleeAttack")
        local targetAction = threat:getActionStateName()
        local targetDown = threat:isProne() or targetAction == "onground" or targetAction == "sitonground"
            or targetAction == "climbfence"
        entry.combatTask = {
            kind = "knife",
            target = threat,
            time = 50,
            attackTime = 20,
            hitDone = false,
            anim = targetDown and "AttackKnifeFloor" or "AttackKnife",
            started = false,
        }
        zombie:setVariable("BartererState", "DefendKnife")
    end

    local function startPistolCombatTask(entry, zombie, threat, actualDistance)
        beginCombatTask(entry, zombie, entry.gun, gunTypeFor(entry))
        local totalAimTicks = getRangedAimTicks(actualDistance)
        local raiseTicks = math.min(totalAimTicks, PISTOL_RAISE_TICKS)
        local recoilTime = getRangedCooldownTicks(entry.gun, actualDistance)
        local loaded = entry.gun:getCurrentAmmoCount() > 0
        entry.combatTask = {
            kind = "pistol",
            target = threat,
            phase = entry.gunNeedsRack and "rack" or (loaded and "raise" or emptyGunPhase(entry)),
            time = loaded and raiseTicks or PISTOL_RELOAD_TICKS,
            aimTime = math.max(totalAimTicks - raiseTicks, 1),
            fireTime = PISTOL_FIRE_TICKS,
            recoilTime = recoilTime,
            recoilHoldTime = math.max(2, math.min(6, math.floor(recoilTime * 0.25))),
            anim = "IdleToAimPistol",
            shotDone = false,
            started = false,
        }
        zombie:setVariable("BartererState", "DefendPistol")
        logDebug(zombie, string.format("gun task start phase=%s gun=%s loaded=%d reserve=%d magOut=%s needsRack=%s",
            entry.combatTask.phase, tostring(entry.gun), entry.gun:getCurrentAmmoCount(), entry.ammoReserve,
            tostring(entry.gunMagOut), tostring(entry.gunNeedsRack)), "DefendPistol")
    end

    local function abortCombat(entry)
        clearCombatTask(entry)
        entry.attackCooldown = 20
        return false
    end

    local function finishCombatTask(entry, zombie, cooldownTicks)
        clearCombatTask(entry)
        entry.attackCooldown = cooldownTicks
        entry.combatEndedAt = BarteringTiming.now()
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
        task.phaseAnimAtMs = nil
        task.anim = "AimPistol"
    end

    local function processCombatTask(entry, zombie)
        local task = entry.combatTask
        if not task then
            return false
        end

        local target = task.target
        if not target or target:isDead()
            or (instanceof(target, "IsoZombie") and BarteringAIUtils.isBartererZombie(target)) then
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
            local meleeThreat, pDistSq = findKnifeRangeThreat(zombie, entry.knife)
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
                if targetDistSq <= entry.knife:getMaxRange() * entry.knife:getMaxRange() then
                    task.hitDone = true
                    local knifeDamage = entry.knife:getMaxDamage() * KNIFE_DAMAGE_MULTIPLIER
                    local hpBefore = target:getHealth()
                    applyCombatHit(zombie, target, entry.knife, knifeDamage, false)
                    Bartering.playBartererSound(zombie, entry.knife:getZombieHitSound())
                    interruptThreatBite(entry, target)
                    logDebug(zombie, string.format("knife HIT dist=%.2f dmg=%.2f weapon=%s hp %.2f->%.2f",
                        math.sqrt(targetDistSq), knifeDamage,
                        tostring(entry.knife:getType()),
                        hpBefore, target:getHealth()), "DefendKnife")
                elseif not task.loggedMiss then
                    task.loggedMiss = true
                    logDebug(zombie, string.format("knife OUT OF RANGE dist=%.2f need=%.2f",
                        math.sqrt(targetDistSq), entry.knife:getMaxRange()), "DefendKnife")
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
        local targetAction = target:getActionStateName()
        local targetDown = target:isProne() or targetAction == "onground" or targetAction == "sitonground"
            or targetAction == "getup"
        local aimAnim = (targetDown and BarteringAIUtils.distanceSqBetween(zombie, target) < LOW_AIM_DISTANCE_SQ)
            and "AimPistolLow" or "AimPistol"
        local shotAnim = aimAnim == "AimPistolLow" and "AttackPistolLow" or "AttackPistol"
        local recoilAnim = (task.shotAtMs and not BarteringTiming.hasElapsed(task.shotAtMs, SHOT_ANIM_MS))
            and shotAnim or aimAnim

        if task.phase == "raise" then
            if not task.started then
                Bartering.playBartererSound(zombie, entry.gun:getBringToBearSound())
            end
            maintainTaskAnim(zombie, task, task.anim)

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "aim", task.aimTime)
            end

            return true
        end

        if task.phase == "aim" then
            maintainTaskAnim(zombie, task, aimAnim)

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "fire", task.fireTime)
                task.shotDone = false
            end

            return true
        end

        if task.phase == "fire" then
            maintainTaskAnim(zombie, task, recoilAnim)

            task.time = task.time - 1
            if not task.shotDone and task.time <= math.floor(task.fireTime / 2) then
                if not hasClearLineTo(zombie, target) then
                    return finishCombatTask(entry, zombie, 10)
                end

                task.shotDone = true
                task.shotAtMs = BarteringTiming.now()
                zombie:setBumpType(shotAnim)
                Bartering.playBartererShot(entry.bartererId, zombie, entry.gun:getSwingSound())
                if not entry.gun:isManuallyRemoveSpentRounds() then
                    Bartering.playBartererSound(zombie, entry.gun:getShellFallSound())
                end
                entry.soundCooldown = (entry.soundCooldown or 0) - 1
                if entry.soundCooldown <= 0 then
                    addSound(zombie,
                        math.floor(zombie:getX()),
                        math.floor(zombie:getY()),
                        math.floor(zombie:getZ()),
                        entry.gun:getSoundRadius(),
                        entry.gun:getSoundVolume())
                    Bartering.logBartererSound(zombie, "worldNoise", "gunshot", string.format("radius=%d volume=%d",
                        entry.gun:getSoundRadius(), entry.gun:getSoundVolume()))
                    entry.soundCooldown = 5
                end
                for p = 1, entry.projectileCount or 1 do
                    if ZombRand(100) < 75 then
                        applyCombatHit(zombie, target, entry.gun, PISTOL_DAMAGE, true)
                        interruptThreatBite(entry, target)
                    end
                end
                entry.gun:setCurrentAmmoCount(entry.gun:getCurrentAmmoCount() - 1)
            end

            if task.time <= 0 then
                advanceTaskPhase(task, "recover_fire", math.max(1, task.recoilHoldTime))
            end

            return true
        end

        if task.phase == "recover_fire" then
            maintainTaskAnim(zombie, task, recoilAnim)

            task.time = task.time - 1
            if task.time <= 0 then
                advanceTaskPhase(task, "recover_aim", math.max(1, task.recoilTime - task.recoilHoldTime))
            end

            return true
        end

        if task.phase == "recover_aim" then
            maintainTaskAnim(zombie, task, recoilAnim)

            task.time = task.time - 1
            if task.time <= 0 then
                if not target:isDead() then
                    if entry.gun:getCurrentAmmoCount() <= 0 then
                        if not hasReserveAmmo(entry, zombie) then
                            logDebug(zombie, "out of ammo; holstering gun", "Defend")
                            return finishCombatTask(entry, zombie, PISTOL_RELOAD_TICKS)
                        end
                        advanceTaskPhase(task, emptyGunPhase(entry), 0)
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

        if task.phase == "unload" then
            logDebug(zombie, string.format("unload: dropping magazine ammo=%d reserve=%d action=%s",
                entry.gun:getCurrentAmmoCount(), entry.ammoReserve, zombie:getActionStateName()), "DefendPistol")
            Bartering.playBartererSound(zombie, entry.gun:getEjectAmmoSound())
            entry.gunMagOut = true
            dropMagazine(entry, zombie)
            advanceTaskPhase(task, "reload", 0)
            return true
        end

        if task.phase == "reload" then
            local pistol = gunTypeFor(entry) == "Pistol"
            maintainTaskAnim(zombie, task, pistol and "ReloadPistol" or "ReloadRifle")
            if not task.phaseAnimAtMs and zombie:getActionStateName() == "bumped" then
                task.phaseAnimAtMs = BarteringTiming.now()
                Bartering.playBartererSound(zombie, entry.gun:getInsertAmmoSound())
            end

            if task.phaseAnimAtMs and BarteringTiming.hasElapsed(task.phaseAnimAtMs,
                    (pistol and PISTOL_RELOAD_ANIM_MS or RIFLE_RELOAD_ANIM_MS) - ANIM_BLEND_MS) then
                entry.gun:setCurrentAmmoCount(loadClipFromReserve(zombie, entry, entry.gun:getMaxAmmo()))
                entry.gunMagOut = nil
                task.shotDone = false
                if entry.gun:getCurrentAmmoCount() <= 0 then
                    logDebug(zombie, "out of ammo; holstering gun", "Defend")
                    return finishCombatTask(entry, zombie, PISTOL_RELOAD_TICKS)
                end
                entry.gunNeedsRack = true
                advanceTaskPhase(task, "rack", 0)
            end

            return true
        end

        if task.phase == "rack" then
            local pistol = gunTypeFor(entry) == "Pistol"
            maintainTaskAnim(zombie, task, pistol and "RackPistol" or "RackRifle")
            if not task.phaseAnimAtMs and zombie:getActionStateName() == "bumped" then
                task.phaseAnimAtMs = BarteringTiming.now()
                Bartering.playBartererSound(zombie, entry.gun:getRackSound())
            end

            if task.phaseAnimAtMs and BarteringTiming.hasElapsed(task.phaseAnimAtMs,
                    (pistol and PISTOL_RACK_ANIM_MS or RIFLE_RACK_ANIM_MS) - ANIM_BLEND_MS) then
                entry.gunNeedsRack = nil
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
        local knifeRangeSq = entry.knife:getMaxRange() * entry.knife:getMaxRange()
        local inKnifeReach = distance <= knifeRangeSq and isThreatInFront(zombie, threat)
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
                committed = (tdx * tdx + tdy * tdy) <= knifeRangeSq
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

        suppressZombieCombat(zombie)

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

        entry.chasingThreat = nil
        if knifeRange then
            startKnifeCombatTask(entry, zombie, threat)
        elseif entry.gun:getCurrentAmmoCount() > 0 or hasReserveAmmo(entry, zombie) then
            startPistolCombatTask(entry, zombie, threat, math.sqrt(distance))
        elseif instanceof(threat, "IsoPlayer") then
            entry.chasingThreat = true
            BarteringFollow.pullToMaster(entry, zombie, threat, BarteringFollow.CHASE_SPRINT_MOVEMENT_SPEED)
            return
        else
            return
        end

        return processCombatTask(entry, zombie)
    end


    local toothlessThreats = {}

    local function endThreatBite(threat)
        local bump = threat:getBumpType()
        if bump == "Bite" or bump == "BiteLow" then
            threat:setVariable("BumpAnimFinished", true)
            threat:setBumpType("")
        end
    end

    local function releaseBartererThreats(bartererZombie)
        for threat, owner in pairs(toothlessThreats) do
            if owner == bartererZombie or threat:isDead() then
                endThreatBite(threat)
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

    local function updateZombieTargetPriorityForBarterer(bartererZombie)
        BarteringAIUtils.forEachThreatZombie(bartererZombie, function(threat, distanceSq, _, _, sameLevel)
            if not sameLevel or BarteringAIUtils.isBartererZombie(threat) then
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
                        BarteringPathTrace.counter(bartererZombie, "threat.pathToCharacter")
                        threat:pathToLocationF(bartererZombie:getX(), bartererZombie:getY(), bartererZombie:getZ())
                    end
                end
            elseif currentTarget == bartererZombie then
                local nearbyPlayer = getClosestNearbyPlayer(threat, 400)
                threat:setTarget(nearbyPlayer)
            end

            currentTarget = threat:getTarget()
            if currentTarget and instanceof(currentTarget, "IsoZombie") and BarteringAIUtils.isBartererZombie(currentTarget) then
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
        local teeth = instanceItem(BARTERER_BITE_WEAPON)
        local bite = ZombRand(4) == 1
        if bite then
            threat:playSound("ZombieBite")
        else
            threat:playSound("ZombieScratch")
        end
        if ZombRand(2) == 0 then
            Bartering.playBartererSound(barterer, (barterer:isFemale() and "VoiceFemale" or "VoiceMale")
                .. (bite and "PainFromBite" or "PainFromScratch"))
        end

        barterer:setHitFromBehind(threat:isBehind(barterer))
        barterer:setPlayerAttackPosition(barterer:testDotSide(threat))
        barterer:setHitReaction("")
        local healthBefore = barterer:getHealth()
        local lethal = healthBefore - BARTERER_BITE_DAMAGE <= BARTERER_ZOMBIFY_HEALTH
        barterer:Hit(teeth, threat, math.min(BARTERER_BITE_DAMAGE, healthBefore - BARTERER_ZOMBIFY_HEALTH), false, 1, false)
        Bartering.clearEngineTarget(barterer)
        logDebug(barterer, string.format("bitten hp %.3f->%.3f lethal=%s",
            healthBefore, barterer:getHealth(), tostring(lethal)), "Bitten")
        return lethal
    end

    local function updateZombieBitesOnBarterer(entry, barterer)
        entry.biteStates = entry.biteStates or {}
        local states = entry.biteStates

        BarteringAIUtils.forEachThreatZombie(barterer, function(threat, distanceSq, _, _, sameLevel)
            if not sameLevel or BarteringAIUtils.isBartererZombie(threat) then
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
                        if applySimulatedZombieBite(threat, barterer) then
                            entry.zombifyPending = true
                        end
                        entry.retreatForced = true
                        clearCombatTask(entry)
                    elseif state.tick >= BARTERER_BITE_RESET_TICKS then
                        endThreatBite(threat)
                        states[threat] = nil
                    end
                end
            elseif state then
                endThreatBite(threat)
                states[threat] = nil
            end
            return false
        end)
    end

    local function resetBiteStates(entry)
        for threat in pairs(entry.biteStates) do
            endThreatBite(threat)
        end
        entry.biteStates = nil
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
        updateZombieTargetPriorityForBarterer = updateZombieTargetPriorityForBarterer,
        updateZombieBitesOnBarterer = updateZombieBitesOnBarterer,
        resetBiteStates = resetBiteStates,
        THREAT_SPRINT_DISTANCE_SQ = THREAT_SPRINT_DISTANCE_SQ,
        THREAT_ENGAGE_DISTANCE_SQ = THREAT_ENGAGE_DISTANCE_SQ,
        BARTERER_AGGRO_SCAN_INTERVAL_TICKS = BARTERER_AGGRO_SCAN_INTERVAL_TICKS,
    }
end

return BarteringAICombat
