Bartering = Bartering or {}

local ModData = _G["ModData"]
local events = _G["Events"]

local FLUSH_INTERVAL_TICKS = 30

local SYNC_KEY_PREFIXES = {
    "BarteringIdentity_",
    "BarteringLife_",
    "BarteringBarterer_",
}

local dirtyKeys = {}
local flushTicks = 0

local function bartererKeys(bartererId)
    local keys = {}
    for _, prefix in ipairs(SYNC_KEY_PREFIXES) do
        table.insert(keys, prefix .. bartererId)
    end
    return keys
end

function Bartering.getSyncedModDataKeys()
    local keys = {}
    for bartererId in pairs(Bartering.Barterers) do
        for _, key in ipairs(bartererKeys(bartererId)) do
            table.insert(keys, key)
        end
    end
    return keys
end

function Bartering.isBartererDataAuthority()
    return not isClient()
end

function Bartering.markBartererDataDirty(bartererId)
    if not isServer() then
        return
    end
    for _, key in ipairs(bartererKeys(bartererId)) do
        dirtyKeys[key] = true
    end
end

local function flushBartererData()
    flushTicks = flushTicks + 1
    if flushTicks < FLUSH_INTERVAL_TICKS then
        return
    end
    flushTicks = 0
    for key in pairs(dirtyKeys) do
        dirtyKeys[key] = nil
        ModData.transmit(key)
    end
end

local function requestBartererData()
    for _, key in ipairs(Bartering.getSyncedModDataKeys()) do
        ModData.request(key)
    end
end

local function onReceiveBartererData(key, received)
    if not received then
        return
    end
    ModData.add(key, received)
end

if isServer() then
    events.OnTick.Add(flushBartererData)
end

if isClient() then
    events.OnGameStart.Add(requestBartererData)
    events.OnReceiveGlobalModData.Add(onReceiveBartererData)
end
