require "Bartering"
require "ISUI/ISInventoryPaneContextMenu"

local BarteringUIUtils = require "BarteringUIUtils"
local events = _G["Events"]
local sendClientCommand = _G["sendClientCommand"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getTimeInMillis = _G["getTimeInMillis"]
local ISContextMenu = _G["ISContextMenu"]
local ISInventoryPaneContextMenu = _G["ISInventoryPaneContextMenu"]

BarteringDebug = {}

function Bartering.requestDebugBartererSpawn(player, bartererId)
    Bartering.markBartererUnavailable(bartererId, getTimeInMillis())
    sendClientCommand(player, "Bartering", "debugSpawnBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugBartererCall(player, bartererId, context)
    sendClientCommand(player, "Bartering", "debugCallBarterer", { bartererId = bartererId })
    context:hideAndChildren()
end

function Bartering.requestDebugKillBarterer(player, bartererId)
    sendClientCommand(player, "Bartering", "debugKillBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugZombifyBarterer(player, bartererId)
    sendClientCommand(player, "Bartering", "debugZombifyBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugMeetAllBarterers(player)
    for _, barterer in pairs(Bartering.Barterers) do
        Bartering.meetBarterer(player, barterer.id)
    end
end

function Bartering.requestDebugAddRelations(player, bartererId)
    sendClientCommand(player, "Bartering", "addRelations", { bartererId = bartererId })
end

function BarteringDebug.addCallMenuOptions(parentMenu, player, bartererId, context)
    if not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end
    BarteringUIUtils.addContextTooltip(parentMenu:addOption("Debug Call", player, Bartering.requestDebugBartererCall, bartererId, context),
        "Debug only: trigger a normal radio call path and bypass call requirements/cooldowns")
end

function Bartering.requestDebugPlayBandageAnimation(player, bartererId)
    sendClientCommand(player, "Bartering", "debugBandageBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugHurtBarterer(player, bartererId)
    sendClientCommand(player, "Bartering", "debugHurtBarterer", { bartererId = bartererId })
end

function Bartering.requestDebugTeleportToQuest(player, bartererId)
    local quest = Bartering.Quests.getActive(player, bartererId)
    player:setX(quest.x + 0.5)
    player:setY(quest.y + 0.5)
    player:setZ(quest.z)
    player:setLx(quest.x + 0.5)
    player:setLy(quest.y + 0.5)
    player:setLz(quest.z)
end

function Bartering.requestDebugResetQuest(player, bartererId)
    sendClientCommand(player, "Bartering", "debugResetQuest", { bartererId = bartererId })
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
            quest.itemName, Bartering.Quests.getPlaceReference(quest), quest.townName, quest.x, quest.y, quest.z))
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

    local teleportParent = submenu:addOption("Teleport to Barterer", worldobjects, nil)
    local teleportSubmenu = ISContextMenu:getNew(context)
    submenu:addSubMenu(teleportParent, teleportSubmenu)

    for _, barterer in pairs(Bartering.Barterers) do
        teleportSubmenu:addOption(Bartering.getBartererDisplayName(barterer.id), worldobjects, onTeleportToBarterer, playerIndex, barterer.id)
    end

    local relationsParent = submenu:addOption("Add 100 Relations", worldobjects, nil)
    local relationsSubmenu = ISContextMenu:getNew(context)
    submenu:addSubMenu(relationsParent, relationsSubmenu)

    for _, barterer in pairs(Bartering.Barterers) do
        BarteringUIUtils.addContextTooltip(
            relationsSubmenu:addOption(Bartering.getBartererDisplayName(barterer.id), worldobjects, onAddRelations, playerIndex, barterer.id),
            "Debug only: add 100 relationship points with this barterer")
    end

    local saleParent = submenu:addOption("Trigger Sale", worldobjects, nil)
    local saleSubmenu = ISContextMenu:getNew(context)
    submenu:addSubMenu(saleParent, saleSubmenu)

    for _, barterer in pairs(Bartering.Barterers) do
        BarteringUIUtils.addContextTooltip(
            saleSubmenu:addOption(Bartering.getBartererDisplayName(barterer.id), worldobjects, onTriggerSale, playerIndex, barterer.id),
            "Debug only: force this barterer's sale active for the rest of today")
    end

    submenu:addOption("Dump Named Place Rooms", worldobjects, onResolveNamedZs, playerIndex)

    BarteringUIUtils.addContextTooltip(
        submenu:addOption("Dump Path Trace", worldobjects, onDumpPathTrace, playerIndex),
        "Debug only: print the accumulated pathing decision counters for every loaded barterer and reset the window")
end

events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

return BarteringDebug
