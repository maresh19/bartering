require "Bartering"
require "ISUI/ISInventoryPaneContextMenu"

local BarteringUIUtils = require "UI/BarteringUIUtils"
local BarteringTiming = require "BarteringTiming"
local print = require("BarteringPathTrace").log
local events = _G["Events"]
local sendClientCommand = _G["sendClientCommand"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local ISContextMenu = _G["ISContextMenu"]
local ISInventoryPaneContextMenu = _G["ISInventoryPaneContextMenu"]

BarteringDebug = {}

function Bartering.requestDebugBartererSpawn(player, bartererId)
    Bartering.markBartererUnavailable(bartererId, BarteringTiming.now())
    sendClientCommand(player, "Bartering", "debugSpawnBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugBartererCall(player, bartererId, context)
    sendClientCommand(player, "Bartering", "debugCallBarterer", { bartererId = bartererId })
    context:hideAndChildren()
end

local function debugRequest(command)
    return function(player, bartererId)
        sendClientCommand(player, "Bartering", command, { bartererId = bartererId })
    end
end

Bartering.requestDebugKillBarterer = debugRequest("debugKillBarterer")
Bartering.requestDebugZombifyBarterer = debugRequest("debugZombifyBarterer")
Bartering.requestDebugAddRelations = debugRequest("addRelations")
Bartering.requestDebugPlayBandageAnimation = debugRequest("debugBandageBarterer")
Bartering.requestDebugHurtBarterer = debugRequest("debugHurtBarterer")
Bartering.requestDebugResetQuest = debugRequest("debugResetQuest")

function Bartering.requestDebugMeetAllBarterers(player)
    for _, barterer in pairs(Bartering.Barterers) do
        Bartering.meetBarterer(player, barterer.id)
    end
end

function BarteringDebug.addCallMenuOptions(parentMenu, player, bartererId, context)
    if not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end
    BarteringUIUtils.addContextTooltip(parentMenu:addOption("Debug Call", player, Bartering.requestDebugBartererCall, bartererId, context),
        "Debug only: trigger a normal radio call path and bypass call requirements/cooldowns")
end

function Bartering.requestDebugTeleportToQuest(player, bartererId)
    local quest = Bartering.Quests.getActive(player, bartererId)
    player:teleportTo(quest.x + 0.5, quest.y + 0.5, quest.z)
end

function BarteringDebug.addBartererMenuOptions(parentMenu, context, player, bartererId)
    if not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end
    local debugMenu = ISContextMenu:getNew(context)
    local debugOption = parentMenu:addOption("Debug", nil, nil)
    parentMenu:addSubMenu(debugOption, debugMenu)
    debugMenu:addOption("Kill Barterer", player, Bartering.requestDebugKillBarterer, bartererId)
    debugMenu:addOption("Zombify Barterer", player, Bartering.requestDebugZombifyBarterer, bartererId)
    debugMenu:addOption("Play Bandage Animation", player, Bartering.requestDebugPlayBandageAnimation, bartererId)
    debugMenu:addOption("Hurt Barterer", player, Bartering.requestDebugHurtBarterer, bartererId)

    local quest = Bartering.Quests.getActive(player, bartererId)
    local teleportOption = debugMenu:addOption("Teleport to Quest Goal", player, Bartering.requestDebugTeleportToQuest, bartererId)
    if quest then
        BarteringUIUtils.addContextTooltip(teleportOption, string.format("%s - %s in %s (%d, %d, %d)",
            quest.itemName, Bartering.Quests.getPlaceReference(quest, player), quest.townName, quest.x, quest.y, quest.z))
    else
        teleportOption.notAvailable = true
        BarteringUIUtils.addContextTooltip(teleportOption, "No active quest for this barterer")
    end

    local resetOption = debugMenu:addOption("Reset Quest", player, Bartering.requestDebugResetQuest, bartererId)
    BarteringUIUtils.addContextTooltip(resetOption, "Debug only: drop any active quest and clear the cooldown so a new quest can be requested")
end

local function onSpawnBartererAt(worldobjects, playerIndex, bartererId, x, y, z)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "debugSpawnBartererAt", {
        bartererId = bartererId,
        x = x,
        y = y,
        z = z,
    })
end

local function onDespawnAllBarterers(worldobjects, playerIndex)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "debugDespawnAllBarterers", {})
end

local function onTeleportToBarterer(worldobjects, playerIndex, bartererId)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "debugTeleportToBarterer", { bartererId = bartererId })
end

local function onMeetAllBarterers(worldobjects, playerIndex)
    Bartering.requestDebugMeetAllBarterers(getSpecificPlayer(playerIndex))
end

local function onTriggerSale(worldobjects, playerIndex, bartererId)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "debugTriggerSale", { bartererId = bartererId })
    player:Say("Triggered a weekly sale with " .. Bartering.getBartererDisplayName(bartererId))
end

local function onAddRelations(worldobjects, playerIndex, bartererId)
    Bartering.requestDebugAddRelations(getSpecificPlayer(playerIndex), bartererId)
end

local function onDumpPathTrace(worldobjects, playerIndex)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "debugDumpPathTrace", {})
end

local function onResolveNamedZs(worldobjects, playerIndex)
    local player = getSpecificPlayer(playerIndex)
    sendClientCommand(player, "Bartering", "dumpNamedZs", {})
end

local function perBartererSubmenu(context, submenu, worldobjects, playerIndex, label, handler, tooltip)
    local parent = submenu:addOption(label, worldobjects, nil)
    local menu = ISContextMenu:getNew(context)
    submenu:addSubMenu(parent, menu)

    for _, barterer in pairs(Bartering.Barterers) do
        local option = menu:addOption(Bartering.getBartererDisplayName(barterer.id),
            worldobjects, handler, playerIndex, barterer.id)
        if tooltip then
            BarteringUIUtils.addContextTooltip(option, tooltip)
        end
    end
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    if test then
        return
    end
    if not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end

    local square
    for _, worldObject in ipairs(worldobjects) do
        local objectSquare = worldObject:getSquare()
        if objectSquare then
            square = objectSquare
            break
        end
    end

    if not square then
        return
    end

    local parent = context:addOption("Bartering", worldobjects, nil)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(parent, submenu)

    submenu:addOption("Meet all Barterers", worldobjects, onMeetAllBarterers, playerIndex)

    local spawnParent = submenu:addOption("Spawn Barterer", worldobjects, nil)
    local spawnSubmenu = ISContextMenu:getNew(context)
    submenu:addSubMenu(spawnParent, spawnSubmenu)

    for _, barterer in pairs(Bartering.Barterers) do
        spawnSubmenu:addOption(
            Bartering.getBartererDisplayName(barterer.id),
            worldobjects,
            onSpawnBartererAt,
            playerIndex,
            barterer.id,
            square:getX(),
            square:getY(),
            square:getZ())
    end

    submenu:addOption("Despawn All Barterers", worldobjects, onDespawnAllBarterers, playerIndex)

    perBartererSubmenu(context, submenu, worldobjects, playerIndex, "Teleport to Barterer", onTeleportToBarterer)
    perBartererSubmenu(context, submenu, worldobjects, playerIndex, "Add 100 Relations", onAddRelations,
        "Debug only: add 100 relationship points with this barterer")
perBartererSubmenu(context, submenu, worldobjects, playerIndex, "Trigger Sale", onTriggerSale,
        "Debug only: force this barterer's sale active for today")

    submenu:addOption("Dump Named Place Rooms", worldobjects, onResolveNamedZs, playerIndex)

    BarteringUIUtils.addContextTooltip(
        submenu:addOption("Dump Path Trace", worldobjects, onDumpPathTrace, playerIndex),
        "Debug only: print the accumulated pathing decision counters for every loaded barterer and reset the window")
end

local tracedBarterers = {}

local function logBartererDebug(zombie, reason, bartererState, actionState)
    local name = Bartering.getBartererDisplayName(zombie:getVariableString("BartererId"))
    print(string.format(
        "[Bartering][ClientDebug] %s | %s | state=%s action=%s curState=%s useless=%s walk=%s bump=%s bumpDone=%s pos=%.2f,%.2f,%.2f | separate=%s solid=%s collidable=%s floor=%s ragdoll=%s sitWall=%s speedType=%s",
        tostring(name),
        tostring(reason),
        tostring(bartererState),
        tostring(actionState),
        tostring(zombie:getCurrentStateName()),
        tostring(zombie:isUseless()),
        tostring(zombie:getVariableString("BartererWalkType")),
        tostring(zombie:getBumpType()),
        tostring(zombie:getVariableBoolean("BumpAnimFinished")),
        zombie:getX(),
        zombie:getY(),
        zombie:getZ(),
        tostring(zombie:isSolidForSeparate()),
        tostring(zombie:isSolid()),
        tostring(zombie:isCollidable()),
        tostring(zombie:isOnFloor()),
        tostring(zombie:isRagdoll()),
        tostring(zombie:isSitAgainstWall()),
        tostring(zombie:getSpeedType())
    ))
end

function BarteringDebug.forgetBarterer(bartererId)
    tracedBarterers[bartererId] = nil
end

function BarteringDebug.traceBarterer(zombie, bartererState)
    local bartererId = zombie:getVariableString("BartererId")
    local entry = tracedBarterers[bartererId]
    if not entry then
        entry = {}
        tracedBarterers[bartererId] = entry
    end
    local actionState = zombie:getActionStateName()

    if entry.lastBartererState ~= bartererState then
        if bartererState == "Return" then
            print(string.format(
                "[Bartering][VisualState] %s raw state -> Return | pos=%.1f,%.1f calledIn=%s liveTrip=%s awayFromHome=%s returnKnowledge=%s",
                tostring(bartererId), zombie:getX(), zombie:getY(),
                tostring(zombie:getVariableBoolean("BartererCalledIn")),
                tostring(Bartering.Trips[bartererId] ~= nil),
                tostring(Bartering.isBartererAwayFromHome(bartererId)),
                tostring(Bartering.hasReturningHomeKnowledge(getSpecificPlayer(0), bartererId))))
        end
        logBartererDebug(zombie, "state changed", bartererState, actionState)
        entry.lastBartererState = bartererState
    end
    if entry.lastActionState ~= actionState then
        logBartererDebug(zombie, "action changed", bartererState, actionState)
        entry.lastActionState = actionState
    end
    if bartererState == "Return" and actionState ~= "pathfind" and actionState ~= "walktoward" and actionState ~= "idle" then
        if entry.lastUnexpectedActionState ~= actionState then
            logBartererDebug(zombie, "unexpected moving action", bartererState, actionState)
            entry.lastUnexpectedActionState = actionState
        end
    else
        entry.lastUnexpectedActionState = nil
    end
end

events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

return BarteringDebug
