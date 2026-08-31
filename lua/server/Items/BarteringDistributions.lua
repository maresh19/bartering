require "Items/ProceduralDistributions"

local events = _G["Events"]
local ProceduralDistributions = _G["ProceduralDistributions"]

local BOOK_ITEM_PREFIX = "Bartering.BookBartering"

local BOOK_DISTRIBUTIONS = {
    { list = "BookstoreBooks", weights = { 10, 8, 6, 4, 2 } },
    { list = "LibraryBooks", weights = { 8, 6, 4, 2, 1 } },
    { list = "CrateBooks", weights = { 6, 4, 2, 1, 0.5 } },
    { list = "PostOfficeBooks", weights = { 6, 4, 2, 1, 0.5 } },
    { list = "ClassroomMisc", weights = { 2, 1, 0.5, 0.1, 0.01 } },
    { list = "ClassroomShelves", weights = { 2, 1, 0.5, 0.1, 0.01 } },
    { list = "LivingRoomShelf", weights = { 2, 1, 0.5, 0.1, 0.01 } },
    { list = "LivingRoomShelfNoTapes", weights = { 2, 1, 0.5, 0.1, 0.01 } },
    { list = "ShelfGeneric", weights = { 2, 1, 0.5, 0.1, 0.01 } },
}

local function addBarteringBooks()
    for _, distribution in ipairs(BOOK_DISTRIBUTIONS) do
        local items = ProceduralDistributions.list[distribution.list].items
        for volume, weight in ipairs(distribution.weights) do
            table.insert(items, BOOK_ITEM_PREFIX .. tostring(volume))
            table.insert(items, weight)
        end
    end
end

events.OnPreDistributionMerge.Add(addBarteringBooks)
