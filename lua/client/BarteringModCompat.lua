require "Bartering"
require "XpSystem/ISUI/ISSkillProgressBar"

local events = _G["Events"]
local Perks = _G["Perks"]
local ISSkillProgressBar = _G["ISSkillProgressBar"]
local print = require("BarteringPathTrace").log

local function getSortedBarterers()
    local barterers = {}
    for _, barterer in pairs(Bartering.Barterers) do
        table.insert(barterers, barterer)
    end

    table.sort(barterers, function(a, b)
        if a.requiredLevel == b.requiredLevel then
            return a.id < b.id
        end
        return a.requiredLevel < b.requiredLevel
    end)

    return barterers
end

local function formatTooltipNumber(value)
    local rounded = math.floor(value * 100 + 0.5) / 100
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    if rounded * 10 == math.floor(rounded * 10) then
        return string.format("%.1f", rounded)
    end
    return string.format("%.2f", rounded)
end

local function getBarteringUnlockLines(level)
    local lines = {}
    for _, barterer in ipairs(getSortedBarterers()) do
        local displayName = Bartering.getBartererDisplayName(barterer.id)
        if level >= barterer.requiredLevel then
            table.insert(lines, "Can barter with " .. displayName)
        end
    end
    return lines
end

local function getBarteringTooltipLines(level)
    local lines = {
        "+" .. formatTooltipNumber(Bartering.getSandboxNumber("BarterValueBonusPerLevel", 0.1) * level) .. " bonus Bartering XP from trades",
    }

    local bonusStockItems = Bartering.getSkillSlotCount(0, level)
    if bonusStockItems > 0 then
        table.insert(lines, "+" .. tostring(bonusStockItems) .. " additional visible barter stock items")
    end

    for _, line in ipairs(getBarteringUnlockLines(level)) do
        table.insert(lines, line)
    end

    return lines
end

local function registerDescriptiveSkillTooltipsBartering()
    local DST = _G["DST"]
    if not DST or not DST.SkillTooltipDefinitions then
        return
    end

    local definitions = {}
    for level = 1, 10 do
        definitions["level_" .. tostring(level)] = getBarteringTooltipLines(level)
    end
    DST.SkillTooltipDefinitions.Bartering = definitions
end

local function registerNecroForgeBarteringPerk()
    local necroList = _G["NecroList"]
    if not necroList or not necroList.Items then
        return
    end

    for key, value in pairs(necroList.Items) do
        if type(key) == "string" and string.find(key, "^NecroExp") and type(value) == "table" and value[12] == Perks.Bartering then
            return
        end
    end

    local perkKey = "NecroExp034"
    if necroList.Items[perkKey] then
        local index = 34
        repeat
            index = index + 1
            perkKey = string.format("NecroExp%03d", index)
        until not necroList.Items[perkKey]
    end

    necroList.Items[perkKey] = {
        "Perks",
        nil,
        nil,
        "Experience - Bartering",
        "NecroForge.NecroFunction",
        "media/textures/Function_Exp.png",
        nil,
        nil,
        nil,
        true,
        "Exp",
        Perks.Bartering,
    }
end

local function appendVanillaBarteringTooltip(self, lvlSelected)
    if not self or not self.perk or self.perk:getType() ~= Perks.Bartering then
        return
    end

    if not self.message or string.find(self.message, "bonus Bartering XP from trades", 1, true) then
        return
    end

    local lines = getBarteringTooltipLines(lvlSelected + 1)
    if #lines == 0 then
        return
    end

    self.message = self.message .. " <LINE> "
    for _, line in ipairs(lines) do
        self.message = self.message .. " <LINE> " .. line
    end
end

local originalUpdateTooltip = ISSkillProgressBar.updateTooltip

function ISSkillProgressBar:updateTooltip(lvlSelected)
    originalUpdateTooltip(self, lvlSelected)
    appendVanillaBarteringTooltip(self, lvlSelected)
end

registerNecroForgeBarteringPerk()
registerDescriptiveSkillTooltipsBartering()
events.OnGameBoot.Add(registerNecroForgeBarteringPerk)
events.OnGameBoot.Add(registerDescriptiveSkillTooltipsBartering)
events.OnGameStart.Add(registerNecroForgeBarteringPerk)
events.OnGameStart.Add(registerDescriptiveSkillTooltipsBartering)

local BanditCompatibility = _G["BanditCompatibility"]
if BanditCompatibility then
    local isRagdoll = BanditCompatibility.IsRagdoll
    BanditCompatibility.IsRagdoll = function(zombie)
        return zombie:getVariableBoolean("Barterer") or isRagdoll(zombie)
    end
end
