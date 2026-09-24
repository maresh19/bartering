local BarteringTiming = require "BarteringTiming"

BarteringMuzzleFlash = BarteringMuzzleFlash or {}
BarteringMuzzleFlash.list = {}

BarteringMuzzleFlash.FORWARD = 0.60
BarteringMuzzleFlash.HEIGHT = 0.46
BarteringMuzzleFlash.SIDE = 0.14
BarteringMuzzleFlash.SPEED = 120
BarteringMuzzleFlash.LENGTH = 4
BarteringMuzzleFlash.RANGE = 25

function BarteringMuzzleFlash.Add(zombie)
    local dir = zombie:getDirectionAngle() + ZombRandFloat(0, 0.3) - 0.3
    local theta = dir * math.pi / 180
    local cosT, sinT = math.cos(theta), math.sin(theta)
    table.insert(BarteringMuzzleFlash.list, {
        x = zombie:getX() + cosT * BarteringMuzzleFlash.FORWARD - sinT * BarteringMuzzleFlash.SIDE,
        y = zombie:getY() + sinT * BarteringMuzzleFlash.FORWARD + cosT * BarteringMuzzleFlash.SIDE,
        z = zombie:getZ() + BarteringMuzzleFlash.HEIGHT,
        dirX = cosT,
        dirY = sinT,
        dropZ = ZombRandFloat(-0.05, 0.05) / BarteringMuzzleFlash.RANGE,
        startMs = BarteringTiming.now(),
    })
    if #BarteringMuzzleFlash.list > 8 then
        table.remove(BarteringMuzzleFlash.list, 1)
    end
end
