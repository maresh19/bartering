local getAverageFPS = _G["getAverageFPS"]

BarteringActions = BarteringActions or {}

local BarteringAIUtils = require "BarteringAIUtils"
local print = require("BarteringPathTrace").log

local BarteringTasks = {}

local brains = {}

local function brainKey(zombie)
    local bartererId = zombie:getVariableString("BartererId")
    if bartererId and bartererId ~= "" then
        return bartererId
    end
    return tostring(zombie)
end

function BarteringTasks.GetBrain(zombie)
    local key = brainKey(zombie)
    local brain = brains[key]
    if not brain then
        brain = { tasks = {}, moving = false, aim = false }
        brains[key] = brain
    end
    return brain
end

function BarteringTasks.RemoveBrain(zombie)
    brains[brainKey(zombie)] = nil
end

local MAX_QUEUED_TASKS = 9

local function brainForInsert(zombie)
    local brain = BarteringTasks.GetBrain(zombie)
    if #brain.tasks > MAX_QUEUED_TASKS then
        brain.tasks = {}
    end
    return brain
end

function BarteringTasks.AddTask(zombie, task)
    table.insert(brainForInsert(zombie).tasks, task)
end

function BarteringTasks.AddTaskFirst(zombie, task)
    table.insert(brainForInsert(zombie).tasks, 1, task)
end

function BarteringTasks.GetTask(zombie)
    local brain = BarteringTasks.GetBrain(zombie)
    if #brain.tasks > 0 then
        return brain.tasks[1]
    end
    return nil
end

function BarteringTasks.HasTask(zombie)
    return #BarteringTasks.GetBrain(zombie).tasks > 0
end

function BarteringTasks.HasTaskType(zombie, taskType)
    for _, task in pairs(BarteringTasks.GetBrain(zombie).tasks) do
        if task.action == taskType then
            return true
        end
    end
    return false
end

function BarteringTasks.RemoveTask(zombie)
    local brain = BarteringTasks.GetBrain(zombie)
    table.remove(brain.tasks, 1)
end

function BarteringTasks.ClearTasks(zombie)
    local brain = BarteringTasks.GetBrain(zombie)
    brain.tasks = {}
end

function BarteringTasks.SetMoving(zombie, moving)
    BarteringTasks.GetBrain(zombie).moving = moving
end

function BarteringTasks.IsMoving(zombie)
    return BarteringTasks.GetBrain(zombie).moving
end

function BarteringTasks.StopTasks(zombie)
    BarteringTasks.ClearTasks(zombie)
    BarteringTasks.SetMoving(zombie, false)
end

function BarteringTasks.StopMovement(zombie)
    BarteringTasks.StopTasks(zombie)
    BarteringAIUtils.clearPathing(zombie)
    zombie:setMoving(false)
end

function BarteringTasks.ProcessTask(zombie, task)
    if not task.action then return end
    if not task.state then task.state = "NEW" end

    if task.state == "NEW" then
        if not task.time then task.time = 1000 end

        if task.action ~= "Move" then
            BarteringAIUtils.detachPath(zombie)
            if BarteringTasks.IsMoving(zombie) then
                BarteringTasks.SetMoving(zombie, false)
            end
        end

        if task.anim then
            zombie:setBumpType(task.anim)
        end

        print(string.format("[Bartering][Task] %s | START %s | target=%d,%d,%d walk=%s pos=%.2f,%.2f",
            tostring(zombie:getVariableString("BartererId")), tostring(task.action),
            task.x or -1, task.y or -1, task.z or -1, tostring(task.walkType),
            zombie:getX(), zombie:getY()))

        if BarteringActions[task.action].onStart(zombie, task) then
            task.state = "WORKING"
        end

    elseif task.state == "WORKING" then
        task.time = task.time - (1 / ((getAverageFPS() + 0.5) * 0.01666667))

        local done = BarteringActions[task.action].onWorking(zombie, task)
        if done or task.time <= 0 then
            print(string.format("[Bartering][Task] %s | END %s | done=%s timeLeft=%.0f action=%s pos=%.2f,%.2f",
                tostring(zombie:getVariableString("BartererId")), tostring(task.action),
                tostring(done), task.time, tostring(zombie:getActionStateName()),
                zombie:getX(), zombie:getY()))
            task.state = "COMPLETED"
        end

    elseif task.state == "COMPLETED" then
        if BarteringActions[task.action].onComplete(zombie, task) then
            BarteringTasks.RemoveTask(zombie)
        end
    end
end

return BarteringTasks
