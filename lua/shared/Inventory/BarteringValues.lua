Bartering = Bartering or {}
Bartering.Values = Bartering.Values or {}
local instanceItem = _G["instanceItem"]
local instanceof = _G["instanceof"]
local getScriptManager = _G["getScriptManager"]
local print = require("BarteringPathTrace").log

Bartering.ValueSide = {
    Player = "player",
    Barterer = "barterer",
}

Bartering.Values.BartererSaleDiscountMultiplier = 0.85
Bartering.Values.BartererSaleItemFraction = 0.8

Bartering.Values.CategoryValues = {
    default = 1,
}

Bartering.Values.CategoryValueGroups = {
    [16] = {
        "Weapon",
        "WeaponCrafted",
        "Explosives",
    },
    [14] = {
        "WeaponPart",
    },    
    [6] = {
        "Food",
        "Bandage",
        "FirstAid",
        "ToolWeapon",
        "Fishing",
    },
    [5] = {
        "Communications",
    },
    [4] = {
        "Water",
        "WaterContainer",
    },
    [3] = {
        "Camping",
        "Clothing",
        "ProtectiveGear",
        "Gardening",
        "Instrument",
        "LightSource",
        "Tool",
        "Trapping",
    },
    [2] = {
        "Bag",
        "Container",
    },
    [1] = {
        "Accessory",
        "Appearance",
        "Ammo",
        "Badger",
        "Beaver",
        "Bunny",
        "Entertainment",
        "Electronics",
        "Literature",
        "Fox",
        "Hedgehog",
        "Hidden",
        "Household",
        "Junk",
        "Material",
        "Mole",
        "Raccoon",
        "Security",
        "Squirrel",
        "SkillBook",
    },
    [0] = {
        "Corpse",
        "Cooking",
        "Furniture",
        "Paint",
        "Sports",
        "Cartography",
        "VehicleMaintenance",
    },
}

for value, categories in pairs(Bartering.Values.CategoryValueGroups) do
    for _, category in ipairs(categories) do
        Bartering.Values.CategoryValues[category] = value
    end
end

Bartering.Values.SideCategoryValues = {
    player = {
        Cartography = 0,
        Junk = 0,
    },
    barterer = {
        Cartography = 1,
        Junk = 1,
    },
}

Bartering.Values.ItemValues = {
    ["Base.MayonnaiseEmpty"] = 0,
    ["Base.Cork"] = 0,
    ["Base.SugarPacket"] = 1,
    ["Base.RemouladeEmpty"] = 0,
    ["Base.BeerEmpty"] = 0,
    ["Base.Newspaper_Dispatch_New"] = 0,
    ["Base.DryerLint"] = 0,
    ["Base.TongueDepressor"] = 0,
    ["Base.TongueDepressorBox"] = 0,
    ["Base.HolePuncher"] = 0,
    ["Base.HotDrinkCopper"] = 0,
    ["Base.Dung_Chicken"] = 0,
    ["Base.Dung_Cow"] = 0,
    ["Base.Dung_Deer"] = 0,
    ["Base.Dung_Mouse"] = 0,
    ["Base.Dung_Pig"] = 0,
    ["Base.Dung_Rabbit"] = 0,
    ["Base.Dung_Raccoon"] = 0,
    ["Base.Dung_Sheep"] = 0,
    ["Base.Dung_Turkey"] = 0,
    ["Base.FurTuft_Black"] = 0,
    ["Base.FurTuft_Browndark"] = 0,
    ["Base.FurTuft_Brownlight"] = 0,
    ["Base.FurTuft_Grey"] = 0,
    ["Base.FurTuft_White"] = 0,
    ["Base.Doodle"] = 0,
    ["Base.GroceryBag1"] = 0,
    ["Base.GroceryBag2"] = 0,
    ["Base.GroceryBag3"] = 0,
    ["Base.GroceryBag4"] = 0,
    ["Base.GroceryBag5"] = 0,
    ["Base.TinCanEmpty"] = 0,
    ["Base.BrokenGlass"] = 0,
    ["Base.CarrotSeed"] = 1,
    ["Base.BroccoliSeed"] = 1,
    ["Base.RedRadishSeed"] = 1,
    ["Base.StrewberrieSeed"] = 1,
    ["Base.TomatoSeed"] = 1,
    ["Base.PotatoSeed"] = 1,
    ["Base.CabbageSeed"] = 1,
    ["Base.LogStacks2"] = 2,
    ["Base.LogStacks3"] = 3,
    ["Base.LogStacks4"] = 4,
    ["Base.Hairspray2"] = 4,
    ["Base.CigaretteSingle"] = 10,
    ["Base.HottieZ"] = 10,
    ["Base.Soap2"] = 2,
    ["Base.ToiletPaper"] = 3,
    ["Base.Toothbrush"] = 2,
    ["Base.Razor"] = 2,
    ["Base.Tissue"] = 0.1,
    ["Base.Toothpaste"] = 2,
    ["Base.Trousers_Fireman"] = 150,
    ["Base.Jacket_Fireman"] = 150,
    ["Base.Scarf_White"] = 150,
    ["Base.Vest_BulletPolice"] = 150,
    ["Base.Bag_FannyPackFront"] = 150,
    ["Base.Bag_FannyPackBack"] = 150,
    ["Base.Shoes_ArmyBoots"] = 75,
    ["Base.Sledgehammer"] = 250,
    ["Base.Katana"] = 400,
    ["Base.Shotgun"] = 125,
    ["Base.DoubleBarrelShotgun"] = 125,
    ["Base.DoubleBarrelShotgunSawnoff"] = 125,
    ["Base.ShotgunSawnoff"] = 125,
}

Bartering.Values.NonBarterableItems = {
    ["Base.RippedSheetsDirty"] = true,
    ["Base.RippedSheets"] = true,
    ["Base.AlcoholRippedSheets"] = true,
    ["Base.CordlessPhone"] = true,
    ["Base.DogChew"] = true,
    ["Base.DeadRat"] = true,
    ["Base.DeadRatSkinned"] = true,
    ["Base.DeadRatBaby"] = true,
    ["Base.DeadRatBabySkinned"] = true,
    ["Base.RatKing"] = true,
    ["Base.Bag_DeadRats"] = true,
    ["Base.Dung_Rat"] = true,
    ["Base.BusinessCard"] = true,
    ["Base.BusinessCard_Nolans"] = true,
    ["Base.BusinessCard_Personal"] = true,
    ["Base.SpeedingTicket"] = true,
    ["keyring"] = true,
    ["broken"] = true,
    ["Base.Hinge"] = true,
    ["Base.KatePic"] = true,
    ["Base.MariannePic"] = true,
    ["Base.JamesPic"] = true,
    ["Base.HankPic"] = true,
    ["Base.ChrisPic"] = true,
    ["Base.BobPic"] = true,
    ["Base.CaseyPic"] = true,
    ["Base.CortmanPic"] = true,
    ["Base.MayonnaiseEmpty"] = true,
    ["Base.RemouladeEmpty"] = true,
    ["Base.BeerEmpty"] = true,
    ["Base.Doodle"] = true,
    ["Base.GroceryBag1"] = true,
    ["Base.GroceryBag2"] = true,
    ["Base.GroceryBag3"] = true,
    ["Base.GroceryBag4"] = true,
    ["Base.GroceryBag5"] = true,
    ["Base.TinCanEmpty"] = true,
    ["Base.BrokenGlass"] = true,
}

Bartering.Values.NonStockedItems = {
    ["Bartering.Coupon"] = true,
    ["Base.Garbagebag"] = true,
    ["Base.Newspaper_Dispatch_New"] = true,
    ["Base.DryerLint"] = true,
    ["Base.TongueDepressor"] = true,
    ["Base.TongueDepressorBox"] = true,
    ["Base.HolePuncher"] = true,
    ["Base.HotDrinkCopper"] = true,
    ["Base.Dung_Chicken"] = true,
    ["Base.Dung_Cow"] = true,
    ["Base.Dung_Deer"] = true,
    ["Base.Dung_Mouse"] = true,
    ["Base.Dung_Pig"] = true,
    ["Base.Dung_Rabbit"] = true,
    ["Base.Dung_Raccoon"] = true,
    ["Base.Dung_Sheep"] = true,
    ["Base.Dung_Turkey"] = true,
    ["Base.FurTuft_Black"] = true,
    ["Base.FurTuft_Browndark"] = true,
    ["Base.FurTuft_Brownlight"] = true,
    ["Base.FurTuft_Grey"] = true,
    ["Base.FurTuft_White"] = true,
    ["Base.Bullets9mm"] = true,
    ["Base.Bullets45"] = true,
    ["Base.Bullets44"] = true,
    ["Base.Bullets38"] = true,
    ["Base.ShotgunShells"] = true,
    ["Base.308Bullets"] = true,
    ["Base.556Bullets"] = true,
    ["Base.Bullets357"] = true,
    ["Base.3030Bullets"] = true,
    ["Base.Bullets9mmCarton"] = true,
    ["Base.Bullets45Carton"] = true,
    ["Base.Bullets44Carton"] = true,
    ["Base.Bullets38Carton"] = true,
    ["Base.Bullets357Carton"] = true,
    ["Base.ShotgunShellsCarton"] = true,
    ["Base.308Carton"] = true,
    ["Base.556Carton"] = true,
    ["Base.3030Carton"] = true,
}

Bartering.Values.SkillBookValuePerLevel = 5
Bartering.Values.MagazineValue = 8
Bartering.Values.ClothingConditionWeight = 0.6
Bartering.Values.ClothingHolePenalty = 0.5
Bartering.Values.ClothingDefenseDeltaScale = 0.2
Bartering.Values.StaleFoodPenalty = -2
Bartering.Values.FreshFoodBonus = 1
Bartering.Values.FreshCookedFoodBonus = 2
Bartering.Values.WaterUnitValue = 1
Bartering.Values.WaterUnitLitres = 0.1
Bartering.Values.FuelUnitValue = 1
Bartering.Values.FuelUnitLitres = 1
Bartering.Values.BatteryChargeValue = 1
Bartering.Values.RareClothingChance = 2
Bartering.Values.RareClothingItems = {
    "Base.Trousers_Fireman",
    "Base.Jacket_Fireman",
    "Base.Scarf_White",
    "Base.Vest_BulletPolice",
    "Base.Bag_FannyPackFront",
    "Base.Bag_FannyPackBack",
}
Bartering.Values.PlayerTradeValueMultiplierBase = 0.75
Bartering.Values.PlayerTradeValueMultiplierPerLevel = 0.02
Bartering.Values.PlayerTradeValueMultiplierMax = 0.90

Bartering.Values.BoxedAmmo = {
    ["Base.Bullets9mmBox"] = { item = "Base.Bullets9mm", count = 50 },
    ["Base.Bullets45Box"] = { item = "Base.Bullets45", count = 50 },
    ["Base.Bullets38Box"] = { item = "Base.Bullets38", count = 50 },
    ["Base.Bullets357Box"] = { item = "Base.Bullets357", count = 50 },
    ["Base.Bullets44Box"] = { item = "Base.Bullets44", count = 20 },
    ["Base.308Box"] = { item = "Base.308Bullets", count = 20 },
    ["Base.556Box"] = { item = "Base.556Bullets", count = 20 },
    ["Base.3030Box"] = { item = "Base.3030Bullets", count = 20 },
    ["Base.ShotgunShellsBox"] = { item = "Base.ShotgunShells", count = 25 },
}

Bartering.Values.AmmoCartons = {
    ["Base.Bullets9mmCarton"] = { item = "Base.Bullets9mmBox", count = 12 },
    ["Base.Bullets45Carton"] = { item = "Base.Bullets45Box", count = 12 },
    ["Base.Bullets38Carton"] = { item = "Base.Bullets38Box", count = 12 },
    ["Base.Bullets357Carton"] = { item = "Base.Bullets357Box", count = 12 },
    ["Base.Bullets44Carton"] = { item = "Base.Bullets44Box", count = 12 },
    ["Base.308Carton"] = { item = "Base.308Box", count = 12 },
    ["Base.556Carton"] = { item = "Base.556Box", count = 12 },
    ["Base.3030Carton"] = { item = "Base.3030Box", count = 12 },
    ["Base.ShotgunShellsCarton"] = { item = "Base.ShotgunShellsBox", count = 12 },
}

Bartering.Values.MedicalBoxes = {
    ["Base.AntibioticsBox"] = { item = "Base.Antibiotics", count = 12 },
    ["Base.BandageBox"] = { item = "Base.Bandage", count = 12 },
    ["Base.CottonBallsBox"] = { item = "Base.CottonBalls", count = 12 },
    ["Base.SutureNeedleBox"] = { item = "Base.SutureNeedle", count = 12 },
    ["Base.AdhesiveBandageBox"] = { item = "Base.Bandaid", count = 24 },
    ["Base.ColdpackBox"] = { item = "Base.Coldpack", count = 6 },
}

Bartering.Values.SkillBookSetVolumePrefixes = {
    ["Base.BookMechanicsSet"] = "Base.BookMechanic",
}
Bartering.Values.SkillBookSetVolumeCount = 5

Bartering.Values.SeedPackets = {
    ["Base.CarrotBagSeed2"] = { item = "Base.CarrotSeed", count = 50 },
    ["Base.BroccoliBagSeed2"] = { item = "Base.BroccoliSeed", count = 50 },
    ["Base.RedRadishBagSeed2"] = { item = "Base.RedRadishSeed", count = 50 },
    ["Base.StrewberrieBagSeed2"] = { item = "Base.StrewberrieSeed", count = 50 },
    ["Base.TomatoBagSeed2"] = { item = "Base.TomatoSeed", count = 50 },
    ["Base.PotatoBagSeed2"] = { item = "Base.PotatoSeed", count = 50 },
    ["Base.CabbageBagSeed2"] = { item = "Base.CabbageSeed", count = 50 },
}

Bartering.Values.CaliberBonuses = {
    { token = "9mm", value = 1 },
    { token = "45", value = 2 },
    { token = "22", value = 1 },
    { token = "shotgun", value = 2 },
    { token = "rifle", value = 3 },
    { token = "357", value = 2 },
    { token = "38", value = 1 },
    { token = "308", value = 3 },
}

function Bartering.getItemName(input)
    if type(input) == "string" then
        return input
    end
    return input:getFullType()
end

function Bartering.roundTradeValue(value)
    if value >= 0 then
        return math.floor(value * 100 + 0.5) / 100
    end
    return math.ceil(value * 100 - 0.5) / 100
end

function Bartering.formatTradeValue(value)
    return string.format("%.2f", Bartering.roundTradeValue(value))
end

function Bartering.getPlayerTradeValueMultiplier(player, bartererId)
    local level = Bartering.getBarterSkillLevel(player)
    local multiplier = math.min(
        Bartering.Values.PlayerTradeValueMultiplierMax,
        Bartering.Values.PlayerTradeValueMultiplierBase + (math.max(0, level) * Bartering.Values.PlayerTradeValueMultiplierPerLevel)
    )
    if bartererId and Bartering.getSandboxBoolean("EnableRelationships", true) then
        multiplier = multiplier + Bartering.Relations.getBonus(player, bartererId)
    end
    return math.min(1, multiplier)
end

function Bartering.applySideTradeModifier(value, side, player, bartererId)
    if side ~= Bartering.ValueSide.Player then
        return value
    end
    return value * Bartering.getPlayerTradeValueMultiplier(player, bartererId)
end

function Bartering.matchesItemRule(input, rules)
    local itemName = Bartering.getItemName(input)
    local lowerName = itemName:lower()
    for key, _ in pairs(rules) do
        if key:find(".", 1, true) then
            if key == itemName then
                return true
            end
        else
            if lowerName:find(key, 1, true) then
                return true
            end
        end
    end
    return false
end

function Bartering.isBarterableItem(input)
    if type(input) ~= "string" and Bartering.Quests.isQuestItem(input) then
        return false
    end

    if type(input) ~= "string" and input:getFluidContainer() and input:getFluidContainer():isEmpty() then
        return false
    end

    return not Bartering.matchesItemRule(input, Bartering.Values.NonBarterableItems)
end

function Bartering.isNonStockedItem(input)
    return Bartering.matchesItemRule(input, Bartering.Values.NonStockedItems)
end

function Bartering.getCategoryName(input)
    if type(input) == "string" then
        return getScriptManager():FindItem(input):getDisplayCategory()
    end
    return input:getDisplayCategory()
end

function Bartering.getScriptItem(input)
    if type(input) == "string" then
        return getScriptManager():FindItem(input)
    end
    return input:getScriptItem()
end

function Bartering.getDisplayName(input)
    if type(input) == "string" then
        return Bartering.getScriptItem(input):getDisplayName()
    end
    return input:getDisplayName()
end

function Bartering.getUnitItem(input)
    if type(input) ~= "string" then
        return input
    end
    return instanceItem(input)
end

function Bartering.getCategoryValue(itemName, side)
    local category = Bartering.getCategoryName(itemName)
    local sideValues = Bartering.Values.SideCategoryValues[side] or Bartering.Values.SideCategoryValues[Bartering.ValueSide.Player]
    if sideValues and sideValues[category] ~= nil then
        return sideValues[category]
    end
    return Bartering.Values.CategoryValues[category] or Bartering.Values.CategoryValues.default
end

function Bartering.getCaliberBonus(itemName)
    local category = Bartering.getCategoryName(itemName)
    if category ~= "Weapon" and category ~= "Ammo" and category ~= "WeaponPart" then
        return 0
    end
    local lowered = itemName:lower()
    for _, bonus in ipairs(Bartering.Values.CaliberBonuses) do
        if lowered:find(bonus.token) then
            return bonus.value
        end
    end
    return 0
end

function Bartering.getSkillBookValue(input)
    if Bartering.getCategoryName(input) ~= "SkillBook" then
        return nil
    end

    local item = Bartering.getUnitItem(input)
    if not instanceof(item, "Literature") then
        local itemName = Bartering.getItemName(input)
        local prefix = Bartering.Values.SkillBookSetVolumePrefixes[itemName] or itemName:gsub("Set$", "")
        local value = 0
        for volume = 1, Bartering.Values.SkillBookSetVolumeCount do
            value = value + Bartering.getSkillBookValue(prefix .. volume)
        end
        return value
    end

    local skillLevel = item:getLvlSkillTrained()
    if skillLevel < 1 then
        return Bartering.Values.MagazineValue
    end

    return skillLevel * Bartering.Values.SkillBookValuePerLevel
end

function Bartering.getFoodConditionModifier(input)
    if Bartering.getCategoryName(input) ~= "Food" then
        return 0
    end

    local lowered = Bartering.getDisplayName(input):lower()
    local modifier = 0
    if lowered:find("%(fresh cooked%)") then
        modifier = Bartering.Values.FreshCookedFoodBonus
    elseif lowered:find("fresh") then
        modifier = Bartering.Values.FreshFoodBonus
    end
    if lowered:find("stale") then
        modifier = modifier + Bartering.Values.StaleFoodPenalty
    end
    return modifier
end

function Bartering.getBatteryChargeValue(input)
    local item = Bartering.getUnitItem(input)
    if not instanceof(item, "DrainableComboItem") or not Bartering.getItemName(input):lower():find("battery") then
        return nil
    end

    return item:getCurrentUsesFloat() * Bartering.Values.BatteryChargeValue
end

function Bartering.getMedicineDoseValue(input, side)
    if Bartering.getCategoryName(input) ~= "FirstAid" then
        return nil
    end
    local item = Bartering.getUnitItem(input)
    if not instanceof(item, "DrainableComboItem") then
        return nil
    end
    return Bartering.getCategoryValue(Bartering.getItemName(input), side) * item:getCurrentUsesFloat()
end

function Bartering.getConditionRatio(input)
    if type(input) == "string" or input:getConditionMax() <= 0 then
        return nil
    end
    return math.max(0, math.min(1, input:getCondition() / input:getConditionMax()))
end

function Bartering.applyConditionRatio(input, value)
    local conditionRatio = Bartering.getConditionRatio(input)
    if conditionRatio == nil then
        return value
    end
    return value * conditionRatio
end

function Bartering.getContainedTradeValue(input, side, player, bartererId)
    if type(input) == "string" or not instanceof(input, "InventoryContainer") then
        return 0
    end

    local contents = input:getInventory():getItems()
    local value = 0
    for i = 0, contents:size() - 1 do
        value = value + Bartering.getTradeValue(contents:get(i), side, player, bartererId)
    end
    return value
end

function Bartering.getDrainableUnitValue(input)
    local item = Bartering.getUnitItem(input)
    local fluidContainer = item:getFluidContainer()
    if not fluidContainer or fluidContainer:isEmpty() then
        return nil
    end

    local fluidType = fluidContainer:getPrimaryFluid():getFluidTypeString()
    local unitValue, unitLitres
    if fluidType == "Water" or fluidType == "TaintedWater" then
        if not Bartering.isWaterShutOff() then
            return 0
        end
        unitValue = Bartering.Values.WaterUnitValue
        unitLitres = Bartering.Values.WaterUnitLitres
    elseif fluidType == "Petrol" then
        unitValue = Bartering.Values.FuelUnitValue
        unitLitres = Bartering.Values.FuelUnitLitres
    else
        return nil
    end

    local unitCount = math.floor(fluidContainer:getAmount() / unitLitres + 0.5)
    if fluidType == "Petrol" then
        print("[Bartering][Values] fuel " .. item:getFullType() .. " litres=" .. tostring(fluidContainer:getAmount())
            .. " units=" .. tostring(unitCount) .. " value=" .. tostring(unitCount * unitValue))
    end
    return unitCount * unitValue
end

function Bartering.getDrainableUnitCount(input)
    if type(input) == "string" then
        return nil
    end
    local fluidContainer = input:getFluidContainer()
    if fluidContainer then
        return math.floor(fluidContainer:getAmount() * 1000 + 0.5)
    end
    if not instanceof(input, "DrainableComboItem") then
        return nil
    end
    return input:getCurrentUses()
end

function Bartering.getClothingValue(input, side)
    local category = Bartering.getCategoryName(input)
    if category ~= "Clothing" and category ~= "ProtectiveGear" and category ~= "Accessory" and category ~= "Appearance" then
        return nil
    end

    local itemName = Bartering.getItemName(input)
    local item = Bartering.getUnitItem(input)
    if not instanceof(item, "Clothing") then
        return Bartering.getCategoryValue(itemName, side)
    end

    if item:getScratchDefense() <= 0 and item:getBiteDefense() <= 0 then
        return 0
    end

    local baseValue = Bartering.getCategoryValue(itemName, side)
    local conditionValue = Bartering.applyConditionRatio(item, baseValue)
    local holePenalty = item:getHolesNumber() * Bartering.Values.ClothingHolePenalty

    local scriptDefaults = instanceItem(itemName)
    local baseDefense = scriptDefaults:getScratchDefense() + scriptDefaults:getBiteDefense() + scriptDefaults:getBulletDefense()
    local currentDefense = item:getScratchDefense() + item:getBiteDefense() + item:getBulletDefense()
    local defenseDelta = (currentDefense - baseDefense) * Bartering.Values.ClothingDefenseDeltaScale

    return math.max(0, conditionValue - holePenalty + defenseDelta)
end

function Bartering.getTradeValue(input, side, player, bartererId)
    local itemName = nil
    local function finalizeValue(value)
        local result = Bartering.applySideTradeModifier(value, side, player, bartererId)
        if itemName and player and bartererId and Bartering.isBartererItemOnSale(bartererId, itemName, player) then
            result = result * Bartering.Values.BartererSaleDiscountMultiplier
        end
        return Bartering.roundTradeValue(result)
    end

    if type(input) == "number" then
        return finalizeValue(input)
    end

    side = side or Bartering.ValueSide.Player

    itemName = Bartering.getItemName(input)
    if Bartering.Quests.isCouponType(itemName) then
        return Bartering.roundTradeValue(Bartering.Quests.COUPON_VALUE)
    end

    local overrideValue = Bartering.Values.ItemValues[itemName]
    if overrideValue ~= nil then
        return finalizeValue(overrideValue)
    end

    local skillBookValue = Bartering.getSkillBookValue(input)
    if skillBookValue ~= nil then
        return finalizeValue(skillBookValue)
    end

    local clothingValue = Bartering.getClothingValue(input, side)
    if clothingValue ~= nil then
        return finalizeValue(clothingValue)
    end

    local batteryChargeValue = Bartering.getBatteryChargeValue(input)
    if batteryChargeValue ~= nil then
        return finalizeValue(Bartering.applyConditionRatio(input, Bartering.getCategoryValue(itemName, side) + batteryChargeValue))
    end

    local medicineDoseValue = Bartering.getMedicineDoseValue(input, side)
    if medicineDoseValue ~= nil then
        return finalizeValue(medicineDoseValue)
    end

    local drainableUnitValue = Bartering.getDrainableUnitValue(input)
    if drainableUnitValue ~= nil then
        return finalizeValue(drainableUnitValue)
    end

    local boxedAmmo = Bartering.Values.BoxedAmmo[itemName]
    if boxedAmmo then
        return finalizeValue(Bartering.getTradeValue(boxedAmmo.item, side, player, bartererId) * boxedAmmo.count)
    end

    local ammoCarton = Bartering.Values.AmmoCartons[itemName]
    if ammoCarton then
        return finalizeValue(Bartering.getTradeValue(ammoCarton.item, side, player, bartererId) * ammoCarton.count)
    end

    local medicalBox = Bartering.Values.MedicalBoxes[itemName]
    if medicalBox then
        return finalizeValue(Bartering.getTradeValue(medicalBox.item, side, player, bartererId) * medicalBox.count)
    end

    local seedPacket = Bartering.Values.SeedPackets[itemName]
    if seedPacket then
        return finalizeValue(Bartering.getTradeValue(seedPacket.item, side, player, bartererId) * seedPacket.count)
    end

    return finalizeValue(Bartering.applyConditionRatio(input, Bartering.getCategoryValue(itemName, side)
        + Bartering.getCaliberBonus(itemName)
        + Bartering.getFoodConditionModifier(input))
        + Bartering.getContainedTradeValue(input, side, player, bartererId))
end
