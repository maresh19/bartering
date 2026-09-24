require "Fishing/FishingHandler"

local events = _G["Events"]
local instanceof = _G["instanceof"]
local Fishing = _G["Fishing"]

events.OnEquipPrimary.Remove(Fishing.Handler.onEquipPrimary)

function Fishing.Handler.onEquipPrimary(player, inventoryItem)
    if instanceof(player, "IsoPlayer") and player:isLocal() then
        Fishing.Handler.handleFishing(player, inventoryItem)
    end
end

events.OnEquipPrimary.Add(Fishing.Handler.onEquipPrimary)
