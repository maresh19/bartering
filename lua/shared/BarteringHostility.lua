Bartering = Bartering or {}

local ModData = _G["ModData"]
local print = require("BarteringPathTrace").log

Bartering.Hostility = {}

Bartering.Hostility.RESTORE_FRACTION = 0.9

function Bartering.getHostilityTable(bartererId)
    return ModData.getOrCreate("BarteringHostility_" .. tostring(bartererId))
end

function Bartering.getAmendsTable(bartererId)
    return ModData.getOrCreate("BarteringAmends_" .. tostring(bartererId))
end

function Bartering.Hostility.getRecord(bartererId, player)
    return Bartering.getHostilityTable(bartererId)[player:getUsername()]
end

function Bartering.Hostility.isHostileTo(bartererId, player)
    return Bartering.Hostility.getRecord(bartererId, player) ~= nil
end

function Bartering.Hostility.getPreRelation(bartererId, player)
    local record = Bartering.Hostility.getRecord(bartererId, player)
    return record and record.preRelation or 0
end

function Bartering.Hostility.getRestoredRelation(bartererId, player)
    return math.floor(Bartering.Hostility.getPreRelation(bartererId, player)
        * Bartering.Hostility.RESTORE_FRACTION)
end

function Bartering.Hostility.getAmendsCost(bartererId, player)
    local level = math.min(Bartering.Relations.STARS,
        math.floor(Bartering.Hostility.getPreRelation(bartererId, player) / Bartering.Relations.VALUE_PER_STAR))
    return math.max(0, 100 - level * 10)
end

function Bartering.Hostility.isAmendsPendingFor(bartererId, player)
    return Bartering.getAmendsTable(bartererId).player == player:getUsername()
end

function Bartering.Hostility.isAmendsCalledFor(bartererId, player)
    local record = Bartering.getAmendsTable(bartererId)
    return record.player == player:getUsername() and record.called == true
end

function Bartering.Hostility.hasUnresolved(bartererId)
    if Bartering.getAmendsTable(bartererId).player then
        return false
    end
    local hostility = Bartering.getHostilityTable(bartererId)
    for username in pairs(hostility) do
        return true
    end
    return false
end

function Bartering.Hostility.trigger(bartererId, player)
    local hostility = Bartering.getHostilityTable(bartererId)
    local username = player:getUsername()
    if not hostility[username] then
        hostility[username] = { preRelation = Bartering.Relations.get(player, bartererId) }
    end
    Bartering.Relations.reset(player, bartererId)
    Bartering.transmitBartererDataNow(bartererId)
end

function Bartering.Hostility.openAmends(bartererId, player)
    local record = Bartering.getAmendsTable(bartererId)
    record.player = player:getUsername()
    record.playerOnlineId = player:getOnlineID()
    record.called = nil
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.Hostility.markAmendsCalled(bartererId)
    Bartering.getAmendsTable(bartererId).called = true
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.Hostility.cancelAmends(bartererId)
    local record = Bartering.getAmendsTable(bartererId)
    print(string.format("[Bartering][Hostility] amends cancelled for %s | was=%s called=%s",
        tostring(bartererId), tostring(record.player), tostring(record.called)))
    record.player, record.playerOnlineId, record.called = nil, nil, nil
    Bartering.transmitBartererDataNow(bartererId)
end

function Bartering.Hostility.complete(bartererId, player)
    Bartering.Relations.set(player, bartererId, Bartering.Hostility.getRestoredRelation(bartererId, player))
    Bartering.getHostilityTable(bartererId)[player:getUsername()] = nil
    local record = Bartering.getAmendsTable(bartererId)
    record.player, record.playerOnlineId, record.called = nil, nil, nil
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.Hostility.clearAll(bartererId)
    local hostility = Bartering.getHostilityTable(bartererId)
    for username in pairs(hostility) do
        hostility[username] = nil
    end
    local record = Bartering.getAmendsTable(bartererId)
    record.player, record.playerOnlineId, record.called = nil, nil, nil
    Bartering.markBartererDataDirty(bartererId)
end

function Bartering.Hostility.clearForPlayer(player)
    local username = player:getUsername()
    local cleared = {}
    for bartererId in pairs(Bartering.Barterers) do
        local hostility = Bartering.getHostilityTable(bartererId)
        if hostility[username] then
            hostility[username] = nil
            table.insert(cleared, bartererId)
            Bartering.markBartererDataDirty(bartererId)
        end
        local record = Bartering.getAmendsTable(bartererId)
        if record.player == username then
            record.player, record.playerOnlineId, record.called = nil, nil, nil
            table.insert(cleared, bartererId .. "(amends)")
            Bartering.markBartererDataDirty(bartererId)
        end
    end
    print("[Bartering][Hostility] clearForPlayer " .. tostring(username) .. " | cleared="
        .. (#cleared > 0 and table.concat(cleared, ",") or "none"))
end

function Bartering.Hostility.reportHit(zombie, attacker, weapon)
    local isShove = attacker:isDoShove()
    print("[Bartering][Hostility] hit on " .. zombie:getVariableString("BartererId")
        .. " weapon=" .. tostring(weapon and weapon:getFullType())
        .. " doShove=" .. tostring(isShove))
    sendClientCommand(attacker, "Bartering", isShove and "shovedBarterer" or "attackedBarterer", {
        id = zombie:getVariableString("BartererId"),
    })
end
