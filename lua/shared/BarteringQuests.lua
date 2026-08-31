Bartering = Bartering or {}
Bartering.Quests = Bartering.Quests or {}

local BarteringTiming = require "BarteringTiming"
local InventoryItemFactory = _G["InventoryItemFactory"]
local getGameTime = _G["getGameTime"]
local ArrayList = _G["ArrayList"]

local NamedPlaces = require "BarteringNamedPlaces"

local Quests = Bartering.Quests

Quests.REWARD = 75
Quests.DEFAULT_COOLDOWN_DAYS = 7
Quests.MIN_ROOM_AREA = 9
Quests.BUILDING_SAMPLES = 600
Quests.THEMED_BUILDING_SAMPLES = 1000
Quests.COUPON_ITEM = "Bartering.Coupon"
Quests.COUPON_VALUE = 10

Quests.Towns = {
    { id = "Louisville", name = "Louisville", x1 = 11700, y1 = 900, x2 = 13799, y2 = 3599 },
    { id = "Riverside", name = "Riverside", x1 = 5700, y1 = 5100, x2 = 7199, y2 = 5999 },
    { id = "WestPoint", name = "West Point", x1 = 10800, y1 = 6600, x2 = 12299, y2 = 7199 },
    { id = "Dixie", name = "Dixie", x1 = 11100, y1 = 8400, x2 = 11999, y2 = 9299 },
    { id = "Muldraugh", name = "Muldraugh", x1 = 10200, y1 = 9000, x2 = 11099, y2 = 10799 },
    { id = "Rosewood", name = "Rosewood", x1 = 7500, y1 = 11100, x2 = 8699, y2 = 12599 },
    { id = "MarchRidge", name = "March Ridge", x1 = 9600, y1 = 12600, x2 = 10799, y2 = 13199 },
}

Quests.ExcludedRooms = {
    empty = true,
    emptyoutside = true,
    nogo = true,
    construction = true,
    candystore = true,
    elevator = true,
    stairwell = true,
    roofstairs = true,
    catwalk = true,
    daycare = true,
    druglab = true,
    balcony = true,
    hall = true,
    hallway = true,
    janitor = true,
    closet = true,
    picnic = true,
    aesthetic = true,
    traincar = true,
    loggingtruck = true,
    sodatruck = true,
    horsebox = true,
    newsroom = true,
}

Quests.PersonalRooms = {
    bedroom = true,
    livingroom = true,
    kitchen = true,
    bathroom = true,
    diningroom = true,
    dining = true,
    garage = true,
    garagestorage = true,
    meetingroom = true,
    laundry = true,
    attic = true,
    sewingroom = true,
    bandlivingroom = true,
    bandkitchen = true,
    bowlingalley = true,
    motelroom = true,
    motelroomoccupied = true,
}

Quests.RoomLabels = {
    livingroom = "living room",
    diningroom = "dining room",
    garagestorage = "garage",
    bandlivingroom = "living room",
    bandkitchen = "kitchen",
    motelroom = "motel room",
    motelroomoccupied = "motel room",
    storageunit = "storage unit",
    lockerroom = "locker room",
    breakroom = "break room",
    changeroom = "changing room",
    changerooms = "changing rooms",
    dressingrooms = "dressing rooms",
    prisoncells = "prison block",
    hospitalroom = "hospital ward",
    medclinic = "medical clinic",
    restaurantkitchen = "restaurant kitchen",
    cafekitchen = "cafe kitchen",
    bakerykitchen = "bakery kitchen",
    burgerkitchen = "burger joint kitchen",
    pizzakitchen = "pizzeria kitchen",
    chinesekitchen = "chinese takeaway kitchen",
    italiankitchen = "italian kitchen",
    dinerkitchen = "diner kitchen",
    barkitchen = "bar kitchen",
    theatrekitchen = "theatre kitchen",
    cafeteriakitchen = "cafeteria kitchen",
    icecreamkitchen = "ice cream parlour kitchen",
    spiffoskitchen = "Spiffo's kitchen",
    gigamartkitchen = "Gigamart kitchen",
    fishchipskitchen = "fish and chip shop kitchen",
    clothesstore = "clothes store",
    clothingstore = "clothes store",
    shoestore = "shoe store",
    toolstore = "hardware store",
    gunstore = "gun store",
    bookstore = "book store",
    toystore = "toy store",
    giftstore = "gift shop",
    artstore = "art supply store",
    musicstore = "music store",
    sportstore = "sporting goods store",
    camerastore = "camera store",
    cornerstore = "corner store",
    generalstore = "general store",
    conveniencestore = "convenience store",
    departmentstore = "department store",
    electronicsstore = "electronics store",
    furniturestore = "furniture store",
    jewelrystore = "jewelry store",
    liquorstore = "liquor store",
    gardenstore = "garden centre",
    sewingstore = "fabric store",
    housewarestore = "houseware store",
    barbequestore = "barbecue store",
    walletshop = "leather goods shop",
    carsupply = "auto parts store",
    armysurplus = "army surplus store",
    pawnshop = "pawn shop",
    movierental = "video rental",
    postoffice = "post office",
    post = "post office",
    gasstore = "gas station",
    knoxbutcher = "butcher shop",
    pizzawhirled = "Pizza Whirled",
    zippeestore = "Zippee store",
    gigamart = "Gigamart",
    icecream = "ice cream shop",
    mexicanrestaurant = "mexican restaurant",
    chineserestaurant = "chinese restaurant",
    boathouse = "boat house",
    serverroom = "server room",
    editingroom = "editing room",
    photoroom = "dark room",
    horsewashingstation = "horse washing station",
    railroadrepair = "railroad repair shed",
    whiskeybottling = "bottling floor",
    wirefactory = "wire factory",
    farmstorage = "farm store room",
    officestorage = "office store room",
    grocerystorage = "grocery store room",
    pharmacystorage = "pharmacy store room",
    theatrestorage = "theatre store room",
    medicalstorage = "medical storage",
    hospitalstorage = "hospital store room",
    schoolstorage = "school store room",
    policestorage = "police store room",
    firestorage = "fire station store room",
    armystorage = "army store room",
    bankstorage = "bank vault room",
    gunstorestorage = "back room of a gun store",
    clothesstorage = "back room of a clothes store",
    clothesstorestorage = "back room of a clothes store",
    generalstorestorage = "back room of a general store",
    cornerstorestorage = "back room of a corner store",
    departmentstorage = "back room of a department store",
    dinerbackroom = "the backroom of a restaurant",
    electronicsstorage = "back room of an electronics store",
    furniturestorage = "furniture store back room",
    jewelrystorage = "jewelry store back room",
    giftstorage = "gift shop back room",
    toystorage = "toy store back room",
    toolstorage = "hardware store back room",
    bookstorage = "book store back room",
    shoestorage = "shoe store back room",
    sewingstorage = "fabric store back room",
    sportstorage = "sporting goods back room",
    gymstorage = "gym store room",
    motelstorage = "motel store room",
    spiffosstorage = "Spiffo's store room",
    zippeestorage = "Zippee store room",
    burgerstorage = "burger joint store room",
    barstorage = "bar cellar",
    gasstorage = "gas station store room",
    factorystorage = "factory store room",
    fishingstorage = "bait shop store room",
    dentiststorage = "dentist store room",
    poststorage = "post office store room",
    producestorage = "produce store room",
    potatostorage = "potato store",
    railroadstorage = "railroad store room",
    miscstorage = "store room",
    storagehall = "store room",
    sttorage = "store room",
    storage = "store room",
    recreation = "recreation room",
    recreational = "recreation room",
    laboratory = "laboratory",
    locker = "locker room",
}

Quests.ToolSentimentLine = "There's none other like it."

Quests.SentimentLines = {
    "It means a lot to me.",
    "Had that thing since before any of this started.",
    "Never got the chance to go back for it.",
    "It's about the last thing I've got left from that life.",
    "Lost enough already without losing that too.",
    "I've replaced everything else twice over. Not that.",
    "You could say I'm attached to it.",
}

Quests.VideoTitles = {
    "Breaking Points: Directors Cut",
    "Man on the Run: Directors Cut",
    "Pleistocene Land: Directors Cut",
    "Eagle Down: Directors Cut",
    "Home Invaders 2: Directors Cut",
    "Blood in the Hood: Directors Cut",
    "Train Bomb: Directors Cut",
    "All Over Again: Directors Cut",
    "Dark Agent: Directors Cut",
    "Timbergap Manor: Directors Cut",
    "Ace Pilot: Directors Cut",
    "Dead Wrong: Directors Cut",
    "Mother's Boy: Directors Cut",
    "Return of the Nightwatcher: Directors Cut",
    "Fred and Ali's Radical Journey: Directors Cut",
    "Slow Descent: Directors Cut",
    "Squad Down: Directors Cut",
    "Dying Strike: Directors Cut",
    "Marriage License: Directors Cut",
    "War Front: Directors Cut",
}

Quests.MusicTitles = {
    "Rock Gods: Special Edition",
    "Running on Fumes: Special Edition",
    "A Boy from Kentucky: Special Edition",
    "Loretta: Special Edition",
    "Got Me Thinkin: Special Edition",
    "Dying Strike Official Soundtrack: Special Edition",
    "Where is Everybody?: Special Edition",
    "Moon Madness: Special Edition",
    "Uncle Billy's Kentucky Moonshine: Special Edition",
    "A Truck Full of Love: Special Edition",
    "Hell Has Opened: Special Edition",
    "I Swear: Special Edition",
    "Over: Special Edition",
    "You're Gone: Special Edition",
    "Hidden: Special Edition",
    "The Depth of your Love: Special Edition",
    "Best of the Bojangles: Special Edition",
    "Heading for the Heat: Special Edition",
}

Quests.MedicineMeds = {
    { itemName = "Nocordin", complaint = "These headaches are getting worse by the day." },
    { itemName = "Migravane", complaint = "My migraines have been killing me." },
    { itemName = "Cephedrin", complaint = "I can barely think, my head hurts so much." },
    { itemName = "Nausol", complaint = "My stomach's been turning over on me." },
    { itemName = "Vertixil", complaint = "I've been dizzy and sick to my stomach." },
    { itemName = "Gastralin", complaint = "Nothing's staying down these days." },
    { itemName = "Anadrex", complaint = "Every joint in my body aches these days." },
    { itemName = "Comfeltin", complaint = "The pain never lets up anymore." },
    { itemName = "Panalex", complaint = "It's hard to get anything done when you're hurting." },
}

Quests.LiquorItemType = "Base.WhiskeyFull"
Quests.LiquorItemName = "Bottle of Rare Bourbon"

Quests.NecklaceItems = {
    { itemType = "Base.Necklace_Gold",   familyTie = "mother" },
    { itemType = "Base.Necklace_Silver", familyTie = "grandmother" },
    { itemType = "Base.Necklace_Pearl",  familyTie = "daughter" },
}

Quests.NecklaceTieLabels = {
    mother    = "Mom's Necklace",
    grandmother = "Grandma's Necklace",
    daughter  = "Daughter's Necklace",
}

Quests.PictureItems = {
    { itemType = "Base.BobPic",       familyTie = "son" },
    { itemType = "Base.JamesPic",     familyTie = "brother" },
    { itemType = "Base.MariannePic",  familyTie = "mother" },
    { itemType = "Base.KatePic",      familyTie = "sister" },
}

Quests.RoomThemes = {
    movierental = "video",
    musicstore = "music",
    liquorstore = "liquor",
    pharmacystorage = "medicine",
    medclinic = "medicine",
    medicalstorage = "medicine",
    hospitalstorage = "medicine",
    hospitalroom = "medicine",
}

Quests.NeverRequestedItems = {
    "Bartering.Coupon",
    "Base.EmptyNotebook",
}

Quests.NeverRequestedPatterns = {
    "Empty",
}

Quests.NeverRequested = {}
for _, itemType in ipairs(Quests.NeverRequestedItems) do
    Quests.NeverRequested[itemType] = true
end
for _, pattern in ipairs(Quests.NeverRequestedPatterns) do
    Quests.NeverRequested[pattern] = true
end
for itemName, value in pairs(Bartering.Values.ItemValues) do
    if value <= 0 then
        Quests.NeverRequested[itemName] = true
    end
end
for key in pairs(Bartering.Values.NonBarterableItems) do
    Quests.NeverRequested[key] = true
end

Quests.ItemPool = {
    "Base.Hammer",
    "Base.HuntingKnife",
    "Base.Screwdriver",
    "Base.Saw",
    "Base.Axe",
    "Base.BaseballBat",
    "Base.Journal",
    "Base.FishingRod",
}

function Quests.getTownAt(x, y)
    for _, town in ipairs(Quests.Towns) do
        if x >= town.x1 and x <= town.x2 and y >= town.y1 and y <= town.y2 then
            return town
        end
    end
    return nil
end

function Quests.getRoomLabel(roomName)
    return Quests.RoomLabels[roomName] or roomName
end

function Quests.getIndefiniteArticle(label)
    local firstChar = label:sub(1, 1):lower()
    if firstChar == "a" or firstChar == "e" or firstChar == "i" or firstChar == "o" or firstChar == "u" then
        return "an"
    end
    return "a"
end

function Quests.getRoomReference(roomName)
    local label = Quests.getRoomLabel(roomName)
    return Quests.getIndefiniteArticle(label) .. " " .. label
end

function Quests.getNamedLocation(quest)
    if quest.namedId then
        for _, location in ipairs(NamedPlaces.getLocations()) do
            if location.id == quest.namedId then
                return location
            end
        end
    end
    local closest = nil
    local closestDist = nil
    for _, location in ipairs(NamedPlaces.getLocations()) do
        if location.townId == quest.townId then
            local dx = math.abs(location.x - quest.x)
            local dy = math.abs(location.y - quest.y)
            if dx <= location.radius and dy <= location.radius then
                local dist = dx + dy
                if not closestDist or dist < closestDist then
                    closest = location
                    closestDist = dist
                end
            end
        end
    end
    return closest
end

function Quests.getPlaceReference(quest)
    local named = Quests.getNamedLocation(quest)
    if named then
        if quest.theme == "medicine" then
            local roomLabel = Quests.getRoomLabel(quest.roomName)
            if roomLabel then
                return string.format("%s's %s", named.name, roomLabel)
            end
        end
        if (quest.z or 0) > 0 and quest.namedFloor0Room and quest.namedFloor0Room ~= quest.roomName then
            local label = Quests.getRoomLabel(quest.roomName)
            if label == "office" then
                return string.format("the offices above %s", named.name)
            end
            return string.format("the %s above %s", label, named.name)
        end
        return named.name
    end
    return Quests.getRoomReference(quest.roomName)
end

function Quests.hasNecklaceUsed(player, bartererId)
    return Quests.getPlayerState(player).necklaceUsed
        and Quests.getPlayerState(player).necklaceUsed[bartererId] == true
end

function Quests.isPersonalRoom(roomName)
    return Quests.PersonalRooms[roomName] == true
end

function Quests.isUsableRoom(roomDef)
    if Quests.ExcludedRooms[roomDef:getName()] then
        return false
    end
    return roomDef:getArea() >= Quests.MIN_ROOM_AREA
end

function Quests.getThemeForRoom(roomName)
    return Quests.RoomThemes[roomName]
end

function Quests.isToolOrWeapon(itemType)
    local category = Bartering.getCategoryName(itemType)
    return category == "Weapon"
        or category == "WeaponCrafted"
        or category == "ToolWeapon"
        or category == "Tool"
        or category == "Explosives"
end

function Quests.hashQuestId(quest)
    local sum = 0
    for i = 1, #quest.id do
        sum = sum + string.byte(quest.id, i)
    end
    return sum
end

function Quests.pickQuestLine(quest, lines)
    return lines[(Quests.hashQuestId(quest) % #lines) + 1]
end

function Quests.isRequestableItem(itemName)
    if Bartering.matchesItemRule(itemName, Quests.NeverRequested) then
        return false
    end
    return Bartering.getTradeValue(itemName, Bartering.ValueSide.Barterer) > 0
end

function Quests.getRequestableItems(excludeTools)
    local items = {}
    for _, itemType in ipairs(Quests.ItemPool) do
        if Quests.isRequestableItem(itemType) then
            if not excludeTools or not Quests.isToolOrWeapon(itemType) then
                table.insert(items, itemType)
            end
        end
    end
    return items
end

function Quests.getSentimentLine(quest)
    if quest.itemType and Quests.isToolOrWeapon(quest.itemType) then
        return Quests.ToolSentimentLine
    end
    return Quests.pickQuestLine(quest, Quests.SentimentLines)
end

function Quests.getFlavorLine(quest)
    local place = Quests.getPlaceReference(quest)
    if quest.theme == "video" then
        return Quests.pickQuestLine(quest, {
            string.format("See if %s in %s still has a copy of '%s' on VHS. I never had a chance to watch it.", place, quest.townName, quest.title),
            string.format("Ask around %s in %s for a copy of '%s'. It reminds me of the old days.", place, quest.townName, quest.title),
        })
    end
    if quest.theme == "music" then
        return Quests.pickQuestLine(quest, {
            string.format("Get me a copy of '%s' from %s in %s. I never had a chance to listen to it.", quest.title, place, quest.townName),
            string.format("Ask around %s in %s for a copy of '%s'. It reminds me of the old days.", place, quest.townName, quest.title),
        })
    end
    if quest.theme == "liquor" then
        return string.format(
            "I need a drink, but I only drink the finest bourbons. Find me a %s from %s in %s and I'll make it worth your while.",
            quest.itemLabel:lower(), place, quest.townName)
    end
    if quest.theme == "medicine" then
        return string.format(
            "I need a bottle of %s. %s There should be some at %s in %s. Bring it back and I'll make it worth your while.",
            quest.itemLabel, quest.complaint, place, quest.townName)
    end
    local sentiment = Quests.getSentimentLine(quest)
    if Quests.isPersonalRoom(quest.roomName) then
        return string.format(
            "I had a place over in %s before all this. My %s is still sitting in the %s there. %s Bring it back to me.",
            quest.townName, quest.itemLabel:lower(), Quests.getRoomLabel(quest.roomName), sentiment)
    end
    if Quests.getNamedLocation(quest) then
        return string.format(
            "I left my %s at %s in %s. %s Bring it back to me.",
            quest.itemLabel:lower(), place, quest.townName, sentiment)
    end
    return string.format(
        "I left my %s somewhere in %s in %s. %s Bring it back to me.",
        quest.itemLabel:lower(), place, quest.townName, sentiment)
end

function Quests.getReminderLine(quest, hasItem)
    if hasItem then
        local label
        if quest.theme == "video" or quest.theme == "music" then
            label = string.format("copy of '%s'", quest.title)
        elseif quest.theme == "medicine" then
            label = quest.itemLabel
        else
            label = quest.itemLabel:lower()
        end
        return string.format("That's the one. Hand over my %s and we're square.", label)
    end
    local place = Quests.getPlaceReference(quest)
    if quest.theme == "video" or quest.theme == "music" then
        return string.format("Still nothing? A copy of '%s' from %s in %s. It's marked on your map.", quest.title, place, quest.townName)
    end
    if quest.theme == "liquor" then
        return string.format("Still nothing? My bourbon from %s in %s. It's marked on your map.", place, quest.townName)
    end
    if quest.theme == "medicine" then
        return string.format("Still nothing? I need the %s from %s in %s. It's marked on your map.", quest.itemLabel, place, quest.townName)
    end
    if Quests.isPersonalRoom(quest.roomName) then
        return string.format("Still nothing? My old place in %s, the %s. It's marked on your map.", quest.townName, Quests.getRoomLabel(quest.roomName))
    end
    return string.format("Still nothing? %s in %s. It's marked on your map.", place, quest.townName)
end

function Quests.getPlayerState(player)
    local modData = player:getModData()
    modData.BarteringQuests = modData.BarteringQuests or {}
    modData.BarteringQuests.active = modData.BarteringQuests.active or {}
    modData.BarteringQuests.cooldown = modData.BarteringQuests.cooldown or {}
    return modData.BarteringQuests
end

function Quests.getActive(player, bartererId)
    return Quests.getPlayerState(player).active[bartererId]
end

function Quests.getCooldownHours()
    return Bartering.getSandboxNumber("QuestCooldownDays", Quests.DEFAULT_COOLDOWN_DAYS) * 24
end

function Quests.getCooldownRemainingHours(player, bartererId)
    return BarteringTiming.remainingHours(Quests.getPlayerState(player).cooldown[bartererId])
end

function Quests.canRequest(player, bartererId)
    if not Bartering.hasMetBarterer(player, bartererId) then
        return false
    end
    if Quests.getActive(player, bartererId) then
        return false
    end
    return Quests.getCooldownRemainingHours(player, bartererId) <= 0
end

function Quests.getItemLabel(itemType)
    return InventoryItemFactory.CreateItem(itemType):getDisplayName()
end

function Quests.buildItemName(bartererId, itemLabel)
    return Bartering.getBartererDisplayName(bartererId) .. "'s " .. itemLabel
end

function Quests.isQuestItem(item)
    return item:getModData().BarteringQuestId ~= nil
end

function Quests.buildCouponName(bartererId)
    return "Coupon for " .. Bartering.getBartererDisplayName(bartererId)
end

function Quests.getCouponBarterer(item)
    return item:getModData().BarteringCouponBarterer
end

function Quests.isCouponType(itemName)
    return itemName == Quests.COUPON_ITEM
end

function Quests.acceptsCoupon(item, bartererId)
    local couponBarterer = Quests.getCouponBarterer(item)
    return couponBarterer == nil or couponBarterer == bartererId
end

function Quests.createCoupon(bartererId)
    local coupon = InventoryItemFactory.CreateItem(Quests.COUPON_ITEM)
    coupon:setName(Quests.buildCouponName(bartererId))
    coupon:getModData().BarteringCouponBarterer = bartererId
    return coupon
end

function Quests.findQuestItem(player, quest)
    local matches = player:getInventory():getAllEvalRecurse(function(item)
        return item:getModData().BarteringQuestId == quest.id
    end, ArrayList.new())
    if matches:size() == 0 then
        return nil
    end
    return matches:get(0)
end

function Quests.startCooldown(player, bartererId)
    Quests.getPlayerState(player).cooldown[bartererId] = getGameTime():getWorldAgeHours() + Quests.getCooldownHours()
end
