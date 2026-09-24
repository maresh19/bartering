Bartering = Bartering or {}
local print = require("BarteringPathTrace").log

local sendAddItemToContainer = _G["sendAddItemToContainer"]

local function fillContainer(container, stock)
    local containerInventory = container:getInventory()
    local existing = containerInventory:getItems()
    for i = existing:size() - 1, 0, -1 do
        containerInventory:Remove(existing:get(i))
    end
    for _, itemName in ipairs(stock) do
        containerInventory:AddItem(itemName)
    end
    return containerInventory
end

local function describeContents(containerInventory)
    local names = ""
    local placed = containerInventory:getItems()
    for i = 0, placed:size() - 1 do
        names = names .. placed:get(i):getFullType() .. ","
    end
    return placed:size(), names
end

function Bartering.syncBartererStockToContainer(container, bartererId)
    local stock = Bartering.getBartererStock(bartererId)
    local placed, names = describeContents(fillContainer(container, stock))
    print("[Bartering][Stock] sync " .. tostring(bartererId)
        .. " stock=" .. tostring(#stock)
        .. " bag=" .. tostring(container)
        .. " bagItems=" .. tostring(placed)
        .. " [" .. names .. "]")
end

function Bartering.takeBartererDeathStock(bartererId)
    local stock = Bartering.getBartererStock(bartererId)
    Bartering.clearBartererStock(bartererId)
    return stock
end

function Bartering.restoreBartererDeathLook(zombie, bartererId)
    local identity = Bartering.ensureBartererIdentity(bartererId)
    if Bartering.bartererVisualsMatch(zombie, identity.clothing) then
        return
    end
    Bartering.applyBartererIdentityToZombie(zombie, bartererId)
    Bartering.dressBartererZombie(zombie, identity)
    print("[Bartering][Deathbag] redressed corpse " .. tostring(bartererId)
        .. " worn=[" .. Bartering.describeItemVisuals(zombie)
        .. "] identity=[" .. table.concat(identity.clothing, ";") .. "]")
end

function Bartering.stockBartererDeathbag(zombie, stock)
    local bag = Bartering.getBartererBag(zombie)
    local placed, names = describeContents(fillContainer(bag, stock))
    print("[Bartering][Deathbag] " .. tostring(zombie:getVariableString("BartererId"))
        .. " stock=" .. tostring(#stock)
        .. " bag=" .. tostring(bag)
        .. " bagItems=" .. tostring(placed)
        .. " [" .. names .. "]")
end

function Bartering.stockBartererCorpse(body, stock)
    local container = body:getContainer()
    for _, itemName in ipairs(stock) do
        sendAddItemToContainer(container, container:AddItem(itemName))
    end
    print("[Bartering][Deathbag] corpse fallback stocked " .. tostring(#stock) .. " items into " .. tostring(container))
end

function Bartering.dropBartererEquipment(bartererId, square, gun, knife, ammoCount, ammoContainer, syncAmmo, knifeInHand)
    local ammoItem = Bartering.getBartererWeapon(bartererId).ammoItem

    local function addAmmo(item)
        ammoContainer:AddItem(item)
        if syncAmmo then
            sendAddItemToContainer(ammoContainer, item)
        end
    end
    local held, stowed = gun, knife
    if knifeInHand then
        held, stowed = knife, gun
    end
    square:AddWorldInventoryItem(held, 0.5, 0.5, 0)
    addAmmo(stowed)
    local magazineType = gun:getMagazineType()
    if magazineType then
        local remaining = ammoCount
        while remaining > 0 do
            local magazine = instanceItem(magazineType)
            local rounds = math.min(gun:getMaxAmmo(), remaining)
            magazine:setCurrentAmmoCount(rounds)
            addAmmo(magazine)
            remaining = remaining - rounds
        end
        ammoItem = magazineType
    else
        for _ = 1, ammoCount do
            addAmmo(instanceItem(ammoItem))
        end
    end

    print("[Bartering][Deathbag] dropped " .. tostring(bartererId)
        .. " held=" .. tostring(held:getFullType())
        .. " stowed=" .. tostring(stowed:getFullType())
        .. " ammo=" .. tostring(ammoCount) .. " " .. tostring(ammoItem)
        .. string.format(" at %d,%d,%d", square:getX(), square:getY(), square:getZ()))
end
