require "Bartering"
require "BarteringHire"
local BarteringPathTrace = require "BarteringPathTrace"
local print = BarteringPathTrace.log
local BarteringAIUtils = require "BarteringAIUtils"
local BarteringDialogue = require "BarteringDialogue"

local events = _G["Events"]
local sendServerCommand = _G["sendServerCommand"]
local triggerEvent = _G["triggerEvent"]
local sendAddItemToContainer = _G["sendAddItemToContainer"]
local sendRemoveItemFromContainer = _G["sendRemoveItemFromContainer"]
local getGameTime = _G["getGameTime"]
local ModData = _G["ModData"]

local function sendToPlayer(player, command, args)
    if isServer() then
        sendServerCommand(player, "Bartering", command, args)
        return
    end
    triggerEvent("OnServerCommand", "Bartering", command, args)
end

local function teleportToBarterer(player, bartererId)
    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return
    end

    local x, y, z = barterer.x, barterer.y, barterer.z
    local zombie = BarteringAI.serverZombies[bartererId]
    if zombie and zombie:getSquare() then
        x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
    end

    player:teleportTo(x + 2, y + 2, z)
    print("[Bartering][ServerDebug] teleported " .. tostring(player:getUsername()) .. " to barterer " .. tostring(bartererId) .. " at " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
end

local function dumpNamedZs()
    local metaGrid = getWorld():getMetaGrid()
    print("[Bartering][NamedPlaces] dumping rooms at named places")
    for _, location in ipairs(Bartering.NamedPlaces.getLocations()) do
        local roomsAt = Bartering.NamedPlaces.roomsAtPoint(metaGrid, location.x, location.y)
        local roomsCell = ""
        for _, entry in ipairs(roomsAt) do
            roomsCell = roomsCell .. entry.level .. "=" .. entry.name .. "\t"
        end
        local buildingCell = "-"
        local buildingDef = metaGrid:getBuildingAt(location.x, location.y)
        if buildingDef and #roomsAt == 0 then
            local rooms = buildingDef:getRooms()
            local seen = {}
            local names = {}
            for i = 0, rooms:size() - 1 do
                local name = rooms:get(i):getName()
                if not seen[name] then
                    seen[name] = true
                    table.insert(names, name)
                end
            end
            buildingCell = table.concat(names, ",")
        end
        print(string.format("roomresolve\t%s\t%d,%d,z%d\t%s%s\t%s", location.id, location.x, location.y, location.z or 0, roomsCell, buildingCell, location.name))
    end
end

local function debugTriggerSale(player, args)
    if not Bartering.isBartererCallOpenNow(args.bartererId) then
        return
    end
    local remaining = Bartering.triggerWeeklySale(args.bartererId)
    if remaining then
        print("[Bartering][ServerDebug] triggered sale for " .. tostring(args.bartererId) .. " for " .. tostring(remaining) .. " more hours")
        if Bartering.hasWalkieTalkie(player) then
            sendToPlayer(player, "saleCall", { bartererId = args.bartererId })
        end
    end
end

local function collectOffer(player, offeredArgs, bartererId)
    local inventoryItems = player:getInventory():getItems()
    local offeredItems = {}
    local seen = {}
    local offeredValue = 0
    local relationValue = 0
    for _, offeredItemArgs in ipairs(offeredArgs) do
        local offeredItem
        for i = 0, inventoryItems:size() - 1 do
            local item = inventoryItems:get(i)
            if item:getID() == offeredItemArgs.id then
                offeredItem = item
                break
            end
        end
        if not offeredItem
            or seen[offeredItem]
            or offeredItem:getFullType() ~= offeredItemArgs.itemName
            or Bartering.getDrainableUnitCount(offeredItem) ~= offeredItemArgs.unitCount
            or not Bartering.Quests.acceptsCoupon(offeredItem, bartererId) then
            return nil
        end
        seen[offeredItem] = true
        table.insert(offeredItems, offeredItem)
        local itemValue = Bartering.getTradeValue(offeredItem, Bartering.ValueSide.Player, player, bartererId)
        offeredValue = offeredValue + itemValue
        if not Bartering.Quests.getCouponBarterer(offeredItem) then
            relationValue = relationValue + itemValue
        end
    end
    return offeredItems, offeredValue, relationValue
end

local function removeOfferedItems(player, offeredItems)
    local inventory = player:getInventory()
    for _, offeredItem in ipairs(offeredItems) do
        inventory:Remove(offeredItem)
        sendRemoveItemFromContainer(inventory, offeredItem)
    end
end

local function performTrade(player, args)
    local barterer = Bartering.Barterers[args.bartererId]
    if not barterer or Bartering.getBarterSkillLevel(player) < barterer.requiredLevel then
        return
    end
    if BarteringAI.isEnRoute(args.bartererId) then
        return
    end

    local offeredItems, offeredValue, relationValue = collectOffer(player, args.offeredItems, args.bartererId)
    if not offeredItems then
        return
    end

    local stock = Bartering.getBartererStock(args.bartererId, player)
    local selectedStockIndexes = {}
    local receivedValue = 0
    for _, received in ipairs(args.receivedItems) do
        local requestedName = received.itemName
        local requestedQty = received.qty
        local matched = 0
        for i, itemName in ipairs(stock) do
            if itemName == requestedName and not selectedStockIndexes[i] then
                selectedStockIndexes[i] = true
                receivedValue = receivedValue + Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer, player, args.bartererId)
                matched = matched + 1
                if matched >= requestedQty then
                    break
                end
            end
        end
        if matched < requestedQty then
            return
        end
    end

    if offeredValue < receivedValue then
        return
    end

    removeOfferedItems(player, offeredItems)
    local inventory = player:getInventory()
    for _, received in ipairs(args.receivedItems) do
        for _ = 1, received.qty do
            sendAddItemToContainer(inventory, inventory:AddItem(received.itemName))
        end
    end
    Bartering.consumeBartererSlots(args.bartererId, stock, selectedStockIndexes)
    BarteringAI.syncBartererStock(args.bartererId)
    Bartering.broadcastToClients("bartererStockChanged", {
        bartererId = args.bartererId,
    })
    Bartering.awardTradeXp(player, offeredValue, receivedValue)
    Bartering.Relations.add(player, args.bartererId, relationValue)
end

local function performHire(player, args)
    local barterer = Bartering.Barterers[args.bartererId]
    if not barterer or not BarteringHire.isAllowed() then
        return
    end
    if Bartering.getBarterSkillLevel(player) < barterer.requiredLevel then
        return
    end
    local extending = BarteringHire.isHired(args.bartererId)
    if extending then
        if not BarteringHire.isHiredBy(player, args.bartererId) then
            return
        end
    end
    if Bartering.getSandboxBoolean("EnableRelationships", true)
        and Bartering.Relations.getStarCount(player, args.bartererId) < SandboxVars.Bartering.HireRelationshipStars then
        return
    end

    local record = Bartering.getLiveRecord(args.bartererId)
    local zombie = BarteringAI.serverZombies[args.bartererId]
    if not record or record.unloaded or not zombie or not zombie:getSquare() then
        return
    end

    local offeredItems, offeredValue = collectOffer(player, args.offeredItems, args.bartererId)
    if not offeredItems then
        return
    end

    local hours = BarteringHire.computeHoursFromValue(offeredValue)
    if hours <= 0 then
        return
    end

    removeOfferedItems(player, offeredItems)

    local durationHours = hours
    if extending then
        durationHours = BarteringHire.getRemainingHours(args.bartererId) + hours
    end
    BarteringHire.setHiredState(args.bartererId, {
        hiredBy = player:getUsername(),
        hiredAtWorldHours = getGameTime():getWorldAgeHours(),
        durationHours = durationHours,
        hireValue = BarteringHire.computeValueFromHours(durationHours),
    })

    record.master = player:getUsername()
    Bartering.bumpLiveRev(record)

    BarteringAIUtils.sayBarterer(args.bartererId, BarteringDialogue.Hire.accepted:format(BarteringHire.formatHours(hours)))

    sendToPlayer(player, "bartererHired", {
        bartererId = args.bartererId,
        hours = hours,
    })
end

local function setDoorState(player, args)
    local square = getCell():getGridSquare(args.x, args.y, args.z)
    local door = square and BarteringAIUtils.findDoorOnSquare(square)
    if not door then
        print(string.format("[Bartering][MP] setDoorState at %d,%d,%d found no door", args.x, args.y, args.z))
        return
    end
    if args.unlock then
        door:setLockedByKey(false)
        door:setIsLocked(false)
        door:syncIsoObject(false, 1, nil, nil)
    end
    if args.open and not door:IsOpen() then
        BarteringAIUtils.openDoorObject(door)
    end
    print(string.format("[Bartering][MP] setDoorState %d,%d,%d unlock=%s open=%s -> [%s]",
        args.x, args.y, args.z, tostring(args.unlock == true), tostring(args.open == true),
        BarteringAIUtils.doorFlags(door)))
end

local function setHireWindowOpen(player, args)
    BarteringAI.setHireWindowOpen(args.bartererId, true)
end

local function setHireWindowClosed(player, args)
    BarteringAI.setHireWindowOpen(args.bartererId, false)
end

local function openAmends(player, bartererId)
    print(string.format("[Bartering][Hostility] openAmends | hostile=%s pending=%s",
        tostring(Bartering.Hostility.isHostileTo(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsPendingFor(bartererId, player))))
    if not Bartering.Hostility.isHostileTo(bartererId, player) then
        return
    end
    Bartering.Hostility.openAmends(bartererId, player)
end

local function callOverToMakeAmends(player, bartererId)
    print(string.format("[Bartering][Hostility] callOver | hostile=%s pending=%s called=%s",
        tostring(Bartering.Hostility.isHostileTo(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsPendingFor(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsCalledFor(bartererId, player))))
    if not Bartering.Hostility.isHostileTo(bartererId, player)
        or not Bartering.Hostility.isAmendsPendingFor(bartererId, player) then
        return
    end
    BarteringAI.despawnBarterer(bartererId)
    Bartering.setRegistryRecord(Bartering.Registries.Call, bartererId, nil)
    BarteringAI.callBarterer(player, bartererId)
end

local function performAmendsOffer(player, args)
    local bartererId = args.bartererId
    print(string.format("[Bartering][Hostility] amendsOffer | hostile=%s pending=%s called=%s items=%s",
        tostring(Bartering.Hostility.isHostileTo(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsPendingFor(bartererId, player)),
        tostring(Bartering.Hostility.isAmendsCalledFor(bartererId, player)),
        tostring(args.offeredItems and #args.offeredItems or "nil")))
    if not Bartering.Hostility.isHostileTo(bartererId, player)
        or not Bartering.Hostility.isAmendsPendingFor(bartererId, player) then
        return
    end

    local offeredItems, offeredValue = collectOffer(player, args.offeredItems, bartererId)
    if not offeredItems then
        return
    end

    local cost = Bartering.Hostility.getAmendsCost(bartererId, player)
    if offeredValue < cost then
        print(string.format("[Bartering][Hostility] amendsOffer REJECTED | offered=%s cost=%s",
            tostring(offeredValue), tostring(cost)))
        return
    end

    removeOfferedItems(player, offeredItems)
    local restored = Bartering.Hostility.getRestoredRelation(bartererId, player)
    Bartering.Hostility.complete(bartererId, player)
    print(string.format("[Bartering][Hostility] amendsOffer accepted | offered=%s cost=%s restored=%s",
        tostring(offeredValue), tostring(cost), tostring(restored)))
    local record = Bartering.getLiveRecord(bartererId)
    if record and not record.unloaded then
        BarteringAIUtils.sayBarterer(bartererId, BarteringDialogue.Hostility.forgiven)
    end
    sendToPlayer(player, "bartererForgiven", { bartererId = bartererId })
end

local function requestStock(player, bartererId)
    Bartering.getBartererSlots(bartererId)
    Bartering.transmitBartererDataNow(bartererId)
    Bartering.broadcastToClients("bartererStockChanged", { bartererId = bartererId })
end

local ID_COMMANDS = {
    requestStock = requestStock,
    callBarterer = BarteringAI.callBarterer,
    radioStatus = BarteringAI.radioStatus,
    updateBartererLocation = BarteringAI.updateBartererCallLocation,
    sendBartererHome = BarteringAI.sendBartererHome,
    cancelBartererMeeting = BarteringAI.cancelBartererMeeting,
    stayHere = BarteringAI.acceptStayHere,
    continueToMeetup = BarteringAI.declineTradeHere,
    interceptDialogOpen = BarteringAI.noteInterceptDialog,
    meetBarterer = Bartering.meetBarterer,
    openAmends = openAmends,
    callOverToMakeAmends = callOverToMakeAmends,
    requestQuest = BarteringQuestServer.generate,
    turnInQuest = BarteringQuestServer.turnIn,
    debugSpawnBarterer = BarteringAI.debugSpawnBarterer,
    debugCallBarterer = BarteringAI.debugCallBarterer,
    debugKillBarterer = BarteringAI.debugKillBarterer,
    debugZombifyBarterer = BarteringAI.debugZombifyBarterer,
    debugBandageBarterer = BarteringAI.debugBandageBarterer,
    debugHurtBarterer = BarteringAI.debugHurtBarterer,
    debugResetQuest = BarteringQuestServer.debugResetQuest,
    debugRefreshQuest = BarteringQuestServer.debugRefreshQuest,
    debugTeleportToBarterer = teleportToBarterer,
}

local ARGS_COMMANDS = {
    attackedBarterer = BarteringAI.attackedBy,
    shovedBarterer = BarteringAI.shovedBy,
    trade = performTrade,
    hireBarterer = performHire,
    hireWindowOpen = setHireWindowOpen,
    hireWindowClosed = setHireWindowClosed,
    amendsOffer = performAmendsOffer,
    debugTriggerSale = debugTriggerSale,
    bartererReport = BarteringAI.handleReport,
    relaySay = BarteringAI.relaySay,
    relayShot = BarteringAI.relayShot,
    relaySound = BarteringAI.relaySound,
    removeZombie = BarteringAI.removeZombie,
    relayZombieHit = BarteringAI.relayZombieHit,
    relayPlayerHit = BarteringAI.relayPlayerHit,
    setDoorState = setDoorState,
}

local DEATH_CARRY_REGISTRY = "BarteringDeathCarry"

local function deathCarryKey(player)
    return isServer() and player:getUsername() or ("local" .. player:getPlayerNum())
end

local function carryPlayerTable(player, modDataKey)
    local copy = {}
    for key, value in pairs(player:getModData()[modDataKey] or {}) do
        copy[key] = value
    end
    return copy
end

local function resetPlayerBarterState(player)
    local keepRelations = not Bartering.getSandboxBoolean("ResetRelationshipOnDeath", true)
    local keepMet = not Bartering.getSandboxBoolean("ResetMetOnDeath", true)
    ModData.getOrCreate(DEATH_CARRY_REGISTRY)[deathCarryKey(player)] = {
        relations = keepRelations and carryPlayerTable(player, "BarteringRelations") or nil,
        met = keepMet and carryPlayerTable(player, "BarteringMetBarterers") or nil,
    }
    print(string.format("[Bartering][Death] %s died | keepRelations=%s keepMet=%s",
        deathCarryKey(player), tostring(keepRelations), tostring(keepMet)))

    Bartering.Hostility.clearForPlayer(player)
    for _, entry in ipairs(BarteringAI.barterers) do
        if entry.hostilePlayer == player then
            entry.hostilePlayer = nil
            entry.hostileFlee = nil
            entry.attackCooldown = nil
            entry.lastPlayerAttackAt = nil
        end
    end
    for bartererId in pairs(Bartering.Barterers) do
        if not keepRelations then
            Bartering.Relations.reset(player, bartererId)
        end
        if BarteringHire.isHiredBy(player, bartererId) then
            BarteringHire.clearHiredState(bartererId)
        end
    end
    BarteringAI.sendPlayerBarterersHome(player)
end

local function restoreCarriedBarterState(player)
    local registry = ModData.getOrCreate(DEATH_CARRY_REGISTRY)
    local key = deathCarryKey(player)
    local carry = registry[key]
    if not carry then
        return
    end
    registry[key] = nil
    local modData = player:getModData()
    if carry.relations then
        modData.BarteringRelations = carry.relations
    end
    if carry.met then
        modData.BarteringMetBarterers = carry.met
    end
    player:transmitModData()
    print(string.format("[Bartering][Death] %s new character | restoredRelations=%s restoredMet=%s",
        key, tostring(carry.relations ~= nil), tostring(carry.met ~= nil)))
end

local PLAYER_COMMANDS = {
    debugDespawnAllBarterers = BarteringAI.debugDespawnAll,
    playerDied = resetPlayerBarterState,
    playerCreated = restoreCarriedBarterState,
}

local function onClientCommand(module, command, player, args)
    if module ~= "Bartering" then
        return
    end

    if (command:sub(1, 5) == "debug" or command == "addRelations" or command == "dumpNamedZs")
        and not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end

    local idHandler = ID_COMMANDS[command]
    if idHandler then
        idHandler(player, args.bartererId)
        return
    end

    local argsHandler = ARGS_COMMANDS[command]
    if argsHandler then
        argsHandler(player, args)
        return
    end

    local playerHandler = PLAYER_COMMANDS[command]
    if playerHandler then
        playerHandler(player)
        return
    end

    if command == "addRelations" then
        Bartering.Relations.add(player, args.bartererId, 100)
    elseif command == "debugSpawnBartererAt" then
        BarteringAI.debugSpawnBartererAt(player, args.bartererId, args.x, args.y, args.z)
    elseif command == "debugDumpPathTrace" then
        BarteringPathTrace.dump()
    elseif command == "dumpNamedZs" then
        dumpNamedZs()
    end
end

events.OnClientCommand.Add(onClientCommand)
