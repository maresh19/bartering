require "Bartering"
require "XpSystem/ISUI/ISCharacterInfo"

local ISCharacterInfo = _G["ISCharacterInfo"]
local Perks = _G["Perks"]

local originalLoadPerk = ISCharacterInfo.loadPerk

ISCharacterInfo.loadPerk = function(self)
    local perks = originalLoadPerk(self)
    if Bartering.getSandboxBoolean("EnableSkill", true) then
        return perks
    end
    for _, group in pairs(perks) do
        for i = #group, 1, -1 do
            if group[i]:getType() == Perks.Bartering then
                table.remove(group, i)
            end
        end
    end
    return perks
end
