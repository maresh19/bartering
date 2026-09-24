require "Bartering"
require "Map/BarteringWaterMask"
require "Map/BarteringRoadGraph"

local getWorld = _G["getWorld"]
local events = _G["Events"]
local ArrayList = _G["ArrayList"]
local getTimeInMillis = _G["getTimeInMillis"]
local print = require("BarteringPathTrace").log

Bartering.RoadRoute = Bartering.RoadRoute or {}
local RoadRoute = Bartering.RoadRoute

RoadRoute.ARRIVAL_STANDOFF = 20

local ROAD_ZONE = "Nav"
local REGION = 100
local BUCKET = 100
local BBOX_MARGIN = 400
local BRIDGE_GAP = 140
local OFFROAD_SURCHARGE = 8
local SHORTCUT_GAP = 45
local SHORTCUT_SURCHARGE = 2.0
local PREFERRED_DISCOUNT = 0.5
local PREFERRED_LIMIT = 400
local WATER_SURCHARGE = 40
local ENDPOINT_LINK_RADIUS = 250
local ENDPOINT_LINK_MAX = 2000
local FRONT_ROAD_SLACK = 4
local HEURISTIC_WEIGHT = 1.15
local MAX_EXPANSIONS = 60000
local WORK_PER_TICK = 800
local REGIONS_PER_TICK = 4
local BAKED_PER_TICK = 400
local JOBS_PER_TICK = 1
local SIMPLIFY_TOLERANCE = 2
local CACHE_LIMIT = 6
local CACHE_QUANTUM = 8

local START_NODE = 1
local GOAL_NODE = 2
local NODE_OFFSET = 2

local WATER_ROWS = Bartering.WaterMask.rows
local WATER_CELL = Bartering.WaterMask.cell

local graph = { rects = {}, rectKeys = {}, buckets = {}, scanned = {}, neighbors = {} }
local preferredRects = {}
local preferredCount = 0
local zoneBuffer = ArrayList.new()
local queue = {}
local cache = {}
local cacheOrder = {}

local function isWaterAt(x, y)
    local row = WATER_ROWS[math.floor(y / WATER_CELL)]
    if not row then
        return false
    end
    local cellX = math.floor(x / WATER_CELL)
    for i = 1, #row, 2 do
        if cellX >= row[i] and cellX <= row[i + 1] then
            return true
        end
    end
    return false
end

local function heapPush(job, node, priority)
    local nodes, priorities = job.heapNodes, job.heapPriorities
    local index = job.heapSize + 1
    job.heapSize = index
    nodes[index] = node
    priorities[index] = priority

    while index > 1 do
        local parent = math.floor(index / 2)
        if priorities[parent] <= priorities[index] then
            break
        end
        nodes[parent], nodes[index] = nodes[index], nodes[parent]
        priorities[parent], priorities[index] = priorities[index], priorities[parent]
        index = parent
    end
end

local function heapPop(job)
    local nodes, priorities = job.heapNodes, job.heapPriorities
    local top = nodes[1]
    local size = job.heapSize
    nodes[1] = nodes[size]
    priorities[1] = priorities[size]
    nodes[size] = nil
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
        nodes[child], nodes[index] = nodes[index], nodes[child]
        priorities[child], priorities[index] = priorities[index], priorities[child]
        index = child
    end

    return top
end

local function distance(fromX, fromY, toX, toY)
    local dx, dy = toX - fromX, toY - fromY
    return math.sqrt(dx * dx + dy * dy)
end

local function closestPointOn(rect, x, y)
    return math.max(rect.minX, math.min(rect.maxX, x)),
        math.max(rect.minY, math.min(rect.maxY, y))
end

local function portalBetween(a, b)
    local lowX = math.max(a.minX, b.minX)
    local highX = math.min(a.maxX, b.maxX)
    local lowY = math.max(a.minY, b.minY)
    local highY = math.min(a.maxY, b.maxY)
    return (lowX + highX) / 2, (lowY + highY) / 2
end

local function rectGap(a, b)
    local dx = math.max(0, math.max(a.minX - b.maxX, b.minX - a.maxX))
    local dy = math.max(0, math.max(a.minY - b.maxY, b.minY - a.maxY))
    return math.sqrt(dx * dx + dy * dy)
end

local function bucketRect(index, minX, minY, maxX, maxY)
    for bucketX = math.floor(minX / BUCKET), math.floor(maxX / BUCKET) do
        for bucketY = math.floor(minY / BUCKET), math.floor(maxY / BUCKET) do
            local bucketKey = bucketY * 100000 + bucketX
            local bucket = graph.buckets[bucketKey]
            if not bucket then
                bucket = {}
                graph.buckets[bucketKey] = bucket
            end
            bucket[#bucket + 1] = index
        end
    end
end

local function addRect(job, minX, minY, maxX, maxY)
    local key = minX .. ":" .. minY .. ":" .. maxX .. ":" .. maxY
    if graph.rectKeys[key] then
        return
    end
    graph.rectKeys[key] = true

    graph.rects[#graph.rects + 1] = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
    local index = #graph.rects

    for bucketX = math.floor(minX / BUCKET), math.floor(maxX / BUCKET) do
        for bucketY = math.floor(minY / BUCKET), math.floor(maxY / BUCKET) do
            local bucketKey = bucketY * 100000 + bucketX
            local bucket = graph.buckets[bucketKey]
            if not bucket then
                bucket = {}
                graph.buckets[bucketKey] = bucket
            end
            bucket[#bucket + 1] = index
        end
    end
end

local baked = Bartering.RoadGraph

local function loadBakedGraph()
    if graph.bakedLoaded then
        return true
    end

    local data = baked.rects
    local index = graph.bakedIndex or 1
    local limit = math.min(#data, index + BAKED_PER_TICK * 4 - 1)

    while index <= limit do
        addRect(nil, data[index], data[index + 1], data[index + 2], data[index + 3])
        index = index + 4
    end

    graph.bakedIndex = index
    if index > #data then
        graph.bakedLoaded = true
        return true
    end
    return false
end

local function isBakedRegion(regionX, regionY)
    local x1 = regionX * REGION
    local y1 = regionY * REGION
    return x1 >= baked.minX and y1 >= baked.minY
        and x1 + REGION - 1 <= baked.maxX and y1 + REGION - 1 <= baked.maxY
end

local function isBakedArea(minX, minY, maxX, maxY)
    return isBakedRegion(math.floor(minX / REGION), math.floor(minY / REGION))
        and isBakedRegion(math.floor(maxX / REGION), math.floor(maxY / REGION))
end

local function scanRegion(job, regionX, regionY)
    local regionKey = regionY * 100000 + regionX
    if graph.scanned[regionKey] then
        return
    end
    if isBakedRegion(regionX, regionY) then
        graph.scanned[regionKey] = true
        return
    end

    graph.scanned[regionKey] = true
    job.regionsThisTick = job.regionsThisTick + 1

    zoneBuffer:clear()
    getWorld():getMetaGrid():getZonesIntersecting(
        regionX * REGION, regionY * REGION, 0, REGION, REGION, zoneBuffer)

    for i = 0, zoneBuffer:size() - 1 do
        local zone = zoneBuffer:get(i)
        if zone:getType() == ROAD_ZONE and zone:getZ() == 0 then
            local zoneX, zoneY = zone:getX(), zone:getY()
            addRect(job, zoneX, zoneY,
                zoneX + zone:getWidth() - 1, zoneY + zone:getHeight() - 1)
        end
    end
end

local function scanArea(job, minX, minY, maxX, maxY)
    minX = math.max(job.minX, minX)
    minY = math.max(job.minY, minY)
    maxX = math.min(job.maxX, maxX)
    maxY = math.min(job.maxY, maxY)

    for regionX = math.floor(minX / REGION), math.floor(maxX / REGION) do
        for regionY = math.floor(minY / REGION), math.floor(maxY / REGION) do
            if job.regionsThisTick >= REGIONS_PER_TICK then
                return false
            end
            scanRegion(job, regionX, regionY)
        end
    end
    return true
end

local function nearbyRects(job, minX, minY, maxX, maxY)
    local generation = job.generation + 1
    job.generation = generation

    local seen, list = job.seenMark, job.foundList
    local count = 0

    for bucketX = math.floor(minX / BUCKET), math.floor(maxX / BUCKET) do
        for bucketY = math.floor(minY / BUCKET), math.floor(maxY / BUCKET) do
            local bucket = graph.buckets[bucketY * 100000 + bucketX]
            if bucket then
                for i = 1, #bucket do
                    local index = bucket[i]
                    if seen[index] ~= generation then
                        seen[index] = generation
                        count = count + 1
                        list[count] = index
                    end
                end
            end
        end
    end

    job.work = job.work + count
    return count
end

local function offroadPremium(gap, fromX, fromY, toX, toY)
    if gap <= 0 then
        return 0
    end

    local shortcut = math.min(gap, SHORTCUT_GAP)
    local remainder = gap - shortcut
    local extra = shortcut * (SHORTCUT_SURCHARGE - 1) + remainder * (OFFROAD_SURCHARGE - 1)

    if isWaterAt((fromX + toX) / 2, (fromY + toY) / 2) then
        extra = extra + gap * WATER_SURCHARGE
    end
    return extra
end

local function heuristic(job, x, y)
    return distance(x, y, job.targetX, job.targetY) * HEURISTIC_WEIGHT
end

local function relax(job, node, tentative, parent, entryX, entryY, viaX, viaY)
    local known = job.gScore[node]
    if known ~= nil and tentative >= known then
        return
    end
    job.gScore[node] = tentative
    job.parent[node] = parent
    job.entryX[node] = entryX
    job.entryY[node] = entryY
    job.viaX[node] = viaX
    job.viaY[node] = viaY
    heapPush(job, node, tentative + heuristic(job, entryX, entryY))
end

local function frontRoads(job, x, y, radiusKey)
    local radius = job[radiusKey] or ENDPOINT_LINK_RADIUS
    local count = 0

    while true do
        if not scanArea(job, x - radius, y - radius, x + radius, y + radius) then
            job[radiusKey] = radius
            return nil
        end

        count = nearbyRects(job, x - radius, y - radius, x + radius, y + radius)

        if count > 0 or radius >= ENDPOINT_LINK_MAX then
            break
        end
        radius = radius * 2
    end

    job[radiusKey] = radius

    local nearest = math.huge
    local gaps = {}
    for i = 1, count do
        local pointX, pointY = closestPointOn(graph.rects[job.foundList[i]], x, y)
        gaps[i] = distance(x, y, pointX, pointY)
        if gaps[i] < nearest then
            nearest = gaps[i]
        end
    end

    local linked = {}
    for i = 1, count do
        if gaps[i] <= nearest + FRONT_ROAD_SLACK then
            linked[#linked + 1] = job.foundList[i]
        end
    end
    return linked
end

local function expandStart(job)
    if not job.goalRects then
        local linked = frontRoads(job, job.targetX, job.targetY, "goalRadius")
        if not linked then
            return false
        end
        job.goalRects = {}
        for i = 1, #linked do
            job.goalRects[linked[i]] = true
        end
    end

    local linked = frontRoads(job, job.startX, job.startY, "linkRadius")
    if not linked then
        return false
    end

    for i = 1, #linked do
        local index = linked[i]
        local pointX, pointY = closestPointOn(graph.rects[index], job.startX, job.startY)
        local gap = distance(job.startX, job.startY, pointX, pointY)
        local cost = gap
            + offroadPremium(gap, job.startX, job.startY, pointX, pointY)
        relax(job, index + NODE_OFFSET, cost, START_NODE, pointX, pointY)
    end

    local direct = distance(job.startX, job.startY, job.targetX, job.targetY)
    relax(job, GOAL_NODE,
        direct + offroadPremium(direct, job.startX, job.startY, job.targetX, job.targetY),
        START_NODE, job.targetX, job.targetY)

    return true
end

local function collectNeighbors(job, rect, minX, minY, maxX, maxY)
    local list = {}
    local size = 0
    local count = nearbyRects(job, minX, minY, maxX, maxY)

    for i = 1, count do
        local index = job.foundList[i]
        local other = graph.rects[index]
        if other ~= rect then
            local gap = rectGap(rect, other)
            if gap <= BRIDGE_GAP then
                local portalX, portalY = portalBetween(rect, other)
                local viaX, viaY = closestPointOn(rect, portalX, portalY)
                local nextX, nextY = closestPointOn(other, portalX, portalY)
                list[size + 1] = index
                list[size + 2] = gap
                list[size + 3] = viaX
                list[size + 4] = viaY
                list[size + 5] = nextX
                list[size + 6] = nextY
                list[size + 7] = offroadPremium(gap, viaX, viaY, nextX, nextY)
                size = size + 7
            end
        end
    end

    return list
end

local function expandRect(job, node)
    local rectIndex = node - NODE_OFFSET
    local rect = graph.rects[rectIndex]
    local entryX, entryY = job.entryX[node], job.entryY[node]
    local score = job.gScore[node]

    local list = graph.neighbors[rectIndex]
    if not list then
        local minX, minY = rect.minX - BRIDGE_GAP, rect.minY - BRIDGE_GAP
        local maxX, maxY = rect.maxX + BRIDGE_GAP, rect.maxY + BRIDGE_GAP
        if not scanArea(job, minX, minY, maxX, maxY) then
            return false
        end
        list = collectNeighbors(job, rect, minX, minY, maxX, maxY)
        if isBakedArea(minX, minY, maxX, maxY) then
            graph.neighbors[rectIndex] = list
        end
    end

    for i = 1, #list, 7 do
        local index = list[i]
        local viaX, viaY = list[i + 2], list[i + 3]
        local travel = distance(entryX, entryY, viaX, viaY) + list[i + 1]
        if preferredRects[index] then
            travel = travel * PREFERRED_DISCOUNT
        end
        relax(job, index + NODE_OFFSET, score + travel + list[i + 6], node,
            list[i + 4], list[i + 5], viaX, viaY)
    end
    job.work = job.work + #list / 7

    if not job.goalRects[rectIndex] then
        return true
    end

    local exitX, exitY = closestPointOn(rect, job.targetX, job.targetY)
    local finalGap = distance(exitX, exitY, job.targetX, job.targetY)
    local goalCost = score + distance(entryX, entryY, exitX, exitY)
        + finalGap
        + offroadPremium(finalGap, exitX, exitY, job.targetX, job.targetY)

    local known = job.gScore[GOAL_NODE]
    if known == nil or goalCost < known then
        job.gScore[GOAL_NODE] = goalCost
        job.parent[GOAL_NODE] = node
        job.entryX[GOAL_NODE] = exitX
        job.entryY[GOAL_NODE] = exitY
        heapPush(job, GOAL_NODE, goalCost)
    end

    return true
end

local function perpendicularDistance(pointX, pointY, startX, startY, endX, endY)
    local dx, dy = endX - startX, endY - startY
    local lengthSq = dx * dx + dy * dy
    if lengthSq == 0 then
        return distance(pointX, pointY, startX, startY)
    end

    local t = ((pointX - startX) * dx + (pointY - startY) * dy) / lengthSq
    t = math.max(0, math.min(1, t))
    return distance(pointX, pointY, startX + t * dx, startY + t * dy)
end

local function douglasPeucker(points, first, last, keep)
    local worst, worstIndex = 0, nil
    for i = first + 1, last - 1 do
        local offset = perpendicularDistance(
            points[i].x, points[i].y,
            points[first].x, points[first].y,
            points[last].x, points[last].y)
        if offset > worst then
            worst, worstIndex = offset, i
        end
    end

    if worst > SIMPLIFY_TOLERANCE then
        douglasPeucker(points, first, worstIndex, keep)
        douglasPeucker(points, worstIndex, last, keep)
        return
    end

    keep[last] = true
end

local function simplify(points)
    if #points < 3 then
        return points
    end

    local keep = { [1] = true }
    douglasPeucker(points, 1, #points, keep)

    local result = {}
    for i = 1, #points do
        if keep[i] then
            result[#result + 1] = points[i]
        end
    end
    return result
end

local function measure(route)
    local points = route.points
    local lengths, total = { 0 }, 0
    for i = 2, #points do
        total = total + distance(points[i - 1].x, points[i - 1].y, points[i].x, points[i].y)
        lengths[i] = total
    end
    route.lengths = lengths
    route.total = total
end

local function buildPolyline(job)
    local chain = {}
    local node = GOAL_NODE
    while node do
        chain[#chain + 1] = node
        node = job.parent[node]
    end

    local raw = { { x = job.startX, y = job.startY } }
    for i = #chain - 1, 1, -1 do
        local current = chain[i]
        if current > NODE_OFFSET and not preferredRects[current - NODE_OFFSET] then
            if preferredCount >= PREFERRED_LIMIT then
                preferredRects = {}
                preferredCount = 0
            end
            preferredRects[current - NODE_OFFSET] = true
            preferredCount = preferredCount + 1
        end

        local viaX, viaY = job.viaX[current], job.viaY[current]
        if viaX then
            raw[#raw + 1] = { x = viaX, y = viaY }
        end
        raw[#raw + 1] = { x = job.entryX[current], y = job.entryY[current] }
    end

    local last = raw[#raw]
    if last.x ~= job.targetX or last.y ~= job.targetY then
        raw[#raw + 1] = { x = job.targetX, y = job.targetY }
    end

    job.points = simplify(raw)
    measure(job)

    job.status = "ready"
    job.gScore = nil
    job.parent = nil
    job.entryX = nil
    job.entryY = nil
    job.viaX = nil
    job.viaY = nil
    job.closed = nil
    job.heapNodes = nil
    job.heapPriorities = nil
end

local function searchStep(job)
    job.regionsThisTick = 0
    job.work = 0

    if not loadBakedGraph() then
        return
    end

    while job.work < WORK_PER_TICK do
        if job.heapSize == 0 then
            job.status = "failed"
            return
        end

        local node = heapPop(job)
        job.work = job.work + 1
        if not job.closed[node] then
            if node == GOAL_NODE then
                job.closed[node] = true
                buildPolyline(job)
                return
            end

            local complete
            if node == START_NODE then
                complete = expandStart(job)
            else
                complete = expandRect(job, node)
            end

            if not complete then
                heapPush(job, node,
                    job.gScore[node] + heuristic(job, job.entryX[node], job.entryY[node]))
                return
            end

            job.closed[node] = true
            job.expansions = job.expansions + 1

            if job.expansions > MAX_EXPANSIONS then
                job.status = "failed"
                return
            end

            if job.regionsThisTick >= REGIONS_PER_TICK then
                return
            end
        end
    end
end

local function onTick()
    local processed = 0
    local index = 1
    while index <= #queue and processed < JOBS_PER_TICK do
        local job = queue[index]
        local startedMs = getTimeInMillis()
        searchStep(job)
        local spentMs = getTimeInMillis() - startedMs
        job.ticks = job.ticks + 1
        job.spentMs = job.spentMs + spentMs
        job.worstTickMs = math.max(job.worstTickMs, spentMs)
        processed = processed + 1

        if job.status ~= "searching" then
            print(string.format(
                "[Bartering][Route] %s %.0f,%.0f -> %.0f,%.0f | ticks=%d spentMs=%d worstTickMs=%d expansions=%d",
                job.status, job.startX, job.startY, job.targetX, job.targetY,
                job.ticks, job.spentMs, job.worstTickMs, job.expansions))
            table.remove(queue, index)
        else
            index = index + 1
        end
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

    local reversed = {
        status = "ready",
        points = points,
    }
    measure(reversed)
    return reversed
end

local function pointAlong(route, along)
    local points, lengths = route.points, route.lengths
    local target = math.max(0, math.min(route.total, along))

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

local function stopShort(route, standoff)
    local x, y, segment = pointAlong(route, route.total - standoff)
    local points = {}
    for i = 1, segment - 1 do
        points[i] = route.points[i]
    end
    points[#points + 1] = { x = x, y = y }

    local trimmed = {
        status = "ready",
        points = points,
        standoff = standoff,
    }
    measure(trimmed)
    return trimmed
end

local function findOrStart(trip)
    local startX, startY = trip.startX, trip.startY
    local targetX, targetY = trip.targetX, trip.targetY

    local key = cacheKey(startX, startY, targetX, targetY)
    local existing = cache[key]
    if existing then
        return existing
    end

    local opposite = cache[cacheKey(targetX, targetY, startX, startY)]
    if opposite and opposite.status == "ready" then
        local route = reverseRoute(opposite, startX, startY, targetX, targetY)
        remember(key, route)
        return route
    end

    local job = {
        status = "searching",
        startX = startX,
        startY = startY,
        targetX = targetX,
        targetY = targetY,
        minX = math.max(0, math.min(startX, targetX) - BBOX_MARGIN),
        minY = math.max(0, math.min(startY, targetY) - BBOX_MARGIN),
        maxX = math.max(startX, targetX) + BBOX_MARGIN,
        maxY = math.max(startY, targetY) + BBOX_MARGIN,
        gScore = {},
        parent = {},
        entryX = {},
        entryY = {},
        viaX = {},
        viaY = {},
        closed = {},
        heapNodes = {},
        heapPriorities = {},
        heapSize = 0,
        expansions = 0,
        work = 0,
        ticks = 0,
        spentMs = 0,
        worstTickMs = 0,
        regionsThisTick = 0,
        generation = 0,
        seenMark = {},
        foundList = {},
    }

    job.gScore[START_NODE] = 0
    job.entryX[START_NODE] = startX
    job.entryY[START_NODE] = startY
    heapPush(job, START_NODE, heuristic(job, startX, startY))

    remember(key, job)
    queue[#queue + 1] = job
    return job
end

function RoadRoute.ensure(trip)
    local route = trip.route or findOrStart(trip)
    if trip.standoff and not route.standoff and route.status == "ready" then
        route = stopShort(route, trip.standoff)
    end
    trip.route = route
    return route
end

function RoadRoute.positionAt(route, progress)
    return pointAlong(route, math.max(0, math.min(1, progress)) * route.total)
end

function RoadRoute.positionFor(trip, progress)
    local route = RoadRoute.ensure(trip)
    if route.status == "ready" then
        return RoadRoute.positionAt(route, progress)
    end

    local startX, startY = trip.startX, trip.startY
    local targetX, targetY = trip.targetX, trip.targetY
    local legX = math.abs(targetX - startX)
    local legY = math.abs(targetY - startY)
    local along = math.max(0, math.min(1, progress)) * math.max(0, legX + legY - (trip.standoff or 0))

    if along <= legX or legX == 0 then
        local fraction = legX > 0 and along / legX or 0
        return startX + (targetX - startX) * fraction, startY
    end

    local fraction = legY > 0 and (along - legX) / legY or 0
    return targetX, startY + (targetY - startY) * fraction
end

events.OnTick.Add(onTick)
