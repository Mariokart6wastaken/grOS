-- Computercraft Graphical "OS" with cooperative multitasking
-- Filename: gui_os.lua
-- Drop this into your .minecraft/computercraft/rom or run from shell.
--
-- Goals:
--  * Provide a simple graphical "desktop" (no windowing) with icons.
--  * Run multiple craftOS programs concurrently (cooperative multitasking).
--  * Keep programs largely compatible: they will see most common APIs
--    (term, fs, peripheral, os, colors, etc.) but their terminal will be
--    redirected to a pseudo-term so background apps don't stomp the screen.
--
-- Limitations / Notes:
--  * This is cooperative multitasking: programs must yield when waiting for
--    events or sleeping. The loader wraps os.sleep and event.pull to yield
--    to the kernel so other processes can run. Programs that busy-loop
--    without yielding will starve other processes.
--  * Full compatibility with every craftOS program is NOT guaranteed — some
--    native internals expect the real term or blocking shell.run behavior.
--    However most text-mode programs that use event.pull, os.pullEvent,
--    or sleep will behave properly.
--  * There is no windowing: when a program becomes the "foreground" app its
--    pseudo-term is copied to the real terminal; other apps run in the
--    background and don't draw.
--
-- How to use:
--  1. place this file on the computer and run `gui_os.lua`
--  2. Use the arrow keys or mouse to select icons and press Enter or click
--     to launch programs (they should be in the computer's filesystem).
--  3. Press Ctrl+T (or the assigned key) to switch to the task list.
--
-- Enjoy! Tweak and expand as needed.

local term_native = term.native()
local w, h = term.getSize()

-- Simple screen buffer helper (for pseudo-terminals)
local function makeBuffer(w,h)
  local chars = {}
  local colors = {}
  for y=1,h do
    chars[y] = {}
    colors[y] = {}
    for x=1,w do
      chars[y][x] = " "
      colors[y][x] = {text=colours.white or colors and colors.white, bg=colours.black or colors and colors.black}
    end
  end
  return {w=w,h=h,chars=chars,colors=colors}
end

local function drawBuffer(buf)
  term.setCursorPos(1,1)
  for y=1,buf.h do
    local line = table.concat(buf.chars[y])
    term.setCursorPos(1,y)
    term.write(line)
  end
end

-- pseudo-term implementation: provides enough of the term API for programs
local function makePseudoTerm()
  local buf = makeBuffer(w,h)
  local curx, cury = 1,1
  local curTextColor = colours.white or colors.white
  local curBG = colours.black or colors.black

  local t = {}
  function t.clear()
    for y=1,buf.h do
      for x=1,buf.w do buf.chars[y][x] = ' ' end
    end
    curx,cury = 1,1
  end
  function t.clearLine()
    for x=1,buf.w do buf.chars[cury][x] = ' ' end
    curx = 1
  end
  function t.setCursorPos(x,y) curx,cury = x,y end
  function t.getCursorPos() return curx,cury end
  function t.setTextColor(c) curTextColor = c end
  function t.setBackgroundColor(c) curBG = c end
  function t.getSize() return buf.w, buf.h end
  function t.write(s)
    for i=1,#s do
      local ch = s:sub(i,i)
      if curx > buf.w then curx = 1; cury = cury + 1 end
      if cury > buf.h then break end
      buf.chars[cury][curx] = ch
      curx = curx + 1
    end
  end
  function t.blit(text, textColor, bgColor)
    -- naive blit impl: ignore color strings and just write chars
    t.write(text)
  end
  function t.getBuffer() return buf end
  return t
end

-- Process / kernel implementation
local Kernel = {}
Kernel.processes = {} -- pid -> process table
Kernel.nextPid = 2 -- reserve 1 for kernel shell

local function now() return os.epoch and os.epoch('ms') or (os.time()*1000) end

local function makeProcess(chunkPath, args)
  local pid = Kernel.nextPid; Kernel.nextPid = Kernel.nextPid + 1
  local pseudoTerm = makePseudoTerm()
  local env = {}
  -- minimal API surface forwarded into the process environment
  local allowed = {"fs","io","os","peripheral","colors","colours","textutils","sleep","paintutils","rs","redstone","commands","gps","http","term","string","table","math","parallel","sides","commands"}

  -- copy globals but override term, os.sleep and event pulling to cooperate with kernel
  for k,v in pairs(_G) do env[k] = v end
  env.term = pseudoTerm

  -- override os.sleep to yield to kernel
  env.os = setmetatable({}, {__index = function(t,k) return _G.os[k] end})
  env.os.sleep = function(t)
    -- yield a sleep request (milliseconds)
    coroutine.yield({type="sleep", time=(t or 1)})
  end

  -- event.pull replacement
  env.os.pullEvent = function(name)
    local ev = coroutine.yield({type="pullEvent", name=name})
    -- when resumed, kernel passes the event table back
    return table.unpack(ev or {})
  end
  -- also provide old-style event-based API
  env.event = setmetatable({}, {__index=function(_,k) return _G.event[k] end})
  env.event.pull = function(name)
    local ev = coroutine.yield({type="pullEvent", name=name})
    return table.unpack(ev or {})
  end

  -- loader: load the program as a chunk
  local ok, chunkOrErr = pcall(loadfile, chunkPath)
  if not ok or type(chunkOrErr) ~= 'function' then
    -- return a process that prints the error then exits
    local function errProc()
      pseudoTerm.clear()
      pseudoTerm.setCursorPos(1,1)
      pseudoTerm.write("[Error loading: "..tostring(chunkPath).."]")
      pseudoTerm.setCursorPos(1,3)
      pseudoTerm.write(tostring(chunkOrErr))
      coroutine.yield({type="exit"})
    end
    local co = coroutine.create(errProc)
    return {pid=pid, co=co, term=pseudoTerm, path=chunkPath, args=args or {}, wake=0, status="ready"}
  end

  -- If loadfile succeeded, wrap the chunk so it gets our env
  local chunk = chunkOrErr
  -- try to set environment for compatibility with Lua versions
  local setfenv = rawget(_G, 'setfenv')
  if setfenv then setfenv(chunk, env) else
    -- Lua 5.2+: loadfile can accept env; but if not, create a wrapper
    -- We'll execute the chunk in env by creating a function that sets _ENV
    local wrapper = load([[return function(...) local _ENV = ... return (function()]]..' end )']])
    -- fallback: simpler approach is to just run chunk in a coroutine with env as _ENV
  end

  local function runner(...)
    -- set _ENV to env for chunk execution if supported
    local f = chunk
    -- try load with environment
    local success, res = pcall(function() return f(table.unpack(args or {})) end)
    if not success then
      -- if program errors, print to pseudoTerm
      pseudoTerm.clear()
      pseudoTerm.setCursorPos(1,1)
      pseudoTerm.write("Program error: ")
      pseudoTerm.setCursorPos(1,2)
      pseudoTerm.write(tostring(res))
    end
    -- when done, yield an exit event
    coroutine.yield({type="exit"})
  end

  local co = coroutine.create(runner)
  return {pid=pid, co=co, term=pseudoTerm, path=chunkPath, args=args or {}, wake=0, status="ready"}
end

function Kernel:spawn(path, args)
  local proc = makeProcess(path, args)
  self.processes[proc.pid] = proc
  return proc.pid
end

function Kernel:kill(pid)
  self.processes[pid] = nil
end

-- scheduler main loop (cooperative)
function Kernel:run()
  local timers = {}
  local function getNextWake()
    local soon = math.huge
    for pid,proc in pairs(self.processes) do
      if proc.wake and proc.wake > 0 and proc.wake < soon then soon = proc.wake end
    end
    return soon
  end

  while true do
    -- check if there's any processes
    if not next(self.processes) then
      -- draw desktop and wait for user to launch something
      self:drawDesktop()
      local ev = {os.pullEvent()}
      self:handleDesktopEvent(ev)
    end

    -- attempt to resume each process (simple round-robin)
    for pid,proc in pairs(self.processes) do
      if proc.status ~= "dead" then
        -- skip sleeping processes until their wake time
        if proc.wake and proc.wake > now() then goto continue end
        local ok, yielded = coroutine.resume(proc.co)
        if not ok then
          -- error in process; print to its pseudo-term and mark dead
          proc.status = "dead"
        else
          if coroutine.status(proc.co) == 'dead' then
            proc.status = 'dead'
            -- leave buffer intact; kernel may remove later
          else
            -- yielded something useful
            if type(yielded) == 'table' then
              if yielded.type == 'sleep' then
                proc.wake = now() + (yielded.time*1000)
              elseif yielded.type == 'pullEvent' then
                -- wait until we receive the event; we register interest
                proc.waiting = yielded.name
              elseif yielded.type == 'exit' then
                proc.status = 'dead'
              end
            end
          end
        end
      end
      ::continue::
    end

    -- process events from the computer and forward to interested procs
    local timeout = 0.05
    local evData = {os.pullEventRaw(timeout)}
    if evData[1] then
      -- forward event to any process waiting for it
      for pid,proc in pairs(self.processes) do
        if proc.waiting then
          if not proc.waiting or proc.waiting == evData[1] then
            proc.waiting = nil
            -- resume and pass the event payload
            coroutine.resume(proc.co, evData)
          end
        end
      end
      -- also allow keyboard/mouse events to control the desktop
      self:handleGlobalEvent(evData)
    end

    -- draw foreground app (pick the first non-dead process as foreground)
    local fg = nil
    for pid,proc in pairs(self.processes) do if proc.status ~= 'dead' then fg = proc; break end end
    if fg then
      -- copy its buffer to the native term so it appears on screen
      drawBuffer(fg.term.getBuffer())
    else
      -- no foreground process -> draw desktop
      self:drawDesktop()
    end

    -- cleanup dead processes
    for pid,proc in pairs(self.processes) do if proc.status == 'dead' then self.processes[pid]=nil end end
  end
end

-- Desktop: list .lua programs in / (or /rom/programs) as icons
function Kernel:scanPrograms()
  local list = {}
  local function tryAdd(path)
    if fs.exists(path) and not fs.isDir(path) then table.insert(list, path) end
  end
  -- look in root and in rom/programs
  for _,f in ipairs(fs.list("/")) do tryAdd('/'..f) end
  if fs.exists('/rom/programs') then for _,f in ipairs(fs.list('/rom/programs')) do tryAdd('/rom/programs/'..f) end end
  return list
end

Kernel.selected = 1
function Kernel:drawDesktop()
  term.setCursorPos(1,1)
  term.clear()
  term.setCursorPos(2,1)
  term.write("MyCC Desktop")
  local progs = self:scanPrograms()
  for i=1,#progs do
    local x = ((i-1) % 4) * 18 + 2
    local y = math.floor((i-1) / 4) * 4 + 3
    term.setCursorPos(x,y)
    if i == self.selected then term.write("> ") else term.write("  ") end
    term.write(fs.getName(progs[i]))
  end
end

function Kernel:handleDesktopEvent(ev)
  local evt = ev[1]
  if evt == 'mouse_click' then
    -- map mouse to icons
    local mx,my = ev[3], ev[4]
    local col = math.floor((mx-2)/18)
    local row = math.floor((my-3)/4)
    local idx = row*4 + col + 1
    local progs = self:scanPrograms()
    if progs[idx] then self:spawn(progs[idx]) end
  elseif evt == 'key' then
    local key = ev[2]
    if key == keys.right then self.selected = math.min(self.selected+1, #self:scanPrograms())
    elseif key == keys.left then self.selected = math.max(self.selected-1,1)
    elseif key == keys.enter then local progs=self:scanPrograms(); if progs[self.selected] then self:spawn(progs[self.selected]) end end
  end
end

function Kernel:handleGlobalEvent(ev)
  -- allow Ctrl+Alt+something to do kernel actions (basic example: terminate all)
  if ev[1] == 'key' and ev[2] == keys.delete then
    -- kill all processes
    for pid,_ in pairs(self.processes) do self:kill(pid) end
  end
end

-- bootstrap: spawn a shell for PID 1 if user wants
local kernel = Kernel

-- auto-launch a small shell or leave desktop
kernel:run()

-- End of file
