local getGameTime = _G["getGameTime"]
local getTimeInMillis = _G["getTimeInMillis"]
local events = _G["Events"]

local BarteringTiming = {}

BarteringTiming.CALLED_IN_LIFETIME_HOURS = 5 / 60
BarteringTiming.CALLED_IN_LIFETIME_MS = BarteringTiming.CALLED_IN_LIFETIME_HOURS * 3600 * 1000
BarteringTiming.MAX_ACCUMULATE_STEP_MS = 1000

local clockMs = getTimeInMillis()
local lastWorldHours

function BarteringTiming.now()
    return clockMs
end

local function seedClock()
    lastWorldHours = getGameTime():getWorldAgeHours()
end

local function advanceClock()
    local worldHours = getGameTime():getWorldAgeHours()
    clockMs = clockMs + (worldHours - lastWorldHours) * BarteringTiming.realSecondsPerGameHour() * 1000
    lastWorldHours = worldHours
end

events.OnGameTimeLoaded.Add(seedClock)
events.OnTick.Add(advanceClock)

function BarteringTiming.minutesSince(previousMinutesStamp)
    local diff = getGameTime():getMinutesStamp() - previousMinutesStamp
    if diff < 0 then
        diff = diff + 24 * 60
    end
    return diff
end

function BarteringTiming.remainingHours(targetHours)
    if targetHours == nil then
        return 0
    end
    return math.max(0, targetHours - getGameTime():getWorldAgeHours())
end

function BarteringTiming.realSecondsPerGameHour()
    return getGameTime():getMinutesPerDay() * 60 / 24
end

function BarteringTiming.gameHoursToRealSeconds(hours)
    return (hours or 0) * BarteringTiming.realSecondsPerGameHour()
end

function BarteringTiming.remainingRealSeconds(targetHours)
    return BarteringTiming.gameHoursToRealSeconds(BarteringTiming.remainingHours(targetHours))
end

function BarteringTiming.hoursUntilTimeOfDay(targetHour)
    local remaining = targetHour - getGameTime():getTimeOfDay()
    if remaining <= 0 then
        remaining = remaining + 24
    end
    return remaining
end

function BarteringTiming.travelSeconds(fromX, fromY, toX, toY, travelSecondsPerTile)
    local dx = fromX - toX
    local dy = fromY - toY
    return math.sqrt(dx * dx + dy * dy) * travelSecondsPerTile
        * Bartering.getSandboxNumber("TravelTimeMultiplier", 1)
end

function BarteringTiming.travelSecondsTo(barterer, toX, toY)
    return BarteringTiming.travelSeconds(barterer.x, barterer.y, toX, toY, barterer.travelSecondsPerTile)
end

function BarteringTiming.msFromSeconds(seconds)
    return clockMs + math.floor(seconds * 1000)
end

function BarteringTiming.elapsedSince(atMs)
    return clockMs - (atMs or 0)
end

function BarteringTiming.hasElapsed(atMs, durationMs)
    return BarteringTiming.elapsedSince(atMs) >= durationMs
end

function BarteringTiming.progress(startedAtMs, arrivalAtMs)
    local span = arrivalAtMs - startedAtMs
    if span <= 0 then
        return 1
    end
    return math.max(0, math.min(1, (clockMs - startedAtMs) / span))
end

function BarteringTiming.accumulate(previousMs, nowMs)
    return math.min(nowMs - previousMs, BarteringTiming.MAX_ACCUMULATE_STEP_MS)
end

function BarteringTiming.createCalledInDepartureHours()
    return getGameTime():getWorldAgeHours()
        + BarteringTiming.CALLED_IN_LIFETIME_MS / 1000 / BarteringTiming.realSecondsPerGameHour()
end

function BarteringTiming.remainingRealSecondsUntilMs(targetMs)
    if not targetMs or targetMs <= 0 then
        return nil
    end
    local remaining = (targetMs - clockMs) / 1000
    if remaining <= 0 then
        return nil
    end
    return remaining
end

function BarteringTiming.formatDuration(seconds)
    local remainingSeconds = math.max(0, math.floor(math.ceil(seconds)))
    local hours = math.floor(remainingSeconds / 3600)
    local minutes = math.floor((remainingSeconds % 3600) / 60)
    local wholeSeconds = math.floor(remainingSeconds % 60)

    if hours > 0 then
        return string.format("%02d:%02d:%02d", hours, minutes, wholeSeconds)
    end
    if minutes > 0 then
        return string.format("%02d:%02d", minutes, wholeSeconds)
    end
    return string.format("%02d", wholeSeconds)
end

function BarteringTiming.formatDurationHours(hours)
    return BarteringTiming.formatDuration(hours * 3600)
end

function BarteringTiming.formatCountdown(seconds)
    local totalSeconds = math.max(0, math.floor(seconds or 0))
    if totalSeconds < 60 then
        return string.format("%ds", totalSeconds)
    end
    local totalMinutes = math.floor(totalSeconds / 60)
    local secs = totalSeconds % 60
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60
    if hours > 0 and minutes > 0 and secs > 0 then
        return string.format("%dh %dm %ds", hours, minutes, secs)
    end
    if hours > 0 and minutes > 0 then
        return string.format("%dh %dm", hours, minutes)
    end
    if hours > 0 and secs > 0 then
        return string.format("%dh %ds", hours, secs)
    end
    if hours > 0 then
        return string.format("%dh", hours)
    end
    if minutes > 0 and secs > 0 then
        return string.format("%dm %ds", minutes, secs)
    end
    if minutes > 0 then
        return string.format("%dm", minutes)
    end
    return string.format("%ds", secs)
end

function BarteringTiming.formatGameHours(hours)
    local days = math.floor(hours / 24)
    local remainingHours = math.floor(hours % 24)
    if days > 0 then
        return string.format("%d day(s) %d hour(s)", days, remainingHours)
    end
    return string.format("%d hour(s)", math.max(1, remainingHours))
end

function BarteringTiming.formatAge(seconds)
    local totalSeconds = math.max(0, math.floor(seconds or 0))
    if totalSeconds < 60 then
        return "just now"
    end
    return BarteringTiming.formatCountdown(totalSeconds) .. " ago"
end

function BarteringTiming.formatArrivalEstimate(seconds)
    local remainingSeconds = math.max(0, math.floor(math.ceil(seconds)))
    if remainingSeconds < 60 then
        return string.format("%d", remainingSeconds) .. " seconds"
    end
    return BarteringTiming.formatDuration(remainingSeconds)
end

function BarteringTiming.formatArrivalEstimateHumanized(seconds)
    local totalMinutes = math.max(5, math.floor(math.max(0, seconds) / 60 / 5 + 0.5) * 5)
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60
    if hours > 0 and minutes > 0 then
        return string.format("%d %s and %d minutes", hours, hours == 1 and "hour" or "hours", minutes)
    end
    if hours > 0 then
        return string.format("%d %s", hours, hours == 1 and "hour" or "hours")
    end
    return string.format("%d minutes", minutes)
end

return BarteringTiming
