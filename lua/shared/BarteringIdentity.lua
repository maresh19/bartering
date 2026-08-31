Bartering = Bartering or {}

local ModData = _G["ModData"]
local SurvivorFactory = _G["SurvivorFactory"]
local SurvivorType = _G["SurvivorType"]
local ItemVisual = _G["ItemVisual"]
local BloodBodyPartType = _G["BloodBodyPartType"]

Bartering.AppearancePools = Bartering.AppearancePools or {
    tops = {
        "Base.Tshirt_WhiteTINT",
        "Base.Tshirt_DefaultTEXTURE_TINT",
        "Base.Shirt_Denim",
        "Base.Shirt_FormalWhite",
        "Base.Shirt_FormalWhite_ShortSleeve",
    },
    pants = {
        "Base.Trousers_Denim",
        "Base.Trousers_JeanBaggy",
        "Base.Trousers_WhiteTEXTURE",
    },
    shoes = {
        "Base.Shoes_ArmyBoots",
    },
    bags = {
        "Base.Bag_DuffelBag",
    },
    accessories = {
        "Base.Scarf_White",
    },
}

Bartering.BARTERER_BAG = "Base.Bag_DuffelBag"

function Bartering.getBartererBag(zombie)
    return zombie:getInventory():getFirstTypeRecurse(Bartering.BARTERER_BAG)
end

local function splitClothingString(encoded)
    local clothing = {}
    if not encoded or encoded == "" then
        return clothing
    end

    for itemType in string.gmatch(encoded, "([^;]+)") do
        table.insert(clothing, itemType)
    end
    return clothing
end

local function isValidBartererId(bartererId)
    return bartererId ~= nil and bartererId ~= ""
end

local function getGeneratedName(barterer)
    local desc = SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, barterer.gender == "female")
    SurvivorFactory.randomName(desc)
    return desc:getForename() .. " " .. desc:getSurname()
end

local function getGeneratedClothing()
    local clothing = {}
    for _, pool in ipairs({
        Bartering.AppearancePools.tops,
        Bartering.AppearancePools.pants,
        Bartering.AppearancePools.shoes,
        Bartering.AppearancePools.bags,
        Bartering.AppearancePools.accessories,
    }) do
        table.insert(clothing, Bartering.pickRandomListItem(pool))
    end
    return clothing
end

function Bartering.getBartererIdentityState(bartererId)
    return ModData.getOrCreate("BarteringIdentity_" .. (isValidBartererId(bartererId) and bartererId or "_missing"))
end

function Bartering.ensureBartererIdentity(bartererId, forceNew)
    if not isValidBartererId(bartererId) then
        return {
            fullName = "Unknown Barterer",
            clothing = {},
            female = false,
            visualString = nil,
        }
    end

    local barterer = Bartering.Barterers[bartererId]
    local state = Bartering.getBartererIdentityState(bartererId)
    if not Bartering.isBartererDataAuthority() then
        return state
    end
    if forceNew or not state.fullName or not state.clothing or #state.clothing == 0 then
        state.fullName = getGeneratedName(barterer)
        state.clothing = getGeneratedClothing()
        state.visualString = nil
        Bartering.markBartererDataDirty(bartererId)
    end
    if state.female == nil then
        state.female = barterer.gender == "female"
        Bartering.markBartererDataDirty(bartererId)
    end
    return state
end

function Bartering.getBartererDisplayName(bartererId)
    return Bartering.ensureBartererIdentity(bartererId).fullName or "Unknown Barterer"
end

function Bartering.getBartererClothing(bartererId)
    return Bartering.copyList(Bartering.ensureBartererIdentity(bartererId).clothing)
end

function Bartering.storeBartererIdentityOnZombie(zombie, bartererId)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    identity.female = zombie:isFemale()
    identity.visualString = zombie:getHumanVisual():getLastStandString()
    Bartering.markBartererDataDirty(bartererId)
    zombie:setVariable("BartererName", identity.fullName)
    zombie:setVariable("BartererClothing", table.concat(identity.clothing, ";"))
    zombie:setVariable("BartererVisualString", identity.visualString or "")
end

function Bartering.getBartererClothingFromZombie(zombie)
    return splitClothingString(zombie:getVariableString("BartererClothing"))
end

function Bartering.applyBartererIdentityToZombie(zombie, bartererId)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    zombie:setFemale(identity.female == true)
    zombie:setFemaleEtc(identity.female == true)
    if identity.visualString and identity.visualString ~= "" then
        zombie:getHumanVisual():loadLastStandString(identity.visualString)
    end
    zombie:resetModelNextFrame()
end

function Bartering.dressBartererZombie(zombie, identity)
    local inventory = zombie:getInventory()
    for _, itemType in ipairs(identity.clothing) do
        local clothing = inventory:AddItem(itemType)
        if clothing:IsInventoryContainer() then
            zombie:setWornItem(clothing:canBeEquipped(), clothing)
        else
            zombie:setWornItem(clothing:getBodyLocation(), clothing)
        end
    end
end

function Bartering.applyBartererVisuals(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    local clothingItems = Bartering.getBartererClothingFromZombie(zombie)
    if #clothingItems == 0 then
        clothingItems = Bartering.getBartererClothing(bartererId)
    end
    if #clothingItems == 0 then
        return
    end

    local visual = zombie:getHumanVisual()
    local visualString = zombie:getVariableString("BartererVisualString")
    if visualString and visualString ~= "" then
        visual:loadLastStandString(visualString)
    end

    local itemVisuals = zombie:getItemVisuals()
    itemVisuals:clear()
    for _, itemType in ipairs(clothingItems) do
        local clothing = ItemVisual.new()
        clothing:setItemType(itemType)
        clothing:setClothingItemName(itemType)
        itemVisuals:add(clothing)
    end

    visual:randomDirt()
    visual:removeBlood()
    local maxIndex = BloodBodyPartType.MAX:index()
    for i = 0, maxIndex - 1 do
        visual:setBlood(BloodBodyPartType.FromIndex(i), 0)
        visual:setDirt(BloodBodyPartType.FromIndex(i), 0)
    end

    zombie:resetModelNextFrame()
    zombie:setVariable("BartererVisualsApplied", true)
end
