require "Bartering"
require "ISUI/ISInventoryPaneContextMenu"
require "Map/BarteringRoadRoute"
require "Map/BarteringMapMarkers"
require "UI/BarteringBarterUI"
require "UI/BarteringDialogUI"
require "UI/BarteringPlayerUI"
require "UI/BarteringHireUI"
require "UI/BarteringAmendsUI"
require "BarteringSaleCall"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local print = require("BarteringPathTrace").log
local BarteringAIUtils = require "BarteringAIUtils"
local sendClientCommandFn = _G["sendClientCommand"]
local events = _G["Events"]
local ISInventoryPane = _G["ISInventoryPane"]
local ISInventoryPaneContextMenu = _G["ISInventoryPaneContextMenu"]
local ISContextMenu = _G["ISContextMenu"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getCell = _G["getCell"]
local BarteringTiming = require "BarteringTiming"

local tracerTexture = getTexture("media/textures/mask_white.png")

local function drawMuzzleFlashes()
    if not isIngameState() then
        return
    end
    local list = BarteringMuzzleFlash.list
    if #list == 0 then
        return
    end
    local zoom = getCore():getZoom(0)
    local renderer = getRenderer()
    for i = #list, 1, -1 do
        local flash = list[i]
        local head = BarteringTiming.elapsedSince(flash.startMs) / 1000 * BarteringMuzzleFlash.SPEED
        local tail = math.max(0, head - BarteringMuzzleFlash.LENGTH)
        if tail >= BarteringMuzzleFlash.RANGE then
            table.remove(list, i)
        else
            head = math.min(head, BarteringMuzzleFlash.RANGE)
            local x1, y1 = ISCoordConversion.ToScreen(flash.x + flash.dirX * tail, flash.y + flash.dirY * tail,
                flash.z + flash.dropZ * tail)
            local x2, y2 = ISCoordConversion.ToScreen(flash.x + flash.dirX * head, flash.y + flash.dirY * head,
                flash.z + flash.dropZ * head)
            renderer:renderline(tracerTexture, x1 / zoom, y1 / zoom, x2 / zoom, y2 / zoom, 1, 1, 0.72, 0.35)
        end
    end
end

local unavailableBarterers = {}
local calledOutBarterers = {}
local localBartererZombies = {}

Bartering.Trips = Bartering.Trips or {}

function Bartering.getLocalBartererZombie(bartererId)
    return localBartererZombies[bartererId]
end

local SAY_VISIBLE_DISTANCE_SQ = 12 * 12
local SAY_PENDING_EXPIRE_MS = 60000
local pendingSays = {}

function Bartering.showBartererSay(bartererId, text)
    pendingSays[bartererId] = { text = text, atMs = BarteringTiming.now() }
end

local function flushBartererSay(zombie, bartererId)
    local pending = pendingSays[bartererId]
    if not pending then
        return
    end
    if BarteringTiming.hasElapsed(pending.atMs, SAY_PENDING_EXPIRE_MS) then
        pendingSays[bartererId] = nil
        return
    end
    local player = getSpecificPlayer(0)
    if player and player:CanSee(zombie)
        and BarteringAIUtils.distanceSqBetween(player, zombie) <= SAY_VISIBLE_DISTANCE_SQ then
        pendingSays[bartererId] = nil
        zombie:addLineChatElement(pending.text, 1.0, 0.9, 0.55)
    end
end

local function isOwnRelay(args)
    local player = getSpecificPlayer(0)
    return args.from ~= nil and player ~= nil and player:getUsername() == args.from
end

local function getArrivalText(bartererId)
    return BarteringTiming.formatDuration((unavailableBarterers[bartererId] - BarteringTiming.now()) / 1000)
end

local function getTravelSeconds(player, barterer)
    return BarteringTiming.travelSecondsTo(barterer, player:getX(), player:getY())
end

local function onFillInventoryObjectContextMenu(playerID, context, items)
    local actualItems = ISInventoryPane.getActualItems(items)
    local player = getSpecificPlayer(playerID)

    for i, item in ipairs(actualItems) do
        if Bartering.isWalkieTalkie(item) then
            local callOption = context:addOption("Call Barterer", nil, nil)
            local callMenu = ISContextMenu:getNew(context)
            context:addSubMenu(callOption, callMenu)
            for bartererId, barterer in pairs(Bartering.Barterers) do
                local met = Bartering.isBartererKnown(player, bartererId)
                local displayName = met and Bartering.getBartererDisplayName(bartererId) or "?"
                local travelTime = BarteringTiming.formatArrivalEstimate(getTravelSeconds(player, barterer))
                local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(bartererId)

                local parentOption = callMenu:addOption(displayName, nil, nil)
                local parentMenu = ISContextMenu:getNew(context)
                callMenu:addSubMenu(parentOption, parentMenu)

                local isEnRoute = unavailableBarterers[bartererId] ~= nil and calledOutBarterers[bartererId] == true
                local locationMode = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1

                local option = parentMenu:addOption("Call", player, Bartering.requestBartererOpenCall, bartererId, context)
                local blockedDescription = Bartering.getCallBlockReason(player, bartererId, BarteringTiming.formatDurationHours)
                local availableDescription
                if not blockedDescription then
                    if (not isEnRoute) and (not Bartering.isBartererCallOpenNow(bartererId)) then
                        blockedDescription = string.format("%s accepts calls between %02d:00 and %02d:00", displayName, callStartHour, callEndHour)
                    elseif unavailableBarterers[bartererId] and calledOutBarterers[bartererId] then
                        if locationMode then
                            availableDescription = "Arrange a meeting with " .. displayName .. " at your location. Current ETA: " .. getArrivalText(bartererId)
                        else
                            blockedDescription = displayName .. " is already on the way to your current position. ETA: " .. getArrivalText(bartererId)
                        end
                    elseif unavailableBarterers[bartererId] then
                        blockedDescription = displayName .. " has arrived at his location. Available in " .. getArrivalText(bartererId)
                    elseif locationMode then
                        availableDescription = "Arrange a meeting with " .. displayName .. " at this location"
                    else
                        availableDescription = "Arrange a meeting with " .. displayName .. " at your location"
                    end
                end

                option.notAvailable = blockedDescription ~= nil
                BarteringUIUtils.addContextTooltip(option, blockedDescription or availableDescription).name = not met and "Barterer Unknown" or displayName .. " Arrives in " .. travelTime

                if isEnRoute then
                    BarteringUIUtils.addContextTooltip(parentMenu:addOption("Cancel Meeting", player, Bartering.requestBartererCancelMeeting, bartererId, context),
                        "Cancel this meeting.")
                end

                BarteringDebug.addCallMenuOptions(parentMenu, player, bartererId, context)
            end
            break
        end
    end
end

function Bartering.requestBartererOpenCall(player, bartererId, context)
    BarteringDialogUI.open(player, bartererId, 0, 0, 0, nil, true)
    context:hideAndChildren()
end

function Bartering.getBartererArrivalRemainingSeconds(bartererId)
    local arrivalAtMs = calledOutBarterers[bartererId] and unavailableBarterers[bartererId]
    if not arrivalAtMs then
        return nil
    end
    local remaining = (arrivalAtMs - BarteringTiming.now()) / 1000
    if remaining <= 0 then
        return nil
    end
    return remaining
end

function Bartering.isBartererWaitingAtMeetup(bartererId)
    local trip = Bartering.Trips[bartererId]
    return trip ~= nil and trip.waiting == true
        and Bartering.getBartererArrivalRemainingSeconds(bartererId) ~= nil
end

function Bartering.isBartererAwayFromHome(bartererId)
    return calledOutBarterers[bartererId] == true or Bartering.Trips[bartererId] ~= nil
end

function Bartering.markBartererUnavailable(bartererId, atMs)
    unavailableBarterers[bartererId] = atMs
end

function Bartering.optimisticCallETA(bartererId, arrivalAtMs)
    calledOutBarterers[bartererId] = true
    unavailableBarterers[bartererId] = arrivalAtMs
end

function Bartering.isBartererArrivedAtCall(bartererId)
    return calledOutBarterers[bartererId] == true and unavailableBarterers[bartererId] == nil
end

function Bartering.requestBartererCancelMeeting(player, bartererId, context)
    sendClientCommandFn(player, "Bartering", "cancelBartererMeeting", { bartererId = bartererId })
    if context then
        context:hideAndChildren()
    end
end

local function setTrip(bartererId, arrivalAtMs, args, startedAtMs, kind)
    if not arrivalAtMs then
        Bartering.Trips[bartererId] = nil
        return
    end

    local waiting = args.waiting == true
    Bartering.Trips[bartererId] = {
        startX = args.startX,
        startY = args.startY,
        targetX = args.targetX,
        targetY = args.targetY,
        startedAtMs = startedAtMs,
        arrivalAtMs = arrivalAtMs,
        kind = kind,
        waiting = waiting,
        standoff = kind ~= "return" and Bartering.RoadRoute.ARRIVAL_STANDOFF or nil,
    }
    if not waiting then
        Bartering.RoadRoute.ensure(Bartering.Trips[bartererId])
    end
end

local function onServerCommand(module, command, args)
    if module ~= "Bartering" then
        return
    end

    if command == "bartererSay" then
        if not isOwnRelay(args) then
            Bartering.showBartererSay(args.bartererId, args.text)
        end
        return
    end

    if command == "bartererShot" then
        local zombie = localBartererZombies[args.bartererId]
        if zombie and not isOwnRelay(args) then
            Bartering.showBartererShot(zombie, args.sound)
        end
        return
    end

    if command == "bartererSound" then
        local zombie = localBartererZombies[args.bartererId]
        if zombie and not isOwnRelay(args) then
            Bartering.logBartererSound(zombie, "relayed", args.sound, zombie:getEmitter():playSound(args.sound))
        end
        return
    end

    if command == "despawnZombie" then
        local zombies = getCell():getZombieList()
        for i = zombies:size() - 1, 0, -1 do
            local zombie = zombies:get(i)
            if zombie:getOnlineID() == args.zid then
                local bartererId = zombie:getVariableString("BartererId")
                if localBartererZombies[bartererId] == zombie then
                    localBartererZombies[bartererId] = nil
                end
                Bartering.clearBartererSighting(bartererId)
                print(string.format("[Bartering][MP] removing zombie zid=%s barterer=%s on server request",
                    tostring(args.zid), tostring(bartererId)))
                zombie:removeFromWorld()
                zombie:removeFromSquare()
                return
            end
        end
        return
    end

    if command == "zombieHit" then
        BarteringAI.applyRelayedZombieHit(args)
        return
    end

    if command == "bartererDebug" then
        BarteringAI.applyDebugAction(args)
        return
    end

    if command == "playerSay" then
        local player = getSpecificPlayer(0)
        if player then
            player:Say(args.text)
        end
        return
    end

    if command == "bartererStockChanged" then
        BarteringBarterUI.refreshOpen(args.bartererId)
        BarteringDialogUI.notifyStockChanged(args.bartererId)
        return
    end

    if command == "setBartererAvailability" then
        if args.permanentlyDead or args.available then
            unavailableBarterers[args.bartererId] = nil
            calledOutBarterers[args.bartererId] = nil
        end
        return
    end

    if command == "questUpdated" then
        print("[Bartering][Quest] client received questUpdated for " .. tostring(args.bartererId))
        BarteringDialogUI.notifyQuestUpdated(args.bartererId)
        return
    end

    if command == "returnTrip" then
        local now = BarteringTiming.now()
        setTrip(args.bartererId, now + args.remainingMs, args, now - args.elapsedMs, "return")
        return
    end

    if command == "callRefused" then
        BarteringDialogUI.notifyCallReply(args.bartererId, args.reason, args.template, args.live)
        return
    end

    if command == "radioStatus" then
        BarteringDialogUI.notifyRadioStatus(args.bartererId, args.status, args.seconds)
        return
    end

    if command == "callNoAnswer" then
        calledOutBarterers[args.bartererId] = nil
        unavailableBarterers[args.bartererId] = nil
        Bartering.Trips[args.bartererId] = nil
        BarteringDialogUI.notifyCallNoAnswer(args.bartererId, args.message)
        return
    end

    if command == "callAccepted" then
        BarteringDialogUI.notifyCallReply(args.bartererId, args.message, args.template, args.live)
        return
    end

    if command == "meetupCanceled" then
        BarteringDialogUI.notifyMeetupCanceled(args.bartererId, args.message, args.relationsDelta)
        BarteringBarterUI.closeAll()
        BarteringDialogUI.closeAllExceptHostileCancel(args.bartererId)
        return
    end

    if command == "bartererReturningHome" then
        local player = getSpecificPlayer(0)
        if player then
            Bartering.revealReturningHome(player, args.bartererId)
        end
        BarteringBarterUI.closeAll()
        BarteringDialogUI.closeAllExceptHostileCancel(args.bartererId)
        return
    end

    if command == "clearBartererSighting" then
        Bartering.clearBartererSighting(args.bartererId)
        return
    end

    if command == "setBartererETA" then
        local now = BarteringTiming.now()
        local eta = args.remainingMs > 0 and (now + args.remainingMs) or nil
        calledOutBarterers[args.bartererId] = args.calledOut == true or nil
        unavailableBarterers[args.bartererId] = eta
        local hasTarget = eta ~= nil and args.targetX ~= nil and args.targetY ~= nil
        setTrip(args.bartererId, hasTarget and eta or nil, args, now - args.elapsedMs)
        return
    end

    if command == "bartererHired" then
        BarteringHireUI.closeAll()
        return
    end

    if command == "bartererForgiven" then
        print("[Bartering][Hostility] forgiven ack received for " .. tostring(args.bartererId))
        BarteringAmendsUI.closeAll()
    end
end

local function onRefreshInventoryWindowContainers(inventoryPage, reason)
    local inventory = inventoryPage and inventoryPage.inventory
    if inventory then
        local character = inventory:getCharacter()
        if character then
            BarteringBarterUI.refreshOpenOffers(character)
            BarteringHireUI.refreshOpenOffers(character)
            BarteringDialogUI.notifyInventoryChanged(character)
        end
    end
end

local function onFillWorldObjectContextMenu(playerID, context, worldObjects, test)
    if test then
        return
    end

    local clickedSquare = worldObjects[1]:getSquare()
    local x = clickedSquare:getX()
    local y = clickedSquare:getY()
    local z = clickedSquare:getZ()
    local zombie
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = getCell():getGridSquare(x + dx, y + dy, z)
            if square and square:getZombie() and square:getZombie():getVariableBoolean("Barterer") then
                zombie = square:getZombie()
                break
            end
        end
        if zombie then
            break
        end
    end

    if zombie then
        local player = getSpecificPlayer(playerID)
        local barterer = Bartering.Barterers[zombie:getVariableString("BartererId")]
        if barterer then
            local parentOption = context:addOption("Barterer", nil, nil)
            local parentMenu = ISContextMenu:getNew(context)
            context:addSubMenu(parentOption, parentMenu)

            local talkOption = parentMenu:addOption("Talk", player, BarteringDialogUI.open, barterer.id, x, y, z, zombie)
            local bartererState = zombie:getVariableString("BartererState") or ""
            local enRoute = zombie:getVariableBoolean("BartererIntercepted")
            if enRoute then
                BarteringUIUtils.addContextTooltip(talkOption, "He stopped to ask if you want to trade here or continue to the meetup")
            elseif bartererState == "DefendKnife" or bartererState == "DefendPistol" then
                talkOption.notAvailable = true
                BarteringUIUtils.addContextTooltip(talkOption, "Barterer is in combat")
            elseif not Bartering.hasMetBarterer(player, barterer.id) then
                BarteringUIUtils.addContextTooltip(talkOption, "Introduce yourself to this barterer")
            else
                BarteringUIUtils.addContextTooltip(talkOption, "Trade with " .. Bartering.getBartererDisplayName(barterer.id) .. " or run an errand for him")
            end

            BarteringDebug.addBartererMenuOptions(parentMenu, context, player, barterer.id)
        end
    end
end

local instanceof = _G["instanceof"]

local function releaseZombie(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    if localBartererZombies[bartererId] == zombie then
        localBartererZombies[bartererId] = nil
    end
    print(string.format("[Bartering][MP] released %s zid=%s (no live record)",
        tostring(bartererId), tostring(zombie:getOnlineID())))
    BarteringDebug.forgetBarterer(bartererId)
    Bartering.releaseBartererZombie(zombie)
end

local function updateBarterer(zombie)
    local record, bartererId = Bartering.resolveBartererRecord(zombie)
    if not record then
        if zombie:getVariableBoolean("Barterer") then
            releaseZombie(zombie)
        end
        return
    end

    localBartererZombies[bartererId] = zombie
    Bartering.adoptBartererZombie(zombie, bartererId, record)

    if zombie:isDead() or zombie:getHealth() <= 0 then
        BarteringDebug.forgetBarterer(bartererId)
        Bartering.clearBartererSighting(bartererId)
        return
    end

    flushBartererSay(zombie, bartererId)
    local bartererState = zombie:getVariableString("BartererState") or ""
    BarteringAIUtils.keepBartererDocile(zombie)
    Bartering.refreshBartererVisuals(zombie, bartererState)
    Bartering.recordBartererSighting(zombie, bartererState)
    BarteringDebug.traceBarterer(zombie, bartererState)
    BarteringAI.noteControllerZombie(zombie, bartererId, record)
end

function Bartering.adoptLiveBarterersNow()
    BarteringAI.rebuildZidIndex()
    local zombies = getCell():getZombieList()
    for i = 0, zombies:size() - 1 do
        updateBarterer(zombies:get(i))
    end
end

local function onHitZombie(zombie, attacker, bodyPart, weapon)
    if not zombie:getVariableBoolean("Barterer") then
        return
    end

    BarteringAIUtils.silenceZombieVoice(zombie)
    BarteringAIUtils.resistKnockdown(zombie, attacker)
    if instanceof(attacker, "IsoPlayer") then
        local script = weapon:getScriptItem()
        local cutting = script:containsWeaponCategory(WeaponCategory.AXE)
            or script:containsWeaponCategory(WeaponCategory.LONG_BLADE)
            or script:containsWeaponCategory(WeaponCategory.SMALL_BLADE)
            or script:containsWeaponCategory(WeaponCategory.SPEAR)
        if ZombRand(2) == 0 then
            Bartering.playBartererSound(zombie, (zombie:isFemale() and "VoiceFemale" or "VoiceMale")
                .. (cutting and "PainFromLacerate" or "PainFromHitBlunt"))
        end
        Bartering.Hostility.reportHit(zombie, attacker, weapon)
    end
end

events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
events.OnRefreshInventoryWindowContainers.Add(onRefreshInventoryWindowContainers)
events.OnServerCommand.Add(onServerCommand)
events.OnPreUIDraw.Add(drawMuzzleFlashes)
events.OnZombieUpdate.Add(updateBarterer)
events.OnHitZombie.Add(onHitZombie)
events.OnPlayerDeath.Add(function()
    BarteringDialogUI.closeAll()
    BarteringBarterUI.closeAll()
    BarteringHireUI.closeAll()
    sendClientCommand(getSpecificPlayer(0), "Bartering", "playerDied", {})
end)
events.OnCreatePlayer.Add(function(playerIndex, player)
    sendClientCommand(player, "Bartering", "playerCreated", {})
end)
