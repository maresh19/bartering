local getGameTime = _G["getGameTime"]
local getTimeInMillis = _G["getTimeInMillis"]

local BarteringTiming = {}

BarteringTiming.CALLED_IN_LIFETIME_HOURS = 5 / 60
BarteringTiming.CALLED_IN_LIFETIME_MS = BarteringTiming.CALLED_IN_LIFETIME_HOURS * 3600 * 1000

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

function BarteringTiming.calculateTravelSeconds(fromX, fromY, toX, toY, travelSecondsPerTile, multiplier)
    local dx = fromX - toX
    local dy = fromY - toY
    return math.sqrt(dx * dx + dy * dy) * travelSecondsPerTile * multiplier
end

function BarteringTiming.createCalledInDeparture()
    return getTimeInMillis() + BarteringTiming.CALLED_IN_LIFETIME_MS
end

function BarteringTiming.remainingRealSecondsUntilMs(targetMs)
    if not targetMs or targetMs <= 0 then
        return nil
    end
    local remaining = (targetMs - getTimeInMillis()) / 1000
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

function BarteringTiming.formatCountdown(seconds)
    local totalSeconds = math.max(0, math.floor(seconds or 0))
    if totalSeconds < 60 then
        return string.format("%ds", totalSeconds)
    end
    local totalMinutes = math.ceil(totalSeconds / 60)
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60
    if hours > 0 and minutes > 0 then
        return string.format("%dh %dm", hours, minutes)
    end
    if hours > 0 then
        return string.format("%dh", hours)
    end
    return string.format("%dm", minutes)
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
