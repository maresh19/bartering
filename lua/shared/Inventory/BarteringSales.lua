Bartering = Bartering or {}

local ZombRand = _G["ZombRand"]
local ModData = _G["ModData"]

local function getBartererSaleState(bartererId)
    return ModData.getOrCreate("BarteringBarterer_" .. bartererId)
end

local function getGameSaleSeed()
    local state = ModData.getOrCreate("BarteringSaleSeed")
    if not state.seed then
        state.seed = ZombRand(1000000)
    end
    return state.seed
end

local function saleHash(bartererId, weekNumber, dayInWeek)
    local seed = tostring(getGameSaleSeed()) .. "@" .. tostring(bartererId) .. "@" .. tostring(weekNumber) .. "@" .. tostring(dayInWeek)
    local hash = 5381
    for i = 1, #seed do
        hash = (hash * 33 + seed:byte(i)) % 2147483647
    end
    return hash % 7
end

local function getSaleDayWithinWeek(bartererId, weekNumber)
    for dayInWeek = 0, 5 do
        if saleHash(bartererId, weekNumber, dayInWeek) == 0 then
            return dayInWeek
        end
    end
    return 6
end

function Bartering.isBartererSaleActive(bartererId)
    if not Bartering.isBartererCallOpenNow(bartererId) then
        return false
    end
    local state = getBartererSaleState(bartererId)
    local dayIndex = math.floor(getGameTime():getWorldAgeHours() / 24)
    if state.saleTriggerDay == dayIndex then
        return true
    end
    if not Bartering.getSandboxBoolean("SaleDays", true) then
        return false
    end
    return (dayIndex % 7) == getSaleDayWithinWeek(bartererId, math.floor(dayIndex / 7))
end

function Bartering.isBartererSaleCallAnnounced(bartererId)
    local state = getBartererSaleState(bartererId)
    return state.saleCallAnnouncedDay == math.floor(getGameTime():getWorldAgeHours() / 24)
end

function Bartering.markBartererSaleCallAnnounced(bartererId)
    local state = getBartererSaleState(bartererId)
    state.saleCallAnnouncedDay = math.floor(getGameTime():getWorldAgeHours() / 24)
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.triggerWeeklySale(bartererId)
    if not Bartering.isBartererDataAuthority() then
        return false
    end
    local state = getBartererSaleState(bartererId)
    local worldAgeHours = getGameTime():getWorldAgeHours()
    local day = math.floor(worldAgeHours / 24)
    state.saleTriggerDay = day
    local untilHour = (day + 1) * 24
    Bartering.markBartererDataDirty(bartererId)
    return untilHour - worldAgeHours
end

function Bartering.isBartererItemOnSale(bartererId, itemName, player)
    if not Bartering.isBartererSaleActive(bartererId) then
        return false
    end
    local seen = {}
    local names = {}
    for _, name in ipairs(Bartering.getBartererSlots(bartererId)) do
        if Bartering.isBarterableItem(name) and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    table.sort(names)
    local discounted = math.floor(#names * Bartering.Values.BartererSaleItemFraction)
    for i = 1, discounted do
        if names[i] == itemName then
            return true
        end
    end
    return false
end