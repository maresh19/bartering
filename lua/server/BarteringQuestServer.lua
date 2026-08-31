require "Bartering"
require "BarteringQuests"

BarteringQuestServer = BarteringQuestServer or {}

local events = _G["Events"]
local getWorld = _G["getWorld"]
local getCell = _G["getCell"]
local getGameTime = _G["getGameTime"]
local ZombRand = _G["ZombRand"]
local InventoryItemFactory = _G["InventoryItemFactory"]
local sendServerCommand = _G["sendServerCommand"]
local BarteringAIUtils = require "BarteringAIUtils"
local ArrayList = _G["ArrayList"]

local PLACEMENT_TICK_INTERVAL = 30
local placementTicks = 0

local function getCandidateTowns(barterer)
    local homeTown = Bartering.Quests.getTownAt(barterer.x, barterer.y)
    local candidates = {}
    for _, town in ipairs(Bartering.Quests.Towns) do
        if not homeTown or town.id ~= homeTown.id then
            table.insert(candidates, town)
        end
    end
    for i = #candidates, 2, -1 do
        local j = ZombRand(i) + 1
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    return candidates
end

local function pickPersonalRoom(buildingDef)
    local rooms = buildingDef:getRooms()
    local candidates = {}
    for i = 0, rooms:size() - 1 do
        local roomDef = rooms:get(i)
        if Bartering.Quests.isUsableRoom(roomDef)
                and Bartering.Quests.isPersonalRoom(roomDef:getName()) then
            table.insert(candidates, roomDef)
        end
    end
    return Bartering.pickRandomListItem(candidates)
end

local function isRoomTile(metaGrid, roomDef, x, y, level)
    local found = metaGrid:getRoomAt(x, y, level)
    return found and found:getID() == roomDef:getID()
end

local function pickRoomTile(metaGrid, roomDef)
    local level = roomDef:getZ()
    local x1, y1 = roomDef:getX(), roomDef:getY()
    local x2, y2 = roomDef:getX2(), roomDef:getY2()
    local centreX = math.floor((x1 + x2) / 2)
    local centreY = math.floor((y1 + y2) / 2)

    if isRoomTile(metaGrid, roomDef, centreX, centreY, level) then
        return centreX, centreY
    end

    local bestX, bestY, bestDistance
    for y = y1, y2 do
        for x = x1, x2 do
            if isRoomTile(metaGrid, roomDef, x, y, level) then
                local distance = BarteringAIUtils.distanceSq(x, y, centreX, centreY)
                if not bestDistance or distance < bestDistance then
                    bestX, bestY, bestDistance = x, y, distance
                end
            end
        end
    end

    return bestX, bestY
end

local function getTownNamedLocations(townId)
    local named = {}
    for _, location in ipairs(Bartering.NamedPlaces.getLocations()) do
        if location.townId == townId then
            table.insert(named, location)
        end
    end
    for i = #named, 2, -1 do
        local j = ZombRand(i) + 1
        named[i], named[j] = named[j], named[i]
    end
    return named
end

local function namedForTile(townId, buildingDef, x, y)
    local metaGrid = getWorld():getMetaGrid()
    local best, bestDist
    for _, location in ipairs(Bartering.NamedPlaces.getLocations()) do
        if location.townId == townId and buildingDef
                and metaGrid:getBuildingAt(location.x, location.y) == buildingDef then
            local dist = math.abs(location.x - x) + math.abs(location.y - y)
            if not bestDist or dist < bestDist then
                best, bestDist = location, dist
            end
        end
    end
    if not best then
        for _, location in ipairs(Bartering.NamedPlaces.getLocations()) do
            if location.townId == townId then
                local dx = math.abs(location.x - x)
                local dy = math.abs(location.y - y)
                if dx <= location.radius and dy <= location.radius then
                    local dist = dx + dy
                    if not bestDist or dist < bestDist then
                        best, bestDist = location, dist
                    end
                end
            end
        end
    end
    return best
end

local function findNamedRoom(town, themed)
    local metaGrid = getWorld():getMetaGrid()
    local fallback
    for _, location in ipairs(getTownNamedLocations(town.id)) do
        local buildingDef = metaGrid:getBuildingAt(location.x, location.y)
        if buildingDef then
            local rooms = buildingDef:getRooms()
            for i = 0, rooms:size() - 1 do
                local roomDef = rooms:get(i)
                if Bartering.Quests.isUsableRoom(roomDef) then
                    local tileX, tileY = pickRoomTile(metaGrid, roomDef)
                    if tileX then
                        if themed and Bartering.Quests.getThemeForRoom(roomDef:getName()) then
                            return buildingDef, roomDef, tileX, tileY, namedForTile(town.id, buildingDef, tileX, tileY)
                        elseif not fallback then
                            fallback = { buildingDef, roomDef, tileX, tileY }
                        end
                    end
                end
            end
        end
    end
    if fallback then
        return fallback[1], fallback[2], fallback[3], fallback[4], namedForTile(town.id, fallback[1], fallback[3], fallback[4])
    end
    return nil, nil, nil, nil, nil
end

local function findPersonalRoom(town)
    local metaGrid = getWorld():getMetaGrid()
    local spanX = town.x2 - town.x1 + 1
    local spanY = town.y2 - town.y1 + 1
    for _ = 1, Bartering.Quests.BUILDING_SAMPLES do
        local buildingDef = metaGrid:getBuildingAt(town.x1 + ZombRand(spanX), town.y1 + ZombRand(spanY))
        if buildingDef then
            local roomDef = pickPersonalRoom(buildingDef)
            if roomDef then
                local tileX, tileY = pickRoomTile(metaGrid, roomDef)
                if tileX then
                    return buildingDef, roomDef, tileX, tileY, nil
                end
            end
        end
    end
    return nil, nil, nil, nil, nil
end

function BarteringQuestServer.generate(player, bartererId)
    if not Bartering.Quests.canRequest(player, bartererId) then
        return
    end

    local barterer = Bartering.Barterers[bartererId]
    local candidates = getCandidateTowns(barterer)
    local town, buildingDef, roomDef, tileX, tileY, questNamedLoc
    local chosenStrategy
    local strategies
    if ZombRand(10) < 2 then
        strategies = { "old", "generic", "themed" }
    elseif ZombRand(2) == 0 then
        strategies = { "themed", "generic", "old" }
    else
        strategies = { "generic", "themed", "old" }
    end
    for _, strategy in ipairs(strategies) do
        for _, candidate in ipairs(candidates) do
            local building, room, xor, yor, namedLoc
            if strategy == "themed" then
                building, room, xor, yor, namedLoc = findNamedRoom(candidate, true)
            elseif strategy == "generic" then
                building, room, xor, yor, namedLoc = findNamedRoom(candidate, false)
            else
                building, room, xor, yor, namedLoc = findPersonalRoom(candidate)
            end
            if room then
                buildingDef, roomDef, tileX, tileY, questNamedLoc = building, room, xor, yor, namedLoc
                chosenStrategy = strategy
                town = candidate
                break
            end
        end
        if roomDef then
            break
        end
    end

    if not roomDef then
        print("[Bartering][Quest] no usable room found for " .. tostring(bartererId))
        return
    end

    local theme = Bartering.Quests.getThemeForRoom(roomDef:getName())
    if not theme and chosenStrategy == "themed" then
        theme = ZombRand(2) == 0 and "video" or "music"
    end
    local itemType, itemLabel, itemName, title, complaint
    if theme == "video" then
        title = Bartering.pickRandomListItem(Bartering.Quests.VideoTitles)
        itemType = "Base.VHS_Retail"
        itemLabel = "VHS-Retail"
        itemName = string.format("Copy of '%s'", title)
    elseif theme == "music" then
        title = Bartering.pickRandomListItem(Bartering.Quests.MusicTitles)
        itemType = "Base.Disc_Retail"
        itemLabel = "CD"
        itemName = string.format("Copy of '%s'", title)
    elseif theme == "liquor" then
        itemType = Bartering.Quests.LiquorItemType
        itemLabel = Bartering.Quests.LiquorItemName
        itemName = Bartering.Quests.LiquorItemName
    elseif theme == "medicine" then
        local med = Bartering.pickRandomListItem(Bartering.Quests.MedicineMeds)
        itemType = "Base.Pills"
        itemLabel = med.itemName
        itemName = med.itemName
        complaint = med.complaint
    else
        local excludeTools = not Bartering.Quests.isPersonalRoom(roomDef:getName())
        itemType = Bartering.pickRandomListItem(Bartering.Quests.getRequestableItems(excludeTools))
        itemLabel = Bartering.Quests.getItemLabel(itemType)
        itemName = Bartering.Quests.buildItemName(bartererId, itemLabel)
    end

    local namedFloor0Room
    if questNamedLoc then
        local room0 = getWorld():getMetaGrid():getRoomAt(questNamedLoc.x, questNamedLoc.y, 0)
        if room0 and not Bartering.Quests.ExcludedRooms[room0:getName()] then
            namedFloor0Room = room0:getName()
        end
    end

    local quest = {
        id = string.format("%s_%d_%d", bartererId, math.floor(getGameTime():getWorldAgeHours() * 60), ZombRand(100000)),
        bartererId = bartererId,
        itemType = itemType,
        itemLabel = itemLabel,
        itemName = itemName,
        theme = theme,
        title = title,
        complaint = complaint,
        townId = town.id,
        townName = town.name,
        roomName = roomDef:getName(),
        namedId = questNamedLoc and questNamedLoc.id,
        namedFloor0Room = namedFloor0Room,
        x = tileX,
        y = tileY,
        z = roomDef:getZ(),
        bx1 = buildingDef:getX(),
        by1 = buildingDef:getY(),
        bx2 = buildingDef:getX2(),
        by2 = buildingDef:getY2(),
        placed = false,
        acceptedAt = getGameTime():getWorldAgeHours(),
    }

    Bartering.Quests.getPlayerState(player).active[bartererId] = quest
    player:transmitModData()

    print(string.format("[Bartering][Quest] %s -> %s in %s (%s) at %d,%d,%d",
        Bartering.getBartererDisplayName(bartererId), quest.itemName, quest.townName, quest.roomName,
        quest.x, quest.y, quest.z))

    sendServerCommand(player, "Bartering", "questUpdated", { bartererId = bartererId })
end

local function pickRoomContainer(room)
    local containers = {}
    local squares = room:getSquares()
    for i = 0, squares:size() - 1 do
        local objects = squares:get(i):getObjects()
        for j = 0, objects:size() - 1 do
            local container = objects:get(j):getContainer()
            if container then
                table.insert(containers, container)
            end
        end
    end
    return Bartering.pickRandomListItem(containers)
end

local function placeQuestItem(quest)
    local square = getCell():getGridSquare(quest.x, quest.y, quest.z)
    if not square then
        return false
    end

    local item = InventoryItemFactory.CreateItem(quest.itemType)
    item:setName(quest.itemName)
    item:getModData().BarteringQuestId = quest.id
    item:getModData().BarteringQuestBarterer = quest.bartererId

    local container = pickRoomContainer(square:getRoom())
    if container then
        container:AddItem(item)
    else
        square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
    end

    print(string.format("[Bartering][Quest] placed %s at %d,%d,%d (%s)",
        quest.itemName, quest.x, quest.y, quest.z, container and "container" or "floor"))
    return true
end

local function removeQuestItem(player, quest)
    local square = getCell():getGridSquare(quest.x, quest.y, quest.z)
    if square then
        local room = square:getRoom()
        if room then
            local squares = room:getSquares()
            for i = 0, squares:size() - 1 do
                local objects = squares:get(i):getObjects()
                for j = 0, objects:size() - 1 do
                    local container = objects:get(j):getContainer()
                    if container then
                        local items = container:getItems()
                        for k = items:size() - 1, 0, -1 do
                            local item = items:get(k)
                            if item:getModData().BarteringQuestId == quest.id then
                                container:Remove(item)
                            end
                        end
                    end
                end
            end
        end
    end
    local held = player:getInventory():getAllEvalRecurse(
        function(item) return item:getModData().BarteringQuestId == quest.id end,
        ArrayList.new())
    for i = 0, held:size() - 1 do
        local item = held:get(i)
        item:getContainer():Remove(item)
    end
end

local function onTick()
    placementTicks = placementTicks + 1
    if placementTicks < PLACEMENT_TICK_INTERVAL then
        return
    end
    placementTicks = 0

    BarteringAIUtils.forEachPlayer(function(player)
        local placedAny = false
        for _, quest in pairs(Bartering.Quests.getPlayerState(player).active) do
            if not quest.placed and placeQuestItem(quest) then
                quest.placed = true
                placedAny = true
            end
        end
        if placedAny then
            player:transmitModData()
        end
    end)
end

function BarteringQuestServer.turnIn(player, bartererId)
    local state = Bartering.Quests.getPlayerState(player)
    local quest = state.active[bartererId]
    if not quest then
        return
    end

    local item = Bartering.Quests.findQuestItem(player, quest)
    if not item then
        return
    end

    item:getContainer():Remove(item)
    Bartering.Relations.add(player, bartererId, Bartering.Quests.REWARD)
    player:getInventory():AddItem(Bartering.Quests.createCoupon(bartererId))
    state.active[bartererId] = nil
    Bartering.Quests.startCooldown(player, bartererId)
    player:transmitModData()

    print(string.format("[Bartering][Quest] %s turned in to %s for %d relations and a coupon",
        quest.itemName, Bartering.getBartererDisplayName(bartererId), Bartering.Quests.REWARD))

    sendServerCommand(player, "Bartering", "questUpdated", { bartererId = bartererId })
end

function BarteringQuestServer.debugResetQuest(player, bartererId)
    local state = Bartering.Quests.getPlayerState(player)
    state.active[bartererId] = nil
    state.cooldown[bartererId] = nil
    player:transmitModData()
    sendServerCommand(player, "Bartering", "questUpdated", { bartererId = bartererId })
end

function BarteringQuestServer.debugRefreshQuest(player, bartererId)
    local state = Bartering.Quests.getPlayerState(player)
    local quest = state.active[bartererId]
    if not quest then
        return
    end
    removeQuestItem(player, quest)
    state.active[bartererId] = nil
    player:transmitModData()
    BarteringQuestServer.generate(player, bartererId)
end

events.OnTick.Add(onTick)

return BarteringQuestServer
