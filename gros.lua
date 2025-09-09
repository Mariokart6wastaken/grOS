-- CCOS (ComputerCraft OS) - Starter graphical "OS" with cooperative multitasking
-- Single-file starter. Drop into your ComputerCraft computer and run it.
-- Goals: remain compatible with craftOS programs where possible, provide
-- multitasking (cooperative), a simple graphical desktop (no windows),
-- and a small API for apps to use.

-- == CONFIG ==
local SCREEN_WIDTH, SCREEN_HEIGHT = term.getSize()
local ICONS_PER_ROW = 6
local ICON_SIZE = {w = 12, h = 4}
local TASK_TICK = 0.05 -- scheduler tick for timers (seconds)

-- == Utility functions ==
local function shallow_copy(t)
  local r = {}
  for k,v in pairs(t) do r[k]=v end
  return r
end

-- == Scheduler ==
local Scheduler = {}
Scheduler.__index = Scheduler
function Scheduler.new()
  return setmetatable({tasks = {}, waiting = {}, timers = {}, nextTimerId = 1}, Scheduler)
end

function Scheduler:createTask(func, name)
  local co = coroutine.create(func)
  local task = {co = co, name = name or "unnamed", status = "ready"}
  table.insert(self.tasks, task)
  return task
end

-- helper: resume task with args, catch errors
function Scheduler:resumeTask(task, ...)
  if coroutine.status(task.co) == "dead" then task.status = "dead"; return end
  local ok, ret1, ret2, ret3 = coroutine.resume(task.co, ...)
  if not ok then
    -- error in task: mark dead and print error
    task.status = "dead"
    printError("[task error] " .. (task.name or "") .. ": " .. tostring(ret1))
  else
    task.status = coroutine.status(task.co)
    return ret1, ret2, ret3
  end
end

-- Tasks yield special tables to request waiting for events/timers
-- yield types: {type="wait", filter=string or nil}  -- wait for an event matching filter
--              {type="sleep", until= os.clock() + seconds} -- sleep
--              {type="done"} -- finished

function Scheduler:run()
  local lastTick = os.clock()
  while true do
    -- clean dead tasks
    for i=#self.tasks,1,-1 do
      if self.tasks[i].status == "dead" then table.remove(self.tasks,i) end
    end
    if #self.tasks == 0 then break end

    -- process timers
    local now = os.clock()
    for id, t in pairs(self.timers) do
      if now >= t.when then
        -- resume task with timer event
        self:resumeTask(t.task, "timer", id)
        self.timers[id] = nil
      end
    end

    -- default: pull an event and dispatch to tasks waiting for it
    -- We use a single global os.pullEventRaw here and then resume the
    -- tasks which were waiting for that event.
    local event = table.pack(os.pullEventRaw()) -- event[1] is name

    -- dispatch: resume tasks that are waiting for this event
    for _, task in ipairs(self.tasks) do
      if coroutine.status(task.co) ~= "dead" then
        -- resume if task last yielded waiting for this event
        local ok, statusOrYield = coroutine.resume(task.co) -- try resume to get its yield reason
        if not ok then
          task.status = "dead"
          printError("[task error] " .. (task.name or "") .. ": " .. tostring(statusOrYield))
        else
          -- if yielded something we inspect if it's a wait request and store the filter
          if type(statusOrYield) == "table" and statusOrYield.type == "wait" then
            task._waitingFilter = statusOrYield.filter
            -- put task back to sleep until event occurs; we won't resume it here
          else
            -- the task yielded but not a wait table - ignore for now
          end
        end
      end
    end

    -- now dispatch the pulled event to any tasks whose filter matches
    for _, task in ipairs(self.tasks) do
      if task._waitingFilter ~= nil then
        local filter = task._waitingFilter
        local evName = event[1]
        if (not filter) or (filter == evName) then
          task._waitingFilter = nil
          -- resume with the event data
          local ok, r1 = coroutine.resume(task.co, table.unpack(event,1,event.n))
          if not ok then
            task.status = "dead"
            printError("[task error] " .. (task.name or "") .. ": " .. tostring(r1))
          end
        end
      end
    end

    -- avoid busy loop
    os.sleep(TASK_TICK)
  end
end

-- NOTE: The above scheduler skeleton demonstrates the idea but is simplified.
-- A production scheduler would keep track of which tasks are waiting and not
-- attempt to resume every task every pull. For this starter, we'll provide a
-- cooperative API so that many craftOS programs will work unmodified when
-- they call os.pullEvent / os.pullEventRaw.

-- == Sandboxed environment builder ==
local function makeSandbox(scheduler, task)
  -- sandbox env where we override os.pullEvent and os.pullEventRaw to yield
  -- back to scheduler so other tasks may run. Also provide os.startTimer / sleep.
  local env = {}
  -- copy globals
  for k,v in pairs(_ENV) do env[k]=v end

  -- override os.pullEvent and os.pullEventRaw
  env.os = shallow_copy(os)
  env.os.pullEventRaw = function()
    return coroutine.yield({type = "wait", filter = nil})
  end
  env.os.pullEvent = function(filter)
    -- If filter is provided, wait until that event only
    return coroutine.yield({type = "wait", filter = filter})
  end
  env.os.startTimer = function(sec)
    local id = scheduler.nextTimerId
    scheduler.nextTimerId = scheduler.nextTimerId + 1
    scheduler.timers[id] = {when = os.clock() + sec, task = task}
    return id
  end
  env.os.sleep = function(sec)
    -- simple sleep using timer
    local id = env.os.startTimer(sec)
    -- yield waiting for timer event with id
    local ev, tid = coroutine.yield({type = "wait", filter = "timer"})
    while tid ~= id do
      ev, tid = coroutine.yield({type = "wait", filter = "timer"})
    end
    return true
  end

  -- Provide a term redirect that uses the real term (no windows) but keeps compatibility
  env.term = term

  -- Provide shell.run to run programs using loadfile in the same sandbox
  env.shell = shallow_copy(shell)
  env.shell.run = function(programPath, ...)
    -- try /rom/programs and disk paths
    local f, err = loadfile(programPath)
    if not f then
      -- try with .lua
      f, err = loadfile(programPath .. ".lua")
    end
    if not f then
      -- try searching /rom/programs
      local ok
      local searchPaths = {"/rom/programs/", "/rom/programs/fun/", "/rom/programs/commands/"}
      for _,p in ipairs(searchPaths) do
        local path = p .. programPath
        ok, err = loadfile(path)
        if ok then f = ok; break end
        ok, err = loadfile(path .. ".lua")
        if ok then f = ok; break end
      end
      if not f then error(err or "Program not found: " .. tostring(programPath)) end
    end
    -- execute loaded chunk inside env
    setfenv(f, env)
    return f(...)
  end

  return env
end

-- == Simple graphical desktop ==
local Desktop = {}
function Desktop.new()
  local d = {icons = {}, tasks = {}, selected = 1}
  return setmetatable(d, {__index = Desktop})
end

function Desktop:addIcon(label, runFunc)
  table.insert(self.icons, {label = label, run = runFunc})
end

function Desktop:draw()
  term.clear()
  term.setCursorPos(1,1)
  term.setCursorBlink(false)
  -- title
  print("CCOS - Desktop")
  -- icons
  local x0, y0 = 2, 3
  local perRow = ICONS_PER_ROW
  for i,icon in ipairs(self.icons) do
    local col = ((i-1) % perRow)
    local row = math.floor((i-1) / perRow)
    local x = x0 + col * (ICON_SIZE.w + 2)
    local y = y0 + row * (ICON_SIZE.h + 1)
    term.setCursorPos(x, y)
    io.write("+" .. string.rep("-", ICON_SIZE.w-2) .. "+")
    for r=1,ICON_SIZE.h-2 do
      term.setCursorPos(x, y+r)
      io.write("|" .. string.rep(" ", ICON_SIZE.w-2) .. "|")
    end
    term.setCursorPos(x, y+ICON_SIZE.h-1)
    io.write("+" .. string.rep("-", ICON_SIZE.w-2) .. "+")
    -- label
    term.setCursorPos(x+1, y+1)
    io.write(icon.label:sub(1, ICON_SIZE.w-2))
    if i == self.selected then
      term.setCursorPos(x, y+ICON_SIZE.h)
      io.write("<selected>")
    end
  end
  -- taskbar
  local tw, th = SCREEN_WIDTH, 1
  term.setCursorPos(1, SCREEN_HEIGHT)
  local bar = "Tasks: "
  for _,t in ipairs(self.tasks) do bar = bar .. (t.name or "?") .. " " end
  write(bar)
end

-- == Boot / Example apps ==
local scheduler = Scheduler.new()
local desktop = Desktop.new()

-- Example: Clock app (simple)
local function clockApp()
  while true do
    term.setCursorPos(2, SCREEN_HEIGHT-2)
    write("Clock: " .. os.date("%H:%M:%S"))
    os.sleep(1)
    os.pullEvent("timer") -- cooperate with scheduler
  end
end

-- Example: Launcher wrapper that runs a program from disk
local function makeLauncher(path)
  return function()
    -- try to run the program using sandboxed shell.run
    local env = makeSandbox(scheduler, nil) -- make a temporary env (task will set task later)
    local f, err = loadfile(path)
    if not f then error(err or "cannot load") end
    setfenv(f, env)
    f()
  end
end

-- register icons
desktop:addIcon("Clock", function()
  local task = scheduler:createTask(function()
    local env = makeSandbox(scheduler)
    setfenv(clockApp, env)
    clockApp()
  end, "Clock")
  table.insert(desktop.tasks, task)
end)

desktop:addIcon("Shell (run)", function()
  -- Launch the default shell interactive in foreground (simple)
  local task = scheduler:createTask(function()
    local env = makeSandbox(scheduler)
    -- run /rom/programs/shell.lua if exists
    local f, err = loadfile("/rom/programs/shell.lua")
    if not f then error(err or "shell not found") end
    setfenv(f, env)
    f()
  end, "Shell")
  table.insert(desktop.tasks, task)
end)

-- draw desktop once
desktop:draw()

-- simple input loop: arrow keys to select, enter to launch
local function inputLoop()
  while true do
    local e = {os.pullEvent()}
    if e[1] == "key" then
      local key = e[2]
      -- 203=left, 205=right, 200=up, 208=down, 28=enter
      if key == 203 then desktop.selected = math.max(1, desktop.selected-1); desktop:draw()
      elseif key == 205 then desktop.selected = math.min(#desktop.icons, desktop.selected+1); desktop:draw()
      elseif key == 28 then
        -- launch selected icon
        local icon = desktop.icons[desktop.selected]
        if icon and icon.run then icon.run() end
        desktop:draw()
      end
    end
  end
end

-- create inputLoop as a task
scheduler:createTask(function() inputLoop() end, "Input")

-- run scheduler
scheduler:run()

print("All tasks finished - CCOS shutting down")
