require "ISUI/Maps/ISWorldMap"
require "Bartering"
require "Map/BarteringRoadRoute"

local ISWorldMap = _G["ISWorldMap"]
local UIFont = _G["UIFont"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local renderWorldMap = ISWorldMap.render
local BarteringTiming = require "BarteringTiming"

local QUEST_COLOUR = { 1.00, 0.85, 0.25 }
local QUEST_MIN_BOX = 5
local QUEST_LABEL_OFFSET = 12
local EN_ROUTE_COLOUR = { 0.30, 0.80, 1.00 }
local STALE_TRACKED_MS = 3000

function Bartering.getBartererMapPosition(bartererId)
    local now = BarteringTiming.now()

    local tracked = Bartering.TrackedBarterers[bartererId]
    if tracked and (not tracked.lastSeenAtMs or now - tracked.lastSeenAtMs < STALE_TRACKED_MS) then
        return tracked.x, tracked.y
    end

    local trip = Bartering.Trips[bartererId]
    if trip and now < trip.arrivalAtMs then
        if trip.waiting then
            return trip.targetX, trip.targetY
        end
        local x, y = Bartering.RoadRoute.positionFor(trip,
            BarteringTiming.progress(trip.startedAtMs, trip.arrivalAtMs))
        return x, y
    end

    local barterer = Bartering.Barterers[bartererId]
    return barterer.x, barterer.y
end

local TRAVELLED_ALPHA = 0.30
local REMAINING_ALPHA = 0.75
local LINE_THICKNESS = 7

local function drawThickLine(worldMap, x1, y1, x2, y2, alpha, colour)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then
        return
    end

    local half = LINE_THICKNESS / 2
    local offsetX = -dy / length * half
    local offsetY = dx / length * half
    worldMap:drawTextureAllPoint(nil,
        x1 + offsetX, y1 + offsetY,
        x2 + offsetX, y2 + offsetY,
        x2 - offsetX, y2 - offsetY,
        x1 - offsetX, y1 - offsetY,
        colour[1], colour[2], colour[3], alpha)
end

local routeEntries = {}
local drawnIndex = {}
local drawnGeneration = 0

local function claimSegment(x1, y1, x2, y2)
    local ax = math.floor(x1 + 0.5)
    local ay = math.floor(y1 + 0.5)
    local bx = math.floor(x2 + 0.5)
    local by = math.floor(y2 + 0.5)
    if bx < ax or (bx == ax and by < ay) then
        ax, ay, bx, by = bx, by, ax, ay
    end

    local outer = ax * 16384 + ay
    local inner = drawnIndex[outer]
    if not inner then
        inner = {}
        drawnIndex[outer] = inner
    end

    local key = bx * 16384 + by
    if inner[key] == drawnGeneration then
        return false
    end
    inner[key] = drawnGeneration
    return true
end

local lastScale, lastCentreX, lastCentreY

local function viewChanged(mapAPI)
    local scale = mapAPI:getWorldScale()
    local centreX = mapAPI:getCenterWorldX()
    local centreY = mapAPI:getCenterWorldY()
    if scale == lastScale and centreX == lastCentreX and centreY == lastCentreY then
        return false
    end
    lastScale, lastCentreX, lastCentreY = scale, centreX, centreY
    return true
end

local function projectRoute(mapAPI, route, screenX, screenY)
    local points = route.points
    local count = #points
    for i = 1, count do
        local point = points[i]
        screenX[i] = mapAPI:worldToUIX(point.x, point.y)
        screenY[i] = mapAPI:worldToUIY(point.x, point.y)
    end
    return count
end

local function drawRoutePass(worldMap, entry, remainingPass)
    local points = entry.route.points
    local screenX, screenY = entry.screenX, entry.screenY
    local segment = entry.segment
    local colour = entry.colour

    for i = 2, entry.count do
        if i == segment then
            if remainingPass then
                if claimSegment(entry.markerX, entry.markerY, points[i].x, points[i].y) then
                    drawThickLine(worldMap, entry.markerScreenX, entry.markerScreenY,
                        screenX[i], screenY[i], REMAINING_ALPHA, colour)
                end
            elseif claimSegment(points[i - 1].x, points[i - 1].y, entry.markerX, entry.markerY) then
                drawThickLine(worldMap, screenX[i - 1], screenY[i - 1],
                    entry.markerScreenX, entry.markerScreenY, TRAVELLED_ALPHA, colour)
            end
        elseif (i > segment) == remainingPass then
            if claimSegment(points[i - 1].x, points[i - 1].y, points[i].x, points[i].y) then
                drawThickLine(worldMap, screenX[i - 1], screenY[i - 1],
                    screenX[i], screenY[i],
                    remainingPass and REMAINING_ALPHA or TRAVELLED_ALPHA, colour)
            end
        end
    end
end

local STATE_COLOURS = {
    Approach = { 0.30, 0.80, 1.00 },
    Waiting = { 0.40, 1.00, 0.40 },
    Return = { 1.00, 0.80, 0.20 },
    Retreat = { 1.00, 0.30, 0.20 },
    DefendPistol = { 1.00, 0.55, 0.10 },
    DefendKnife = { 1.00, 0.20, 0.55 },
    BlockedByDoor = { 1.00, 0.45, 0.35 },
    BlockedRoute = { 1.00, 0.45, 0.35 },
}

local CLIMB_COLOUR = { 1.00, 0.40, 1.00 }
local DEFAULT_COLOUR = { 0.90, 0.90, 0.90 }

local function trackedColour(tracked)
    if tracked.climbing then
        return CLIMB_COLOUR
    end
    return STATE_COLOURS[tracked.state] or DEFAULT_COLOUR
end

local function projectWorldBounds(mapAPI, x1, y1, x2, y2)
    local ax = mapAPI:worldToUIX(x1, y1)
    local ay = mapAPI:worldToUIY(x1, y1)
    local bx = mapAPI:worldToUIX(x2, y1)
    local by = mapAPI:worldToUIY(x2, y1)
    local cx = mapAPI:worldToUIX(x2, y2)
    local cy = mapAPI:worldToUIY(x2, y2)
    local dx = mapAPI:worldToUIX(x1, y2)
    local dy = mapAPI:worldToUIY(x1, y2)

    local left = math.floor(math.min(ax, bx, cx, dx))
    local top = math.floor(math.min(ay, by, cy, dy))
    local right = math.ceil(math.max(ax, bx, cx, dx))
    local bottom = math.ceil(math.max(ay, by, cy, dy))

    return left, top,
        math.max(QUEST_MIN_BOX, right - left),
        math.max(QUEST_MIN_BOX, bottom - top)
end

local function renderQuestMarkers(worldMap)
    local player = getSpecificPlayer(0)
    if not player then
        return
    end

    local mapAPI = worldMap.mapAPI
    for bartererId in pairs(Bartering.Quests.getPlayerState(player).active) do
        local quest = Bartering.Quests.getActive(player, bartererId)
        if quest then
            local left, top, width, height = projectWorldBounds(mapAPI,
                quest.bx1, quest.by1, quest.bx2, quest.by2)

            local labelY = top - QUEST_LABEL_OFFSET
            if labelY < 0 then
                labelY = top + 2
            end

            worldMap:drawRectBorder(left - 1, top - 1, width + 2, height + 2, 1, 0.05, 0.05, 0.05)
            worldMap:drawRectBorder(left, top, width, height, 1, QUEST_COLOUR[1], QUEST_COLOUR[2], QUEST_COLOUR[3])
            worldMap:drawText(
                string.format("%s (%s)", tostring(quest.itemName), Bartering.Quests.getPlaceLabel(quest, player)),
                left, labelY, QUEST_COLOUR[1], QUEST_COLOUR[2], QUEST_COLOUR[3], 1, UIFont.Small)
        end
    end
end

function ISWorldMap:render(...)
    renderWorldMap(self, ...)
    local now = BarteringTiming.now()

    renderQuestMarkers(self)

    for _, barterer in pairs(Bartering.Barterers) do
        if not Bartering.isBartererAwayFromHome(barterer.id) then
            local x = math.floor(self.mapAPI:worldToUIX(barterer.x, barterer.y))
            local y = math.floor(self.mapAPI:worldToUIY(barterer.x, barterer.y))
            self:drawRect(x - 3, y - 3, 7, 7, 1, 0.95, 0.72, 0.12)
            self:drawRectBorder(x - 4, y - 4, 9, 9, 1, 0.1, 0.1, 0.1)
            self:drawText("Barterer Home", x + 7, y - 7, 0.95, 0.72, 0.12, 1, UIFont.Small)
        end
    end

    local entries = routeEntries
    local entryCount = 0
    local pending = {}
    drawnGeneration = drawnGeneration + 1
    local reproject = viewChanged(self.mapAPI)

    for id, trip in pairs(Bartering.Trips) do
        if now >= trip.arrivalAtMs then
            Bartering.Trips[id] = nil
        else
            local tracked = Bartering.TrackedBarterers[id]
            local trackedFresh = tracked and tracked.lastSeenAtMs and now - tracked.lastSeenAtMs < STALE_TRACKED_MS
            if not trackedFresh then
                local colour, label, ix, iy
                if trip.waiting then
                    colour = STATE_COLOURS.Waiting
                    label = "At the meetup"
                    ix, iy = trip.targetX, trip.targetY
                else
                    colour = trip.kind == "return" and STATE_COLOURS.Return or EN_ROUTE_COLOUR
                    label = trip.kind == "return" and "Returning home" or "On the way"
                    local progress = BarteringTiming.progress(trip.startedAtMs, trip.arrivalAtMs)
                    local route = Bartering.RoadRoute.ensure(trip)
                    if route.status == "ready" then
                        local segment
                        ix, iy, segment = Bartering.RoadRoute.positionAt(route, progress)

                        entryCount = entryCount + 1
                        local entry = entries[entryCount]
                        if not entry then
                            entry = { screenX = {}, screenY = {} }
                            entries[entryCount] = entry
                        end
                        entry.route = route
                        entry.segment = segment
                        entry.colour = colour
                        entry.markerX, entry.markerY = ix, iy
                        if reproject or entry.projectedRoute ~= route then
                            entry.projectedRoute = route
                            entry.count = projectRoute(self.mapAPI, route, entry.screenX, entry.screenY)
                        end
                        entry.markerScreenX = self.mapAPI:worldToUIX(ix, iy)
                        entry.markerScreenY = self.mapAPI:worldToUIY(ix, iy)
                    else
                        ix, iy = Bartering.RoadRoute.positionFor(trip, progress)
                    end
                end
                pending[#pending + 1] = { x = ix, y = iy, colour = colour, label = label }
            end
        end
    end

    for i = 1, entryCount do
        drawRoutePass(self, entries[i], true)
    end
    for i = 1, entryCount do
        drawRoutePass(self, entries[i], false)
    end

    for i = 1, #pending do
        local marker = pending[i]
        local x = math.floor(self.mapAPI:worldToUIX(marker.x, marker.y))
        local y = math.floor(self.mapAPI:worldToUIY(marker.x, marker.y))
        self:drawRectBorder(x - 5, y - 5, 11, 11, 1, 0.05, 0.05, 0.05)
        self:drawRect(x - 4, y - 4, 9, 9, 1, marker.colour[1], marker.colour[2], marker.colour[3])
        self:drawText(marker.label, x + 8, y - 7, marker.colour[1], marker.colour[2], marker.colour[3], 1, UIFont.Small)
    end

    for _, tracked in pairs(Bartering.TrackedBarterers) do
        if not tracked.lastSeenAtMs or now - tracked.lastSeenAtMs < STALE_TRACKED_MS then
            local colour = trackedColour(tracked)
            local x = math.floor(self.mapAPI:worldToUIX(tracked.x, tracked.y))
            local y = math.floor(self.mapAPI:worldToUIY(tracked.x, tracked.y))

            self:drawRectBorder(x - 6, y - 6, 13, 13, 1, 0.05, 0.05, 0.05)
            self:drawRect(x - 5, y - 5, 11, 11, 1, colour[1], colour[2], colour[3])
            self:drawText(
                string.format("%s (%s)", tostring(tracked.name), tostring(tracked.state)),
                x + 9, y - 8, colour[1], colour[2], colour[3], 1, UIFont.Small)
        end
    end
end
