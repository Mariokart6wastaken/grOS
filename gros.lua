-- osui.lua
local tasks = {}
local current = nil
local term = term
local oldTerm = term.current()

-- Start a program as a coroutine
local function startProgram(name, ...)
    local env = setmetatable({}, { __index = _G })
    local fn, err = loadfile(shell.resolveProgram(name), env)
    if not fn then return nil, err end
    local co = coroutine.create(function(...) fn(...) end)
    table.insert(tasks, {name=name, co=co, bg=false})
    return true
end

-- Switch foreground task
local function setForeground(idx)
    if tasks[idx] then
        current = idx
    end
end

-- Simple scheduler
local function scheduler()
    while true do
        term.redirect(oldTerm) -- always reset term before redraw
        -- Draw status bar
        term.setCursorPos(1,1)
        term.setBackgroundColor(colors.blue)
        term.clearLine()
        term.setTextColor(colors.white)
        local labels = {}
        for i, t in ipairs(tasks) do
            local marker = (i==current) and "*" or " "
            table.insert(labels, marker..t.name)
        end
        term.write(table.concat(labels, " "))

        -- Resume foreground task
        if current and tasks[current] then
            local ok, event, p1,p2,p3,p4,p5 = coroutine.resume(tasks[current].co, os.pullEventRaw())
            if not ok then
                print("Task crashed: "..tostring(event))
                table.remove(tasks, current)
                current = #tasks > 0 and 1 or nil
            elseif coroutine.status(tasks[current].co) == "dead" then
                table.remove(tasks, current)
                current = #tasks > 0 and 1 or nil
            end
        else
            os.pullEvent("key") -- idle
        end
    end
end

-- Boot
local ok, err = startProgram("shell") -- start CraftOS shell
if ok then
    current = 1
    scheduler()
else
    print("Failed to start shell: "..err)
end
