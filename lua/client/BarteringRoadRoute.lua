require "Bartering"

local getWorld = _G["getWorld"]
local events = _G["Events"]
local ArrayList = _G["ArrayList"]

Bartering.RoadRoute = Bartering.RoadRoute or {}
local RoadRoute = Bartering.RoadRoute

local CELL = 10
local ROAD_ZONE_TYPE = "Nav"
local REGION = 100
local BBOX_MARGIN = 400
local OFFROAD_COST = 6
local DIAGONAL_COST = 1.4142135
local HEURISTIC_WEIGHT = 1.6
local MAX_EXPANSIONS = 150000
local EXPANSIONS_PER_TICK = 500
local REGIONS_PER_TICK = 12
local SIMPLIFY_TOLERANCE = 2
local FINAL_TOLERANCE = 0.5
local SMOOTH_PASSES = 2
local SMOOTH_CUT = 5
local SMOOTH_MIN_TURN = 0.985
local KEY_STRIDE = 100000
local CACHE_LIMIT = 6
local CACHE_QUANTUM = 8

local NEIGHBOURS = {
    { 1, 0, 1 },
    { -1, 0, 1 },
    { 0, 1, 1 },
    { 0, -1, 1 },
    { 1, 1, DIAGONAL_COST },
    { 1, -1, DIAGONAL_COST },
    { -1, 1, DIAGONAL_COST },
    { -1, -1, DIAGONAL_COST },
}

local zoneBuffer = ArrayList.new()
local queue = {}
local cache = {}
local cacheOrder = {}

local function heapPush(job, key, priority)
    local keys, priorities = job.heapKeys, job.heapPriorities
    local index = job.heapSize + 1
    job.heapSize = index
    keys[index] = key
    priorities[index] = priority

    while index > 1 do
        local parent = math.floor(index / 2)
        if priorities[parent] <= priorities[index] then
            break
        end
        keys[parent], keys[index] = keys[index], keys[parent]
        priorities[parent], priorities[index] = priorities[index], priorities[parent]
        index = parent
    end
end

local function heapPop(job)
    local keys, priorities = job.heapKeys, job.heapPriorities
    local top = keys[1]
    local size = job.heapSize
    keys[1] = keys[size]
    priorities[1] = priorities[size]
    keys[size] = nil
    priorities[size] = nil
    size = size - 1
    job.heapSize = size

    local index = 1
    while true do
        local child = index * 2
        if child > size then
            break
        end
        if child + 1 <= size and priorities[child + 1] < priorities[child] then
            child = child + 1
        end
        if priorities[index] <= priorities[child] then
            break
        end
        keys[child], keys[index] = keys[index], keys[child]
        priorities[child], priorities[index] = priorities[index], priorities[child]
        index = child
    end

    return top
end

local function octile(fromX, fromY, toX, toY)
    local dx = math.abs(toX - fromX)
    local dy = math.abs(toY - fromY)
    local short = math.min(dx, dy)
    return (dx + dy - short) + DIAGONAL_COST * short
end

local function rasteriseZone(job, zone)
    local road = job.road
    local zoneX, zoneY = zone:getX(), zone:getY()
    local zoneWidth, zoneHeight = zone:getWidth(), zone:getHeight()
    local firstX = math.max(job.minCX, math.floor(zoneX / CELL))
    local lastX = math.min(job.maxCX, math.floor((zoneX + zoneWidth - 1) / CELL))
    local firstY = math.max(job.minCY, math.floor(zoneY / CELL))
    local lastY = math.min(job.maxCY, math.floor((zoneY + zoneHeight - 1) / CELL))

    local rect = {
        minX = zoneX,
        minY = zoneY,
        maxX = zoneX + zoneWidth - 1,
        maxY = zoneY + zoneHeight - 1,
    }

    for cellY = firstY, lastY do
        local rowKey = cellY * KEY_STRIDE
        for cellX = firstX, lastX do
            road[rowKey + cellX] = rect
        end
    end
end

local function ensureRegion(job, cellX, cellY)
    local regionX = math.floor(cellX * CELL / REGION)
    local regionY = math.floor(cellY * CELL / REGION)
    local regionKey = regionY * KEY_STRIDE + regionX
    if job.scanned[regionKey] then
        return
    end

    job.scanned[regionKey] = true
    job.regionsThisTick = job.regionsThisTick + 1

    zoneBuffer:clear()
    getWorld():getMetaGrid():getZonesIntersecting(
        regionX * REGION, regionY * REGION, 0, REGION, REGION, zoneBuffer)

    for i = 0, zoneBuffer:size() - 1 do
        local zone = zoneBuffer:get(i)
        if zone:getType() == ROAD_ZONE_TYPE and zone:getZ() == 0 then
            rasteriseZone(job, zone)
        end
    end
end

local function perpendicularDistance(pointX, pointY, startX, startY, endX, endY)
    local dx, dy = endX - startX, endY - startY
    local lengthSq = dx * dx + dy * dy
    if lengthSq == 0 then
        local ox, oy = pointX - startX, pointY - startY
        return math.sqrt(ox * ox + oy * oy)
    end

    local t = ((pointX - startX) * dx + (pointY - startY) * dy) / lengthSq
    t = math.max(0, math.min(1, t))
    local ox = pointX - (startX + t * dx)
    local oy = pointY - (startY + t * dy)
    return math.sqrt(ox * ox + oy * oy)
end

local function douglasPeucker(points, first, last, tolerance, keep)
    local worst, worstIndex = 0, nil
    for i = first + 1, last - 1 do
        local distance = perpendicularDistance(
            points[i].x, points[i].y,
            points[first].x, points[first].y,
            points[last].x, points[last].y)
        if distance > worst then
            worst, worstIndex = distance, i
        end
    end

    if worst > tolerance then
        douglasPeucker(points, first, worstIndex, tolerance, keep)
        douglasPeucker(points, worstIndex, last, tolerance, keep)
        return
    end

    keep[last] = true
end

local function simplify(points, tolerance)
    local keep = { [1] = true }
    douglasPeucker(points, 1, #points, tolerance, keep)

    local result = {}
    for i = 1, #points do
        if keep[i] then
            result[#result + 1] = points[i]
        end
    end
    return result
end

local function smoothCorners(points)
    if #points < 3 then
        return points
    end

    local result = { points[1] }
    for i = 2, #points - 1 do
        local previous, current, following = points[i - 1], points[i], points[i + 1]
        local inX, inY = current.x - previous.x, current.y - previous.y
        local outX, outY = following.x - current.x, following.y - current.y
        local inLength = math.sqrt(inX * inX + inY * inY)
        local outLength = math.sqrt(outX * outX + outY * outY)

        if inLength == 0 or outLength == 0
            or (inX * outX + inY * outY) / (inLength * outLength) > SMOOTH_MIN_TURN then
            result[#result + 1] = current
        else
            local inCut = math.min(SMOOTH_CUT, inLength * 0.5) / inLength
            local outCut = math.min(SMOOTH_CUT, outLength * 0.5) / outLength
            result[#result + 1] = { x = current.x - inX * inCut, y = current.y - inY * inCut }
            result[#result + 1] = { x = current.x + outX * outCut, y = current.y + outY * outCut }
        end
    end

    result[#result + 1] = points[#points]
    return result
end

local function measure(route)
    local points = route.points
    local lengths, total = { 0 }, 0
    for i = 2, #points do
        local dx = points[i].x - points[i - 1].x
        local dy = points[i].y - points[i - 1].y
        total = total + math.sqrt(dx * dx + dy * dy)
        lengths[i] = total
    end

    route.lengths = lengths
    route.total = total
end

local function buildPolyline(job)
    local raw = {}
    local key = job.goalKey
    while key do
        local cellY = math.floor(key / KEY_STRIDE)
        local cellX = key - cellY * KEY_STRIDE
        local x = cellX * CELL + CELL / 2
        local y = cellY * CELL + CELL / 2
        local rect = job.road[key]
        if rect then
            x = math.max(rect.minX, math.min(rect.maxX, x))
            y = math.max(rect.minY, math.min(rect.maxY, y))
        end
        table.insert(raw, 1, { x = x, y = y })
        key = job.parent[key]
    end

    raw[1] = { x = job.startX, y = job.startY }
    raw[#raw] = { x = job.targetX, y = job.targetY }

    local points = simplify(raw, SIMPLIFY_TOLERANCE)
    for _ = 1, SMOOTH_PASSES do
        points = smoothCorners(points)
    end

    job.points = simplify(points, FINAL_TOLERANCE)
    measure(job)

    job.status = "ready"
    job.road = nil
    job.scanned = nil
    job.gScore = nil
    job.parent = nil
    job.closed = nil
    job.heapKeys = nil
    job.heapPriorities = nil
end

local function searchStep(job)
    local gScore, parent, closed, road = job.gScore, job.parent, job.closed, job.road
    local goalCX, goalCY, goalKey = job.goalCX, job.goalCY, job.goalKey
    local minCX, maxCX, minCY, maxCY = job.minCX, job.maxCX, job.minCY, job.maxCY
    job.regionsThisTick = 0

    for _ = 1, EXPANSIONS_PER_TICK do
        if job.heapSize == 0 then
            job.status = "failed"
            return
        end

        local current = heapPop(job)
        if not closed[current] then
            closed[current] = true
            job.expansions = job.expansions + 1

            if current == goalKey then
                buildPolyline(job)
                return
            end

            if job.expansions > MAX_EXPANSIONS then
                job.status = "failed"
                return
            end

            local cellY = math.floor(current / KEY_STRIDE)
            local cellX = current - cellY * KEY_STRIDE
            local currentScore = gScore[current]

            for i = 1, #NEIGHBOURS do
                local offset = NEIGHBOURS[i]
                local nextX, nextY = cellX + offset[1], cellY + offset[2]
                if nextX >= minCX and nextX <= maxCX and nextY >= minCY and nextY <= maxCY then
                    local nextKey = nextY * KEY_STRIDE + nextX
                    if not closed[nextKey] then
                        ensureRegion(job, nextX, nextY)
                        local tentative = currentScore + offset[3] * (road[nextKey] and 1 or OFFROAD_COST)
                        local known = gScore[nextKey]
                        if known == nil or tentative < known then
                            gScore[nextKey] = tentative
                            parent[nextKey] = current
                            heapPush(job, nextKey, tentative + HEURISTIC_WEIGHT * octile(nextX, nextY, goalCX, goalCY))
                        end
                    end
                end
            end

            if job.regionsThisTick >= REGIONS_PER_TICK then
                return
            end
        end
    end
end

local function onTick()
    local job = queue[1]
    if not job then
        return
    end

    searchStep(job)

    if job.status ~= "searching" then
        table.remove(queue, 1)
    end
end

local function cacheKey(startX, startY, targetX, targetY)
    return string.format("%d:%d:%d:%d",
        math.floor(startX / CACHE_QUANTUM), math.floor(startY / CACHE_QUANTUM),
        math.floor(targetX / CACHE_QUANTUM), math.floor(targetY / CACHE_QUANTUM))
end

local function remember(key, route)
    cache[key] = route
    cacheOrder[#cacheOrder + 1] = key
    if #cacheOrder > CACHE_LIMIT then
        cache[table.remove(cacheOrder, 1)] = nil
    end
end

local function reverseRoute(route, startX, startY, targetX, targetY)
    local source = route.points
    local points = {}
    for i = #source, 1, -1 do
        points[#points + 1] = { x = source[i].x, y = source[i].y }
    end

    points[1] = { x = startX, y = startY }
    points[#points] = { x = targetX, y = targetY }

    local reversed = { status = "ready", points = points }
    measure(reversed)
    return reversed
end

function RoadRoute.ensure(trip)
    if trip.route then
        return trip.route
    end

    local startX, startY = trip.startX, trip.startY
    local targetX, targetY = trip.targetX, trip.targetY

    local key = cacheKey(startX, startY, targetX, targetY)
    local existing = cache[key]
    if existing then
        trip.route = existing
        return existing
    end

    local opposite = cache[cacheKey(targetX, targetY, startX, startY)]
    if opposite and opposite.status == "ready" then
        local route = reverseRoute(opposite, startX, startY, targetX, targetY)
        remember(key, route)
        trip.route = route
        return route
    end

    local minX = math.max(0, math.min(startX, targetX) - BBOX_MARGIN)
    local minY = math.max(0, math.min(startY, targetY) - BBOX_MARGIN)
    local maxX = math.max(startX, targetX) + BBOX_MARGIN
    local maxY = math.max(startY, targetY) + BBOX_MARGIN

    local startCX = math.floor(startX / CELL)
    local startCY = math.floor(startY / CELL)

    local job = {
        status = "searching",
        startX = startX,
        startY = startY,
        targetX = targetX,
        targetY = targetY,
        minCX = math.floor(minX / CELL),
        minCY = math.floor(minY / CELL),
        maxCX = math.floor(maxX / CELL),
        maxCY = math.floor(maxY / CELL),
        goalCX = math.floor(targetX / CELL),
        goalCY = math.floor(targetY / CELL),
        road = {},
        scanned = {},
        gScore = {},
        parent = {},
        closed = {},
        heapKeys = {},
        heapPriorities = {},
        heapSize = 0,
        expansions = 0,
        regionsThisTick = 0,
    }

    job.goalKey = job.goalCY * KEY_STRIDE + job.goalCX
    local startKey = startCY * KEY_STRIDE + startCX
    job.gScore[startKey] = 0
    heapPush(job, startKey, HEURISTIC_WEIGHT * octile(startCX, startCY, job.goalCX, job.goalCY))

    remember(key, job)
    trip.route = job
    queue[#queue + 1] = job
    return job
end

function RoadRoute.positionAt(route, progress)
    local points, lengths = route.points, route.lengths
    local target = math.max(0, math.min(1, progress)) * route.total

    for i = 2, #points do
        if lengths[i] >= target then
            local span = lengths[i] - lengths[i - 1]
            local fraction = span > 0 and (target - lengths[i - 1]) / span or 0
            local from, to = points[i - 1], points[i]
            return from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction, i
        end
    end

    local last = points[#points]
    return last.x, last.y, #points
end

events.OnTick.Add(onTick)
