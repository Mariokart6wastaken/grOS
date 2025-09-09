--[[
A minimal graphical OS for ComputerCraft
- Provides multitasking (background/foreground tasks)
- Remains compatible with CraftOS programs
- Uses a simple task scheduler
]]

-- Table to hold running processes
local processes = {}
local currentPID = 0

-- Create a new process
local function spawn(path, args, isForeground)
    local pid = #processes + 1
    local co = coroutine.create(function()
        shell.run(path, table.unpack(args or {}))
    end)
    processes[pid] = {
        pid = pid,
        co = co,
        foreground = isForeground or false,
        alive = true,
    }
    return pid
end

-- Kill a process
local function kill(pid)
    if processes[pid] then
        processes[pid].alive = false
        processes[pid] = nil
    end
end

-- Switch foreground process
local function fg(pid)
    for _, p in pairs(processes) do
        p.foreground = false
    end
    if processes[pid] then
        processes[pid].foreground = true
    end
end

-- Scheduler loop
local function scheduler()
    while true do
        local event = {os.pullEventRaw()}
        for pid, p in pairs(processes) do
            if p.alive and coroutine.status(p.co) ~= "dead" then
                local ok, err = coroutine.resume(p.co, table.unpack(event))
                if not ok then
                    print("Process " .. pid .. " crashed: " .. tostring(err))
                    processes[pid] = nil
                end
            end
        end
    end
end

-- Simple command line interface
local function shellUI()
    term.clear()
    term.setCursorPos(1,1)
    print("Graphical OS - Multitasking Shell")
    while true do
        io.write("$ ")
        local input = read()
        local args = {}
        for word in input:gmatch("%S+") do table.insert(args, word) end
        if #args > 0 then
            local cmd = args[1]
            if cmd == "bg" then
                spawn(args[2], {select(3, table.unpack(args))}, false)
            elseif cmd == "fg" then
                local pid = tonumber(args[2])
                if pid then fg(pid) end
            elseif cmd == "kill" then
                local pid = tonumber(args[2])
                if pid then kill(pid) end
            else
                spawn(cmd, {select(2, table.unpack(args))}, true)
            end
        end
    end
end

-- Boot system
spawn("shellUI", {}, true)
scheduler()
