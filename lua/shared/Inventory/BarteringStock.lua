local BarteringAIUtils = require "BarteringAIUtils"

Bartering = Bartering or {}

local getScriptManager = _G["getScriptManager"]
local ZombRand = _G["ZombRand"]
local ModData = _G["ModData"]
local instanceItem = _G["instanceItem"]

Bartering.Stock = Bartering.Stock or {}
Bartering.Stock.Categories = {
    "Food",
    "Ammo",
    "FirstAid",
    "Tool",
    "Container",
    "Literature",
    "Explosives",
    "WeaponPart",
    "SkillBook",
    "Junk",
}

Bartering.Stock.BonusCategories = {
    "Food",
    "Ammo",
    "FirstAid",
    "Tool",
    "Container",
    "Literature",
    "Explosives",
    "SkillBook",
    "WeaponPart",
}

Bartering.Stock.BaseCarryWeight = 18
Bartering.Stock.DuffelBagCapacity = 18
Bartering.Stock.DuffelBagEncumbranceReduction = 0.65

Bartering.Stock.SlotMaxQty = 3

function Bartering.Stock.getSlotMaxQty(itemName)
    if Bartering.Stock.isRareItem(itemName) then
        return 1
    end
    if Bartering.getCategoryName(itemName) == "WeaponPart" then
        return 1
    end
    return Bartering.Stock.SlotMaxQty
end

function Bartering.Stock.getEffectiveCapacity()
    return Bartering.Stock.BaseCarryWeight + Bartering.Stock.DuffelBagCapacity / (1 - Bartering.Stock.DuffelBagEncumbranceReduction)
end

function Bartering.Stock.isRareItem(itemName)
    if itemName == "Base.Sledgehammer" or itemName == "Base.Katana" then
        return true
    end
    for _, rare in ipairs(Bartering.Values.RareClothingItems) do
        if rare == itemName then
            return true
        end
    end
    return false
end

function Bartering.Stock.getItemWeight(itemName)
    local item = instanceItem(itemName)
    if not item then
        return 1
    end
    return item:getWeight()
end

function Bartering.Stock.getTotalWeight(stock)
    local total = 0
    for itemName, qty in pairs(stock) do
        total = total + Bartering.Stock.getItemWeight(itemName) * qty
    end
    return total
end

function Bartering.pickRandomItemFromGame(category)
    local itemDefinitions = getScriptManager():getAllItems()
    local candidateList = {}

    for i = 0, itemDefinitions:size() - 1 do
        local fullType = itemDefinitions:get(i):getFullName()
        if Bartering.getCategoryName(fullType) == category and Bartering.isBarterableItem(fullType) and not Bartering.isNonStockedItem(fullType) then
            table.insert(candidateList, fullType)
        end
    end

    return Bartering.pickRandomListItem(candidateList)
end

local function pickFittingQty(itemName, itemWeight, availableWeight)
    local maxQty = Bartering.Stock.getSlotMaxQty(itemName)
    local addQty = math.min(ZombRand(maxQty) + 1, maxQty)
    return math.max(0, math.min(addQty, math.floor(availableWeight / itemWeight)))
end

function Bartering.generateBartererStock(weightLimit, slotLimit)
    local stock = {}
    local wLimit = weightLimit or Bartering.Stock.getEffectiveCapacity()
    local slotsUsed = 0

    if ZombRand(1000) < 1 then
        stock["Base.Sledgehammer"] = 1
        slotsUsed = 1
    end

    if slotsUsed < slotLimit and ZombRand(100) < Bartering.Values.RareClothingChance then
        local rare = Bartering.pickRandomListItem(Bartering.Values.RareClothingItems)
        if rare then
            stock[rare] = 1
            slotsUsed = slotsUsed + 1
        end
    end

    local attempts = 0
    while slotsUsed < slotLimit and Bartering.Stock.getTotalWeight(stock) < wLimit and attempts < 200 do
        local category = Bartering.Stock.Categories[ZombRand(#Bartering.Stock.Categories) + 1]
        local itemName = Bartering.pickRandomItemFromGame(category)
        if itemName and not Bartering.Stock.isRareItem(itemName) and not stock[itemName]
            and Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer) > 0 then
            local itemWeight = Bartering.Stock.getItemWeight(itemName)
            local availableWeight = wLimit - Bartering.Stock.getTotalWeight(stock)
            local addQty = pickFittingQty(itemName, itemWeight, availableWeight)
            if addQty >= 1 then
                stock[itemName] = addQty
                slotsUsed = slotsUsed + 1
            end
        end
        attempts = attempts + 1
    end

    return stock
end

function Bartering.generateAdditionalBartererStock(existingStock, weightLimit, slotLimit)
    local slotsUsed = 0
    for _ in pairs(existingStock) do
        slotsUsed = slotsUsed + 1
    end
    if slotsUsed >= slotLimit then
        return {}
    end

    local currentWeight = Bartering.Stock.getTotalWeight(existingStock)
    local bonusWeightBudget = weightLimit - currentWeight
    if bonusWeightBudget <= 0 then
        return {}
    end

    local bonusStock = {}
    local bonusWeight = 0
    local attempts = 0
    while slotsUsed < slotLimit and bonusWeight < bonusWeightBudget and attempts < 200 do
        local category = Bartering.Stock.BonusCategories[ZombRand(#Bartering.Stock.BonusCategories) + 1]
        local itemName = Bartering.pickRandomItemFromGame(category)
        if itemName and not existingStock[itemName] and not bonusStock[itemName]
            and Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer) > 0 then
            local itemWeight = Bartering.Stock.getItemWeight(itemName)
            local availableWeight = bonusWeightBudget - bonusWeight
            if itemWeight <= availableWeight then
                local addQty = pickFittingQty(itemName, itemWeight, availableWeight)
                if addQty >= 1 then
                    bonusStock[itemName] = addQty
                    bonusWeight = bonusWeight + itemWeight * addQty
                    slotsUsed = slotsUsed + 1
                end
            end
        end
        attempts = attempts + 1
    end

    return bonusStock
end

local function getBartererStockState(bartererId)
    return ModData.getOrCreate("BarteringBarterer_" .. bartererId)
end

local function getStockRefreshHours()
    return Bartering.getSandboxNumber("BarterRefreshHours", 6)
end

local function getRefreshInterval(worldAgeHours)
    local interval = getStockRefreshHours()
    return math.floor(worldAgeHours / interval)
end

function Bartering.isBartererAwakeNow(bartererId)
    if Bartering.isBartererCallOpenNow(bartererId) then
        return true
    end
    return Bartering.getRegistryRecord(Bartering.Registries.Call, bartererId) ~= nil
        or Bartering.getRegistryRecord(Bartering.Registries.ReturningHome, bartererId) ~= nil
end

function Bartering.getBartererStockRefreshRemainingHours(bartererId)
    local anyAwake = false
    for id in pairs(Bartering.Barterers) do
        if Bartering.isBartererAwakeNow(id) then
            anyAwake = true
            break
        end
    end
    if not anyAwake then
        return getStockRefreshHours()
    end
    local interval = getStockRefreshHours()
    return math.max(0, interval - (getGameTime():getWorldAgeHours() % interval))
end

function Bartering.getStockRefreshInterval()
    return getRefreshInterval(getGameTime():getWorldAgeHours())
end

function Bartering.isBartererStockRefreshPending(bartererId)
    local state = getBartererStockState(bartererId)
    return not state.lastRefreshInterval
        or getRefreshInterval(getGameTime():getWorldAgeHours()) > state.lastRefreshInterval
end

function Bartering.shuffleSlots(slots)
    for i = #slots, 2, -1 do
        local j = ZombRand(i) + 1
        slots[i], slots[j] = slots[j], slots[i]
    end
    return slots
end

local RELATION_SLOT_BONUS = 2
local SKILL_SLOT_MILESTONES = { 3, 6, 9 }

function Bartering.getExtraSkillSlotMilestones(requiredLevel)
    local milestones = {}
    for _, milestone in ipairs(SKILL_SLOT_MILESTONES) do
        if milestone > requiredLevel then
            table.insert(milestones, milestone)
        end
    end
    return milestones
end

function Bartering.getSkillSlotCount(requiredLevel, playerLevel)
    local count = 0
    for _, milestone in ipairs(Bartering.getExtraSkillSlotMilestones(requiredLevel)) do
        if not playerLevel or milestone <= playerLevel then
            count = count + 1
        end
    end
    return count
end

function Bartering.getBartererRelationshipSlots(bartererId, player)
    if not player then
        return 0
    end
    local starCount = Bartering.Relations.getStarCount(player, bartererId)
    local slots = 0
    if starCount >= SandboxVars.Bartering.StockSlot1RelationshipStars then
        slots = slots + 1
    end
    if starCount >= SandboxVars.Bartering.StockSlot2RelationshipStars then
        slots = slots + 1
    end
    return slots
end

function Bartering.getBartererSlotCount(barterer)
    return barterer.stockCount + Bartering.getSkillSlotCount(barterer.requiredLevel) + RELATION_SLOT_BONUS
end

function Bartering.getVisibleSlotCount(barterer, player)
    local total = Bartering.getBartererSlotCount(barterer)
    if not player then
        return total
    end
    local relationSlots = Bartering.getBartererRelationshipSlots(barterer.id, player)
    return math.min(barterer.stockCount
        + Bartering.getSkillSlotCount(barterer.requiredLevel, Bartering.getBarterSkillLevel(player))
        + relationSlots, total)
end

local function buildSlots(barterer)
    local weightLimit = barterer.stockWeight
    local base = Bartering.generateBartererStock(weightLimit, barterer.stockCount)

    local slotArray = {}
    for itemName, qty in pairs(base) do
        slotArray[#slotArray + 1] = { name = itemName, qty = qty }
    end

    local extra = Bartering.generateAdditionalBartererStock(base, weightLimit,
        Bartering.getBartererSlotCount(barterer))
    for name, qty in pairs(extra) do
        slotArray[#slotArray + 1] = { name = name, qty = qty }
    end

    local sanitized = {}
    for _, slot in ipairs(slotArray) do
        if Bartering.isBarterableItem(slot.name) then
            table.insert(sanitized, slot)
        end
    end
    sanitized = Bartering.shuffleSlots(sanitized)

    local flat = {}
    for _, slot in ipairs(sanitized) do
        for _ = 1, slot.qty do
            flat[#flat + 1] = slot.name
        end
    end
    return flat
end

function Bartering.getBartererSlots(bartererId)
    local state = getBartererStockState(bartererId)
    local barterer = Bartering.Barterers[bartererId]
    local worldAgeHours = getGameTime():getWorldAgeHours()

    if not Bartering.isBartererDataAuthority() then
        return state.slots or {}
    end

    if not state.slots or not state.lastRefreshInterval
        or getRefreshInterval(worldAgeHours) > state.lastRefreshInterval then
        state.slots = buildSlots(barterer)
        state.lastRefreshInterval = getRefreshInterval(worldAgeHours)
        Bartering.markBartererDataDirty(bartererId)
        BarteringAI.syncBartererStock(bartererId)
    end

    return state.slots
end

function Bartering.getBartererStock(bartererId, player)
    local slots = Bartering.getBartererSlots(bartererId)
    local visible = Bartering.getVisibleSlotCount(Bartering.Barterers[bartererId], player)

    local list = {}
    local last = nil
    local runs = 0
    for _, itemName in ipairs(slots) do
        if Bartering.isBarterableItem(itemName) and Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer) > 0 then
            if itemName ~= last then
                runs = runs + 1
                last = itemName
                if runs > visible then
                    break
                end
            end
            table.insert(list, itemName)
        end
    end
    return list
end

function Bartering.getBartererStockMap(bartererId, player)
    local map = {}
    for _, itemName in ipairs(Bartering.getBartererStock(bartererId, player)) do
        map[itemName] = (map[itemName] or 0) + 1
    end
    return map
end

function Bartering.getSlotRequirementLabel(barterer, slotIndex)
    local totalSlots = Bartering.getBartererSlotCount(barterer)
    local skillMilestones = Bartering.getExtraSkillSlotMilestones(barterer.requiredLevel)
    if slotIndex <= barterer.stockCount then
        return "Lvl " .. tostring(barterer.requiredLevel) .. " Bartering"
    elseif slotIndex <= totalSlots - 2 then
        return "Lvl " .. tostring(skillMilestones[slotIndex - barterer.stockCount]) .. " Bartering"
    end
    local relationStar = SandboxVars.Bartering.StockSlot1RelationshipStars
    if slotIndex == totalSlots then
        relationStar = SandboxVars.Bartering.StockSlot2RelationshipStars
    end
    return "Lvl " .. tostring(relationStar) .. " Relationship"
end

function Bartering.getItemRequirementMap(bartererId)
    local requirementByItem = {}
    local orderByItem = {}
    local barterer = Bartering.Barterers[bartererId]
    local last = nil
    local slotIndex = 0
    for _, name in ipairs(Bartering.getBartererStock(bartererId)) do
        if name ~= last then
            last = name
            slotIndex = slotIndex + 1
            requirementByItem[name] = Bartering.getSlotRequirementLabel(barterer, slotIndex)
            orderByItem[name] = slotIndex
        end
    end
    return requirementByItem, orderByItem
end

function Bartering.clearBartererStock(bartererId)
    local state = getBartererStockState(bartererId)
    state.slots = nil
    state.lastRefreshInterval = nil
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.consumeBartererSlots(bartererId, stock, indexes)
    local counts = {}
    for i, itemName in ipairs(stock) do
        if indexes[i] then
            counts[itemName] = (counts[itemName] or 0) + 1
        end
    end
    local slots = Bartering.getBartererSlots(bartererId)
    for itemName, count in pairs(counts) do
        local removed = 0
        for i = #slots, 1, -1 do
            if removed < count and slots[i] == itemName then
                table.remove(slots, i)
                removed = removed + 1
            end
        end
    end
    Bartering.markBartererDataDirty(bartererId)
end

