require "Bartering"
require "ISUI/ISInventoryPaneContextMenu"
require "Bartering.media.lua.client.BarteringVisuals"
require "Bartering.media.lua.client.BarteringRoadRoute"
require "Bartering.media.lua.client.BarteringMapMarkers"
require "Bartering.media.lua.client.BarteringDebug"

local BarteringUIUtils = require "BarteringUIUtils"
local sendClientCommandFn = _G["sendClientCommand"]
local events = _G["Events"]
local ISInventoryPane = _G["ISInventoryPane"]
local ISInventoryPaneContextMenu = _G["ISInventoryPaneContextMenu"]
local ISContextMenu = _G["ISContextMenu"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getCell = _G["getCell"]
local BarteringTiming = require "BarteringTiming"

local unavailableBarterers = {}
local permanentlyDeadBarterers = {}
local calledOutBarterers = {}

Bartering.Trips = Bartering.Trips or {}

local function getArrivalText(bartererId)
    return BarteringTiming.formatDuration((unavailableBarterers[bartererId] - getTimeInMillis()) / 1000)
end

local function getTravelSeconds(player, barterer)
    local multiplier = Bartering.getSandboxNumber("TravelTimeMultiplier", 1)
    return BarteringTiming.calculateTravelSeconds(
        player:getX(),
        player:getY(),
        barterer.x,
        barterer.y,
        barterer.travelSecondsPerTile,
        multiplier
    )
end

local function isCallLockedUntilMet(player, bartererId)
    return not Bartering.isBartererKnown(player, bartererId)
end

local function onFillInventoryObjectContextMenu(playerID, context, items)
    local actualItems = ISInventoryPane.getActualItems(items)
    local player = getSpecificPlayer(playerID)

    for i, item in ipairs(actualItems) do
        if item and item:getFullType() and string.find(item:getFullType():lower(), "walkietalkie") then
            local callOption = context:addOption("Call Barterer", nil, nil)
            local callMenu = ISContextMenu:getNew(context)
            context:addSubMenu(callOption, callMenu)
            for bartererId, barterer in pairs(Bartering.Barterers) do
                local met = Bartering.isBartererKnown(player, bartererId)
                local displayName = met and Bartering.getBartererDisplayName(bartererId) or "?"
                local travelTime = BarteringTiming.formatArrivalEstimate(getTravelSeconds(player, barterer))
                local callStartHour, callEndHour = Bartering.getBartererCallWindowHours(bartererId)
                local lifeState = Bartering.getBartererLifeState(bartererId)
                local callCooldownRemainingHours = BarteringTiming.remainingHours(lifeState.calledInCooldownAt)
                local respawnRemainingHours = BarteringTiming.remainingHours(lifeState.respawnAt)

                local parentOption = callMenu:addOption(displayName, nil, nil)
                local parentMenu = ISContextMenu:getNew(context)
                callMenu:addSubMenu(parentOption, parentMenu)

                local isEnRoute = unavailableBarterers[bartererId] ~= nil and calledOutBarterers[bartererId] == true
                local locationMode = Bartering.getSandboxNumber("ArriveAtCallLocation", 1) == 1

                local option = parentMenu:addOption("Call", player, Bartering.requestBartererOpenCall, bartererId, context)
                local blockedDescription
                local availableDescription
                if Bartering.Relations.getStarCount(player, bartererId) < 1 then
                    blockedDescription = "Requires Level 1 Relationship With This Barterer"
                    if isCallLockedUntilMet(player, bartererId) then
                        blockedDescription = blockedDescription .. ". Also requires meeting in person"
                    end
                elseif isCallLockedUntilMet(player, bartererId) then
                    blockedDescription = "Meet " .. displayName .. " in person before radio calls are unlocked"
                elseif permanentlyDeadBarterers[bartererId] or Bartering.isBartererPermanentlyDead(bartererId) then
                    blockedDescription = displayName .. " is dead and cannot respawn with the current sandbox settings"
                elseif respawnRemainingHours > 0 then
                    blockedDescription = displayName .. " is dead and will be replaced with a new barterer in " .. BarteringTiming.formatDuration(respawnRemainingHours * 3600)
                elseif callCooldownRemainingHours > 0 then
                    blockedDescription = displayName .. " call cooldown: " .. BarteringTiming.formatDuration(callCooldownRemainingHours * 3600)
                elseif (not isEnRoute) and (not Bartering.isBartererCallOpenNow(bartererId)) then
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

                option.notAvailable = blockedDescription ~= nil
                BarteringUIUtils.addContextTooltip(option, blockedDescription or availableDescription).name = not met and "Barterer Unknown" or displayName .. " Arrives in " .. travelTime

                if isEnRoute then
                    BarteringUIUtils.addContextTooltip(parentMenu:addOption("Cancel Meeting", player, Bartering.requestBartererCancelMeeting, bartererId, context),
                        "Cancel this meeting. Time spent traveling becomes call cooldown.")
                end

                local canSendHome = calledOutBarterers[bartererId] == true and unavailableBarterers[bartererId] == nil
                if canSendHome then
                    BarteringUIUtils.addContextTooltip(parentMenu:addOption("Send Home", player, Bartering.requestBartererSendHome, bartererId, context),
                        "Barterer has arrived at his location")
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
    local remaining = (arrivalAtMs - getTimeInMillis()) / 1000
    if remaining <= 0 then
        return nil
    end
    return remaining
end

function Bartering.markBartererUnavailable(bartererId, atMs)
    unavailableBarterers[bartererId] = atMs
end

function Bartering.optimisticCallETA(bartererId, arrivalAtMs)
    calledOutBarterers[bartererId] = true
    unavailableBarterers[bartererId] = arrivalAtMs
end

function Bartering.requestBartererSendHome(player, bartererId, context)
    sendClientCommandFn(player, "Bartering", "sendBartererHome", { bartererId = bartererId })
    context:hideAndChildren()
end

function Bartering.requestBartererCancelMeeting(player, bartererId, context)
    sendClientCommandFn(player, "Bartering", "cancelBartererMeeting", { bartererId = bartererId })
    if context then
        context:hideAndChildren()
    end
end

local function onServerCommand(module, command, args)
    if module ~= "Bartering" then
        return
    end

    if command == "setBartererAvailability" then
        if args.permanentlyDead or args.available then
            permanentlyDeadBarterers[args.bartererId] = args.permanentlyDead == true or nil
            unavailableBarterers[args.bartererId] = nil
            calledOutBarterers[args.bartererId] = nil
        end
        return
    end

    if command == "questUpdated" then
        BarteringDialogUI.notifyQuestUpdated(args.bartererId)
        return
    end

    if command == "returnTrip" then
        if args.arrivalAtMs then
            Bartering.Trips[args.bartererId] = {
                startX = args.startX,
                startY = args.startY,
                targetX = args.targetX,
                targetY = args.targetY,
                startedAtMs = args.startedAtMs or args.arrivalAtMs,
                arrivalAtMs = args.arrivalAtMs,
                kind = "return",
            }
            Bartering.RoadRoute.ensure(Bartering.Trips[args.bartererId])
        else
            Bartering.Trips[args.bartererId] = nil
        end
        return
    end

    if command == "callRefused" then
        BarteringDialogUI.notifyCallReply(args.bartererId, args.reason)
        return
    end

    if command == "callAccepted" then
        BarteringDialogUI.notifyCallReply(args.bartererId, args.message)
        return
    end

    if command == "meetupCanceled" then
        BarteringDialogUI.notifyMeetupCanceled(args.bartererId, args.message, args.relationsDelta)
        return
    end

    if command == "setBartererETA" then
        local eta = tonumber(args.arrivalAtMs) or 0
        calledOutBarterers[args.bartererId] = args.calledOut == true or nil
        unavailableBarterers[args.bartererId] = eta > 0 and eta or nil
        if eta > 0 and args.targetX ~= nil and args.targetY ~= nil then
            Bartering.Trips[args.bartererId] = {
                startX = args.startX,
                startY = args.startY,
                targetX = args.targetX,
                targetY = args.targetY,
                startedAtMs = tonumber(args.startedAtMs) or eta,
                arrivalAtMs = eta,
            }
            Bartering.RoadRoute.ensure(Bartering.Trips[args.bartererId])
        else
            Bartering.Trips[args.bartererId] = nil
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
            if bartererState == "DefendKnife" or bartererState == "DefendPistol" or bartererState == "DefendRifle" then
                talkOption.notAvailable = true
                BarteringUIUtils.addContextTooltip(talkOption, "Barterer is in combat")
            elseif not Bartering.hasMetBarterer(player, barterer.id) then
                BarteringUIUtils.addContextTooltip(talkOption, "Introduce yourself to this barterer")
            else
                BarteringUIUtils.addContextTooltip(talkOption, "Trade with " .. Bartering.getBartererDisplayName(barterer.id) .. " or run an errand for him")
            end

            if zombie:getVariableBoolean("BartererCalledIn") then
                parentMenu:addOption("Send home", player, Bartering.requestBartererSendHome, barterer.id, context)
            end

            BarteringDebug.addBartererMenuOptions(parentMenu, context, player, barterer.id)
        end
    end
end

events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
events.OnServerCommand.Add(onServerCommand)
