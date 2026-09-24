Bartering = Bartering or {}
local print = require("BarteringPathTrace").log

local ModData = _G["ModData"]
local BarteringAIUtils = require "BarteringAIUtils"
local SurvivorFactory = _G["SurvivorFactory"]
local SurvivorType = _G["SurvivorType"]
local ItemVisual = _G["ItemVisual"]
local BloodBodyPartType = _G["BloodBodyPartType"]
local instanceItem = _G["instanceItem"]
local ImmutableColor = _G["ImmutableColor"]

Bartering.AppearancePools = Bartering.AppearancePools or {
    tops = {
        "Base.Shirt_Denim",
    },
    pants = {
        "Base.Trousers_Denim",
        "Base.Trousers_JeanBaggy",
    },
    shoes = {
        "Base.Shoes_ArmyBoots",
    },
    bags = {
        "Base.Bag_DuffelBag",
    },
    accessories = {
    },
}

Bartering.BARTERER_BAG = "Base.Bag_DuffelBag"

function Bartering.getBartererBag(zombie)
    return zombie:getInventory():getFirstTypeRecurse(Bartering.BARTERER_BAG)
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
        state.clothingQuestDone = nil
        state.clothingVisuals = nil
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

function Bartering.captureBartererIdentity(zombie, bartererId)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    identity.female = zombie:isFemale()
    identity.visualString = zombie:getHumanVisual():getLastStandString()
    Bartering.markBartererDataDirty(bartererId)
end

local HUMAN_SKIN_COUNT = 5

local function applyHumanSkin(zombie, visual)
    local skin = visual:getSkinTexture()
    if skin:find("^FemaleBody") or skin:find("^MaleBody") then
        return nil
    end
    local index = visual:getSkinTextureIndex() % HUMAN_SKIN_COUNT + 1
    local humanSkin
    if zombie:isFemale() then
        humanSkin = "FemaleBody0" .. tostring(index)
    else
        humanSkin = "MaleBody0" .. tostring(index) .. "a"
    end
    visual:setSkinTextureName(humanSkin)
    return skin, humanSkin
end

local function zombieDamageVisuals(visual)
    local damaged = {}
    local bodyVisuals = visual:getBodyVisuals()
    for i = 0, bodyVisuals:size() - 1 do
        local itemType = bodyVisuals:get(i):getItemType()
        if itemType and itemType:find("ZedDmg") then
            table.insert(damaged, itemType)
        end
    end
    return damaged
end

local function loadHumanVisual(zombie, identity, bartererId)
    local visual = zombie:getHumanVisual()
    if identity.visualString and identity.visualString ~= "" then
        visual:loadLastStandString(identity.visualString)
    end
    for _, itemType in ipairs(zombieDamageVisuals(visual)) do
        visual:removeBodyVisualFromItemType(itemType)
    end
    local zombieSkin, humanSkin = applyHumanSkin(zombie, visual)
    if zombieSkin then
        print("[Bartering][Visual] " .. tostring(bartererId) .. " zombie skin " .. zombieSkin .. " replaced with " .. humanSkin)
    end
end

function Bartering.applyBartererIdentityToZombie(zombie, bartererId)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    zombie:setFemale(identity.female == true)
    zombie:setFemaleEtc(identity.female == true)
    loadHumanVisual(zombie, identity, bartererId)
    zombie:resetModelNextFrame()
end

function Bartering.getBartererClothingVisual(identity, itemType)
    return identity.clothingVisuals and identity.clothingVisuals[itemType]
end

function Bartering.applyClothingVisual(itemVisual, stored)
    itemVisual:setTint(ImmutableColor.new(stored.tint.r, stored.tint.g, stored.tint.b, 1))
    itemVisual:setBaseTexture(stored.baseTexture)
    itemVisual:setTextureChoice(stored.textureChoice)
end

function Bartering.captureClothingVisual(item)
    local visual = item:getVisual()
    local tint = visual:getTint(item:getClothingItem())
    return {
        textureChoice = visual:getTextureChoice(),
        baseTexture = visual:getBaseTexture(),
        tint = { r = tint:getRedFloat(), g = tint:getGreenFloat(), b = tint:getBlueFloat() },
    }
end

function Bartering.dressBartererZombie(zombie, identity)
    local inventory = zombie:getInventory()
    identity.clothingVisuals = identity.clothingVisuals or {}
    for _, itemType in ipairs(identity.clothing) do
        local clothing = inventory:AddItem(itemType)
        local stored = identity.clothingVisuals[itemType]
        if not stored then
            stored = Bartering.captureClothingVisual(clothing)
            identity.clothingVisuals[itemType] = stored
            print(string.format("[Bartering][Visual] %s locked %s texture=%s base=%s tint=%.2f,%.2f,%.2f",
                zombie:getVariableString("BartererId"), itemType, tostring(stored.textureChoice),
                tostring(stored.baseTexture), stored.tint.r, stored.tint.g, stored.tint.b))
        end
        Bartering.applyClothingVisual(clothing:getVisual(), stored)
        if clothing:IsInventoryContainer() then
            zombie:setWornItem(clothing:canBeEquipped(), clothing)
        else
            zombie:setWornItem(clothing:getBodyLocation(), clothing)
        end
    end
end

function Bartering.getWearBumpType(itemType)
    local location = instanceItem(itemType):getBodyLocation()
    if location == ItemBodyLocation.HAT then
        return "WearHat"
    end
    if location == ItemBodyLocation.JACKET then
        return "WearJacket"
    end
    print(string.format("[Bartering][Visual] no wear bump for %s location=%s", itemType, tostring(location)))
end

function Bartering.giveBartererQuestClothing(bartererId, itemType, visual)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    local location = instanceItem(itemType):getBodyLocation()
    local replacedType
    local clothing = {}
    for _, existing in ipairs(identity.clothing) do
        local existingItem = instanceItem(existing)
        if not existingItem:IsInventoryContainer() and existingItem:getBodyLocation() == location then
            replacedType = existing
        else
            table.insert(clothing, existing)
        end
    end
    table.insert(clothing, itemType)
    identity.clothing = clothing
    identity.clothingVisuals = identity.clothingVisuals or {}
    if replacedType then
        identity.clothingVisuals[replacedType] = nil
    end
    identity.clothingVisuals[itemType] = visual
    identity.clothingQuestDone = true
    Bartering.markBartererDataDirty(bartererId)
    return replacedType
end

function Bartering.wearBartererClothing(zombie, bartererId, itemType, replacedType)
    local inventory = zombie:getInventory()
    if replacedType then
        inventory:Remove(inventory:getFirstTypeRecurse(replacedType))
    end
    local worn = inventory:AddItem(itemType)
    Bartering.applyClothingVisual(worn:getVisual(),
        Bartering.getBartererClothingVisual(Bartering.ensureBartererIdentity(bartererId), itemType))
    zombie:setWornItem(worn:getBodyLocation(), worn)
    Bartering.captureBartererIdentity(zombie, bartererId)
    Bartering.applyBartererVisuals(zombie)
end

function Bartering.describeItemVisuals(zombie)
    local itemVisuals = zombie:getItemVisuals()
    local types = {}
    for i = 0, itemVisuals:size() - 1 do
        table.insert(types, tostring(itemVisuals:get(i):getItemType()))
    end
    return table.concat(types, ";")
end

function Bartering.bartererVisualsMatch(zombie, clothingItems)
    local itemVisuals = zombie:getItemVisuals()
    if itemVisuals:size() ~= #clothingItems then
        return false
    end
    local expected = {}
    for _, itemType in ipairs(clothingItems) do
        expected[itemType] = (expected[itemType] or 0) + 1
    end
    for i = 0, itemVisuals:size() - 1 do
        local itemType = itemVisuals:get(i):getItemType()
        if not expected[itemType] or expected[itemType] == 0 then
            return false
        end
        expected[itemType] = expected[itemType] - 1
    end
    return true
end

function Bartering.applyBartererVisuals(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    local identity = Bartering.ensureBartererIdentity(bartererId)
    loadHumanVisual(zombie, identity, bartererId)

    local visual = zombie:getHumanVisual()
    local itemVisuals = zombie:getItemVisuals()
    itemVisuals:clear()
    for _, itemType in ipairs(identity.clothing) do
        local clothing = ItemVisual.new()
        clothing:setItemType(itemType)
        clothing:setClothingItemName(itemType)
        local stored = Bartering.getBartererClothingVisual(identity, itemType)
        if stored then
            Bartering.applyClothingVisual(clothing, stored)
        end
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
    zombie:resetModel()
end

local lastRedressFrom = {}

local function keepBartererDressed(zombie, bartererId)
    local clothingItems = Bartering.ensureBartererIdentity(bartererId).clothing
    if not clothingItems or (Bartering.bartererVisualsMatch(zombie, clothingItems)
        and #zombieDamageVisuals(zombie:getHumanVisual()) == 0) then
        return
    end
    local worn = Bartering.describeItemVisuals(zombie)
    if lastRedressFrom[bartererId] ~= worn then
        lastRedressFrom[bartererId] = worn
        print("[Bartering][Visual] " .. bartererId .. " redress from [" .. worn .. "] to [" .. table.concat(clothingItems, ";") .. "]")
    end
    Bartering.applyBartererVisuals(zombie)
end

local function holdCombatWeapon(zombie, bartererId, bartererState)
    if bartererState ~= "DefendPistol" and bartererState ~= "DefendKnife" then
        return
    end

    local barterer = Bartering.Barterers[bartererId]
    if not barterer then
        return
    end

    local gun = Bartering.getBartererWeapon(bartererId)
    local isRanged = bartererState == "DefendPistol"
    local expectedItemType = isRanged and gun.item or barterer.equipment.knife
    local expectedWeapon = isRanged and gun.weaponType or "Knife"
    local expectedPrimaryType = isRanged and gun.primaryType or "onehanded"

    if zombie:getVariableString("BartererWeapon") ~= expectedWeapon then
        zombie:setVariable("BartererWeapon", expectedWeapon)
    end
    if zombie:getVariableString("BartererPrimaryType") ~= expectedPrimaryType then
        zombie:setVariable("BartererPrimaryType", expectedPrimaryType)
    end

    local primary = zombie:getPrimaryHandItem()
    if primary and primary:getFullType() == expectedItemType then
        return
    end

    local desired = zombie:getInventory():getFirstTypeRecurse(expectedItemType)
    if desired then
        zombie:setPrimaryHandItem(desired)
    end
end

function Bartering.refreshBartererVisuals(zombie, bartererState)
    local bartererId = zombie:getVariableString("BartererId")
    holdCombatWeapon(zombie, bartererId, bartererState)
    keepBartererDressed(zombie, bartererId)
end

function Bartering.provisionBartererZombie(zombie, bartererId)
    zombie:setDressInRandomOutfit(false)
    zombie:setNoTeeth(true)
    zombie:setReanim(false)
    zombie:clearAggroList()
    zombie:setVariable("Barterer", true)
    zombie:setVariable("BartererId", bartererId)
    BarteringAIUtils.clearGoal(zombie, "provision")
    zombie:setVariable("ZombieHitReaction", "Chainsaw")
    zombie:setVariable("MovementSpeed", "1.00")
    zombie:setTurnAlertedValues(-5, 5)
    zombie:setWalkType("BartererWalk")
    zombie:setVariable("BartererWalkType", "BartererWalk")
    zombie:resetEquippedHandsModels()
    zombie:clearAttachedItems()
end

local function ensureLocalItem(zombie, itemType)
    local inventory = zombie:getInventory()
    if not inventory:getFirstTypeRecurse(itemType) then
        inventory:AddItem(itemType)
    end
end

function Bartering.adoptBartererZombie(zombie, bartererId, record)
    if zombie:getVariableString("BartererId") ~= bartererId then
        Bartering.provisionBartererZombie(zombie, bartererId)
        ensureLocalItem(zombie, Bartering.getBartererWeapon(bartererId).item)
        ensureLocalItem(zombie, Bartering.Barterers[bartererId].equipment.knife)
        Bartering.applyBartererIdentityToZombie(zombie, bartererId)
        zombie:setVariable("BartererState", record.state or "")
        print(string.format("[Bartering][MP] adopted %s zid=%s seq=%s remote=%s pos=%.1f,%.1f,%.1f health=%.2f prone=%s outfit=%s visuals=%d curState=%s",
            tostring(bartererId), tostring(zombie:getOnlineID()), tostring(record.seq),
            tostring(zombie:isRemoteZombie()), zombie:getX(), zombie:getY(), zombie:getZ(),
            zombie:getHealth(), tostring(zombie:isProne()), tostring(zombie:getPersistentOutfitID()),
            zombie:getItemVisuals():size(), tostring(zombie:getCurrentStateName())))
    end
    zombie:setVariable("BartererCalledIn", record.homeResident ~= true)
    zombie:setVariable("BartererIntercepted", record.intercepted == true)
    if zombie:getVariableString("BartererMasterName") ~= (record.master or "") then
        zombie:setVariable("BartererMasterName", record.master or "")
    end
    if isClient() and zombie:isRemoteZombie() and record.state and zombie:getVariableString("BartererState") ~= record.state then
        zombie:setVariable("BartererState", record.state)
    end
end

function Bartering.releaseBartererZombie(zombie)
    zombie:setVariable("Barterer", false)
    zombie:setVariable("BartererId", "")
    zombie:setVariable("BartererState", "")
    zombie:setVariable("BartererMasterName", "")
    zombie:setPrimaryHandItem(nil)
    zombie:setSecondaryHandItem(nil)
    zombie:setUseless(false)
    zombie:setNoTeeth(false)
    zombie:setReanim(false)
    zombie:setWalkType("2")
    zombie:setVariable("BumpAnimFinished", true)
    zombie:setBumpType("")
    zombie:setZombiesDontAttack(false)
    zombie:resetEquippedHandsModels()
    zombie:clearAttachedItems()
end
