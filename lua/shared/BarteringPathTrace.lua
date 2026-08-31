local events = _G["Events"]
local isClient = _G["isClient"]
local getTimeInMillis = _G["getTimeInMillis"]

local BarteringPathTrace = {}

local TUNE = {}
TUNE.FLUSH_INTERVAL_MS = 5000
TUNE.TRANSITION_PRINT_LIMIT = 3
TUNE.STALE_GOAL_TICKS = 30

local records = {}
local nextFlushAt = 0

local function tracing()
    return Bartering.getSandboxBoolean("DebugMode", false)
end

local function traceKey(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    if bartererId and bartererId ~= "" then
        return bartererId
    end
    return tostring(zombie)
end

local function newRecord(id, zombie)
    return {
        id = id,
        zombie = zombie,
        aiTicks = 0,
        driveTicks = 0,
        aiStops = {},
        driveStops = {},
        goals = {},
        swallowed = {},
        counters = {},
        flaps = {},
        flapPrints = {},
        goalConsumed = 0,
        goalLatency = 0,
        windowStartMs = getTimeInMillis(),
        windowStartX = zombie:getX(),
        windowStartY = zombie:getY(),
    }
end

local function recordFor(zombie)
    local id = traceKey(zombie)
    local record = records[id]
    if not record then
        record = newRecord(id, zombie)
        records[id] = record
    end
    record.zombie = zombie
    return record
end

local function displayName(record)
    return Bartering.getBartererDisplayName(record.id)
end

local function bump(map, name)
    map[name] = (map[name] or 0) + 1
end

local function noteTransition(record, layer, field, ticksField, reason)
    local previous = record[field]
    if previous == reason then
        record[ticksField] = record[ticksField] + 1
        return
    end

    if previous then
        local pair = previous .. ">" .. reason
        bump(record.flaps, layer .. ":" .. pair)
        local prints = (record.flapPrints[pair] or 0) + 1
        record.flapPrints[pair] = prints
        if prints <= TUNE.TRANSITION_PRINT_LIMIT then
            print(string.format("[Bartering][Path] %s | %s %s -> %s after %d ticks",
                displayName(record), layer, previous, reason, record[ticksField]))
        end
    end

    record[field] = reason
    record[ticksField] = 1
end

function BarteringPathTrace.aiStop(zombie, reason)
    if not tracing() then
        return
    end
    local record = recordFor(zombie)
    record.aiTicks = record.aiTicks + 1
    bump(record.aiStops, reason)
    noteTransition(record, "ai", "lastAiStop", "lastAiTicks", reason)
end

function BarteringPathTrace.driveStop(zombie, reason)
    if not tracing() then
        return
    end
    local record = recordFor(zombie)
    record.driveTicks = record.driveTicks + 1
    bump(record.driveStops, reason)
    noteTransition(record, "drive", "lastDriveStop", "lastDriveTicks", reason)

    if not record.goalPending then
        return
    end

    record.goalPendingTicks = record.goalPendingTicks + 1
    bump(record.swallowed, reason)
    if record.goalPendingTicks == TUNE.STALE_GOAL_TICKS then
        print(string.format(
            "[Bartering][Path] %s | goal %d,%d,%d from %s unconsumed for %d drive ticks | blocked at %s pos=%.2f,%.2f",
            displayName(record), record.goalX, record.goalY, record.goalZ,
            record.goalSource, record.goalPendingTicks, reason,
            zombie:getX(), zombie:getY()))
    end
end

function BarteringPathTrace.counter(zombie, name)
    if not tracing() then
        return
    end
    bump(recordFor(zombie).counters, name)
end

local function goalBucket(record, source)
    local bucket = record.goals[source]
    if not bucket then
        bucket = { fresh = 0, repeated = 0, cleared = 0 }
        record.goals[source] = bucket
    end
    return bucket
end

function BarteringPathTrace.goal(zombie, source, x, y, z)
    if not tracing() then
        return
    end
    local record = recordFor(zombie)
    local bucket = goalBucket(record, source)
    local gx, gy, gz = math.floor(x), math.floor(y), math.floor(z)

    if record.goalSource == source and record.goalX == gx and record.goalY == gy and record.goalZ == gz then
        bucket.repeated = bucket.repeated + 1
        return
    end

    bucket.fresh = bucket.fresh + 1
    record.goalSource = source
    record.goalX, record.goalY, record.goalZ = gx, gy, gz
    record.goalPending = true
    record.goalPendingTicks = 0
end

function BarteringPathTrace.goalCleared(zombie, source)
    if not tracing() then
        return
    end
    local record = recordFor(zombie)
    if record.goalSource == nil and not record.goalPending then
        bump(record.counters, "goal.clear.redundant")
        return
    end
    goalBucket(record, source).cleared = goalBucket(record, source).cleared + 1
    record.goalSource = nil
    record.goalX, record.goalY, record.goalZ = nil, nil, nil
    record.goalPending = false
    record.goalPendingTicks = 0
end

function BarteringPathTrace.goalConsumed(zombie, x, y, z)
    if not tracing() then
        return
    end
    local record = recordFor(zombie)
    if not record.goalPending then
        bump(record.counters, "goal.consume.stale")
        return
    end

    record.goalConsumed = record.goalConsumed + 1
    record.goalLatency = record.goalLatency + record.goalPendingTicks
    record.goalPending = false
    if record.goalX ~= x or record.goalY ~= y or record.goalZ ~= z then
        bump(record.counters, "goal.redirected")
    end
end

function BarteringPathTrace.forget(zombie)
    records[traceKey(zombie)] = nil
end

local function formatCounts(map)
    local list = {}
    for name, count in pairs(map) do
        list[#list + 1] = { name = name, count = count }
    end
    if #list == 0 then
        return nil
    end
    table.sort(list, function(a, b)
        if a.count == b.count then
            return a.name < b.name
        end
        return a.count > b.count
    end)
    local parts = {}
    for _, item in ipairs(list) do
        parts[#parts + 1] = string.format("%s=%d", item.name, item.count)
    end
    return table.concat(parts, " ")
end

local function formatGoals(record)
    local parts = {}
    for source, bucket in pairs(record.goals) do
        parts[#parts + 1] = string.format("%s(new=%d repeat=%d clear=%d)",
            source, bucket.fresh, bucket.repeated, bucket.cleared)
    end
    if #parts == 0 then
        return nil
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

local function line(record, section, body)
    if not body then
        return
    end
    print(string.format("[Bartering][PathTrace] %s | %s | %s", displayName(record), section, body))
end

local function flushRecord(record, nowMs)
    if record.aiTicks == 0 and record.driveTicks == 0 then
        return false
    end

    local zombie = record.zombie
    local dx = zombie:getX() - record.windowStartX
    local dy = zombie:getY() - record.windowStartY
    local seconds = (nowMs - record.windowStartMs) / 1000

    print(string.format(
        "[Bartering][PathTrace] %s [%s] | ai=%d drive=%d window=%.1fs moved=%.1f pos=%.1f,%.1f,%.0f state=%s",
        displayName(record), record.id, record.aiTicks, record.driveTicks, seconds,
        math.sqrt(dx * dx + dy * dy),
        zombie:getX(), zombie:getY(), zombie:getZ(),
        tostring(zombie:getVariableString("BartererState"))))

    line(record, "ai-stop", formatCounts(record.aiStops))
    line(record, "drive-stop", formatCounts(record.driveStops))

    local goals = formatGoals(record)
    if goals then
        local latency = 0
        if record.goalConsumed > 0 then
            latency = record.goalLatency / record.goalConsumed
        end
        line(record, "goal", string.format("%s | consumed=%d avgWaitTicks=%.1f", goals, record.goalConsumed, latency))
    end

    line(record, "swallowed", formatCounts(record.swallowed))
    line(record, "counters", formatCounts(record.counters))
    line(record, "flaps", formatCounts(record.flaps))

    record.aiTicks = 0
    record.driveTicks = 0
    record.aiStops = {}
    record.driveStops = {}
    record.goals = {}
    record.swallowed = {}
    record.counters = {}
    record.flaps = {}
    record.flapPrints = {}
    record.goalConsumed = 0
    record.goalLatency = 0
    record.windowStartMs = nowMs
    record.windowStartX = zombie:getX()
    record.windowStartY = zombie:getY()
    return true
end

local function flushAll()
    local nowMs = getTimeInMillis()
    local reported = 0
    for id, record in pairs(records) do
        if flushRecord(record, nowMs) then
            reported = reported + 1
        else
            records[id] = nil
        end
    end
    return reported
end

function BarteringPathTrace.dump()
    if flushAll() == 0 then
        print("[Bartering][PathTrace] no barterer pathing activity in window")
    end
end

local function onTick()
    if not tracing() then
        return
    end
    local nowMs = getTimeInMillis()
    if nowMs < nextFlushAt then
        return
    end
    nextFlushAt = nowMs + TUNE.FLUSH_INTERVAL_MS
    flushAll()
end

if not isClient() then
    events.OnTick.Add(onTick)
end

return BarteringPathTrace
