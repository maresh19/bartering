require "ISUI/Maps/ISWorldMap"
require "Bartering"
require "Bartering.media.lua.client.BarteringRoadRoute"

local ISWorldMap = _G["ISWorldMap"]
local UIFont = _G["UIFont"]
local getSpecificPlayer = _G["getSpecificPlayer"]
local getTimeInMillis = _G["getTimeInMillis"]
local renderWorldMap = ISWorldMap.render

local QUEST_COLOUR = { 1.00, 0.85, 0.25 }
local EN_ROUTE_COLOUR = { 0.30, 0.80, 1.00 }
local STALE_TRACKED_MS = 3000

local function tripProgress(trip, now)
    local total = trip.arrivalAtMs - trip.startedAtMs
    if total <= 0 then
        return 1
    end
    return math.max(0, math.min(1, (now - trip.startedAtMs) / total))
end

local function gridRoutePosition(trip, t)
    local sx, sy = trip.startX, trip.startY
    local tx, ty = trip.targetX, trip.targetY
    local leg1 = math.abs(tx - sx)
    local leg2 = math.abs(ty - sy)
    local totalLen = leg1 + leg2
    local dist = t * totalLen

    if dist <= leg1 or leg1 == 0 then
        local f = leg1 > 0 and dist / leg1 or 0
        return sx + (tx - sx) * f, sy
    end
    local f = leg2 > 0 and (dist - leg1) / leg2 or 0
    return tx, sy + (ty - sy) * f
end

local TRAVELLED_ALPHA = 0.15
local REMAINING_ALPHA = 0.5

local function drawRouteLine(worldMap, route, segment, markerWorldX, markerWorldY, colour)
    local mapAPI = worldMap.mapAPI
    local points = route.points
    local previousX = math.floor(mapAPI:worldToUIX(points[1].x, points[1].y))
    local previousY = math.floor(mapAPI:worldToUIY(points[1].x, points[1].y))

    for i = 2, #points do
        local point = points[i]
        local x = math.floor(mapAPI:worldToUIX(point.x, point.y))
        local y = math.floor(mapAPI:worldToUIY(point.x, point.y))

        if i < segment then
            worldMap:drawLine2(previousX, previousY, x, y, TRAVELLED_ALPHA, colour[1], colour[2], colour[3])
        elseif i == segment then
            local markerX = math.floor(mapAPI:worldToUIX(markerWorldX, markerWorldY))
            local markerY = math.floor(mapAPI:worldToUIY(markerWorldX, markerWorldY))
            worldMap:drawLine2(previousX, previousY, markerX, markerY, TRAVELLED_ALPHA, colour[1], colour[2], colour[3])
            worldMap:drawLine2(markerX, markerY, x, y, REMAINING_ALPHA, colour[1], colour[2], colour[3])
        else
            worldMap:drawLine2(previousX, previousY, x, y, REMAINING_ALPHA, colour[1], colour[2], colour[3])
        end

        previousX, previousY = x, y
    end
end

local STATE_COLOURS = {
    Approach = { 0.30, 0.80, 1.00 },
    Waiting = { 0.40, 1.00, 0.40 },
    Return = { 1.00, 0.80, 0.20 },
    Retreat = { 1.00, 0.30, 0.20 },
    Dormant = { 0.45, 0.45, 0.55 },
    DefendPistol = { 1.00, 0.55, 0.10 },
    DefendRifle = { 1.00, 0.55, 0.10 },
    DefendKnife = { 1.00, 0.20, 0.55 },
}

local CLIMB_COLOUR = { 1.00, 0.40, 1.00 }
local DEFAULT_COLOUR = { 0.90, 0.90, 0.90 }

local function trackedColour(tracked)
    if tracked.climbing then
        return CLIMB_COLOUR
    end
    return STATE_COLOURS[tracked.state] or DEFAULT_COLOUR
end

local function renderQuestMarkers(worldMap)
    local player = getSpecificPlayer(0)
    if not player then
        return
    end

    for _, quest in pairs(Bartering.Quests.getPlayerState(player).active) do
        local x1 = math.floor(worldMap.mapAPI:worldToUIX(quest.bx1, quest.by1))
        local y1 = math.floor(worldMap.mapAPI:worldToUIY(quest.bx1, quest.by1))
        local x2 = math.floor(worldMap.mapAPI:worldToUIX(quest.bx2, quest.by2))
        local y2 = math.floor(worldMap.mapAPI:worldToUIY(quest.bx2, quest.by2))
        local cx = math.floor(worldMap.mapAPI:worldToUIX(quest.x, quest.y))
        local cy = math.floor(worldMap.mapAPI:worldToUIY(quest.x, quest.y))

        worldMap:drawRectBorder(x1 - 1, y1 - 1, math.max(3, x2 - x1) + 2, math.max(3, y2 - y1) + 2, 1, 0.05, 0.05, 0.05)
        worldMap:drawRectBorder(x1, y1, math.max(3, x2 - x1), math.max(3, y2 - y1), 1, QUEST_COLOUR[1], QUEST_COLOUR[2], QUEST_COLOUR[3])
        worldMap:drawRectBorder(cx - 4, cy - 4, 9, 9, 1, 0.05, 0.05, 0.05)
        worldMap:drawRect(cx - 3, cy - 3, 7, 7, 1, QUEST_COLOUR[1], QUEST_COLOUR[2], QUEST_COLOUR[3])
        worldMap:drawText(
            string.format("%s (%s)", tostring(quest.itemName), Bartering.Quests.getPlaceReference(quest)),
            cx + 8, cy - 8, QUEST_COLOUR[1], QUEST_COLOUR[2], QUEST_COLOUR[3], 1, UIFont.Small)
    end
end

function ISWorldMap:render(...)
    renderWorldMap(self, ...)
    local now = getTimeInMillis()

    renderQuestMarkers(self)

    for _, barterer in pairs(Bartering.Barterers) do
        local x = math.floor(self.mapAPI:worldToUIX(barterer.x, barterer.y))
        local y = math.floor(self.mapAPI:worldToUIY(barterer.x, barterer.y))
        self:drawRect(x - 3, y - 3, 7, 7, 1, 0.95, 0.72, 0.12)
        self:drawRectBorder(x - 4, y - 4, 9, 9, 1, 0.1, 0.1, 0.1)
        self:drawText("Barterer", x + 7, y - 7, 0.95, 0.72, 0.12, 1, UIFont.Small)
    end

    for id, trip in pairs(Bartering.Trips) do
        if now >= trip.arrivalAtMs then
            Bartering.Trips[id] = nil
        else
            local tracked = Bartering.TrackedBarterers[id]
            local trackedFresh = tracked and tracked.lastSeenAtMs and now - tracked.lastSeenAtMs < STALE_TRACKED_MS
            if not trackedFresh then
                local colour = trip.kind == "return" and STATE_COLOURS.Return or EN_ROUTE_COLOUR
                local label = trip.kind == "return" and "Returning home" or "On the way"
                local progress = tripProgress(trip, now)
                local route = Bartering.RoadRoute.ensure(trip)
                local ix, iy
                if route.status == "ready" then
                    local segment
                    ix, iy, segment = Bartering.RoadRoute.positionAt(route, progress)
                    drawRouteLine(self, route, segment, ix, iy, colour)
                else
                    ix, iy = gridRoutePosition(trip, progress)
                end
                local x = math.floor(self.mapAPI:worldToUIX(ix, iy))
                local y = math.floor(self.mapAPI:worldToUIY(ix, iy))
                self:drawRectBorder(x - 5, y - 5, 11, 11, 1, 0.05, 0.05, 0.05)
                self:drawRect(x - 4, y - 4, 9, 9, 1, colour[1], colour[2], colour[3])
                self:drawText(label, x + 8, y - 7, colour[1], colour[2], colour[3], 1, UIFont.Small)
            end
        end
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
