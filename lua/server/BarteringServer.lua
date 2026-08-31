require "Bartering"
local BarteringPathTrace = require "BarteringPathTrace"

local events = _G["Events"]

local function teleportToBarterer(player, bartererId)
    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return
    end

    local x, y, z
    for i = #BarteringAI.barterers, 1, -1 do
        local entry = BarteringAI.barterers[i]
        if entry.bartererId == bartererId and entry.zombie and entry.zombie:getSquare() then
            x, y, z = entry.zombie:getX(), entry.zombie:getY(), entry.zombie:getZ()
            break
        end
    end
    if not x then
        x, y, z = barterer.x, barterer.y, barterer.z
    end

    player:setX(x + 0.5)
    player:setY(y + 0.5)
    player:setZ(z)
    player:setLx(x + 0.5)
    player:setLy(y + 0.5)
    player:setLz(z)
    print("[Bartering][ServerDebug] teleported " .. tostring(player:getUsername()) .. " to barterer " .. tostring(bartererId) .. " at " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
end

local function onClientCommand(module, command, player, args)
    if module ~= "Bartering" then
        return
    end

    local debugCommands = {
        ["debugSpawnBarterer"] = true,
        ["debugDespawnAllBarterers"] = true,
        ["debugSpawnBartererAt"] = true,
        ["debugCallBarterer"] = true,
        ["debugKillBarterer"] = true,
        ["debugZombifyBarterer"] = true,
        ["debugBandageBarterer"] = true,
        ["debugHurtBarterer"] = true,
        ["debugResetQuest"] = true,
        ["debugRefreshQuest"] = true,
        ["debugTriggerSale"] = true,
        ["debugTeleportToBarterer"] = true,
        ["debugDumpPathTrace"] = true,
        ["addRelations"] = true,
    }
    if debugCommands[command] and not Bartering.getSandboxBoolean("DebugMode", false) then
        return
    end

    if command == "callBarterer" then
        BarteringAI.callBarterer(player, args.bartererId)
        return
    end

    if command == "updateBartererLocation" then
        BarteringAI.updateBartererCallLocation(player, args.bartererId)
        return
    end

    if command == "debugSpawnBarterer" then
        BarteringAI.debugSpawnBarterer(player, args.bartererId)
        return
    end

    if command == "debugDespawnAllBarterers" then
        BarteringAI.debugDespawnAll(player)
        return
    end

    if command == "debugSpawnBartererAt" then
        BarteringAI.debugSpawnBartererAt(player, args.bartererId, args.x, args.y, args.z)
        return
    end

    if command == "debugCallBarterer" then
        BarteringAI.debugCallBarterer(player, args.bartererId)
        return
    end

    if command == "debugKillBarterer" then
        BarteringAI.debugKillBarterer(player, args.bartererId)
        return
    end

    if command == "debugZombifyBarterer" then
        BarteringAI.debugZombifyBarterer(player, args.bartererId)
        return
    end

    if command == "debugBandageBarterer" then
        BarteringAI.debugBandageBarterer(player, args.bartererId)
        return
    end

    if command == "debugHurtBarterer" then
        BarteringAI.debugHurtBarterer(player, args.bartererId)
        return
    end

    if command == "dumpNamedZs" then
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
            print(string.format("roomresolve\t%s\t%s%s\t%s", location.id, roomsCell, buildingCell, location.name))
        end
        return
    end

    if command == "debugTriggerSale" then
        local remaining = Bartering.triggerWeeklySale(args.bartererId)
        if remaining then
            print("[Bartering][ServerDebug] triggered sale for " .. tostring(args.bartererId) .. " for " .. tostring(remaining) .. " more hours")
        end
        return
    end

    if command == "debugTeleportToBarterer" then
        teleportToBarterer(player, args.bartererId)
        return
    end

    if command == "debugDumpPathTrace" then
        BarteringPathTrace.dump()
        return
    end

    if command == "meetBarterer" then
        Bartering.meetBarterer(player, args.bartererId)
        return
    end

    if command == "requestQuest" then
        BarteringQuestServer.generate(player, args.bartererId)
        return
    end

    if command == "turnInQuest" then
        BarteringQuestServer.turnIn(player, args.bartererId)
        return
    end

    if command == "debugResetQuest" then
        BarteringQuestServer.debugResetQuest(player, args.bartererId)
        return
    end

    if command == "debugRefreshQuest" then
        BarteringQuestServer.debugRefreshQuest(player, args.bartererId)
        return
    end

    if command == "attackedBarterer" then
        BarteringAI.attackedBy(player, args)
        return
    end

    if command == "shovedBarterer" then
        BarteringAI.shovedBy(player, args)
        return
    end

    if command == "recordTrade" then
        Bartering.awardTradeXp(player, args.offeredValue, args.receivedValue)
        return
    end

    if command == "trade" then
        local barterer = Bartering.Barterers[args.bartererId]
        if not barterer or Bartering.getBarterSkillLevel(player) < barterer.requiredLevel then
            return
        end

        local inventory = player:getInventory()
        local inventoryItems = inventory:getItems()
        local offeredItems = {}
        local offeredValue = 0
        local relationValue = 0
        for _, offeredItemArgs in ipairs(args.offeredItems) do
            local offeredItem
            for i = 0, inventoryItems:size() - 1 do
                local item = inventoryItems:get(i)
                if item:getID() == offeredItemArgs.id then
                    offeredItem = item
                    break
                end
            end
            if not offeredItem then
                return
            end
            if offeredItem:getFullType() ~= offeredItemArgs.itemName then
                return
            end
            local currentUnitCount = Bartering.getDrainableUnitCount(offeredItem)
            if currentUnitCount ~= offeredItemArgs.unitCount then
                return
            end
            if not Bartering.Quests.acceptsCoupon(offeredItem, args.bartererId) then
                return
            end
            table.insert(offeredItems, offeredItem)
            local itemValue = Bartering.getTradeValue(offeredItem, Bartering.ValueSide.Player, player, args.bartererId)
            offeredValue = offeredValue + itemValue
            if not Bartering.Quests.getCouponBarterer(offeredItem) then
                relationValue = relationValue + itemValue
            end
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

        for _, offeredItem in ipairs(offeredItems) do
            inventory:Remove(offeredItem)
        end
        for _, received in ipairs(args.receivedItems) do
            for _ = 1, received.qty do
                inventory:AddItem(received.itemName)
            end
        end
        Bartering.consumeBartererSlots(args.bartererId, stock, selectedStockIndexes)
        BarteringAI.syncBartererStock(args.bartererId, player)
        Bartering.awardTradeXp(player, offeredValue, receivedValue)
        Bartering.Relations.add(player, args.bartererId, relationValue)
        return
    end

    if command == "sendBartererHome" then
        BarteringAI.sendBartererHome(player, args.bartererId)
        return
    end

    if command == "cancelBartererMeeting" then
        BarteringAI.cancelBartererMeeting(player, args.bartererId)
    end

    if command == "addRelations" then
        Bartering.Relations.add(player, args.bartererId, 100)
    end
end

events.OnClientCommand.Add(onClientCommand)
