Bartering = Bartering or {}

local Perks = _G["Perks"]

function Bartering.addBarteringXp(player, xp)
    if xp <= 0 then
        return
    end

    player:getXp():AddXP(Perks.Bartering, xp)
end
