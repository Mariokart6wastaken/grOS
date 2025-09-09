-- gros.lua - Graphical Round-robin OS layer for ComputerCraft
-- One full-screen app at a time, multitasking via coroutine scheduling.
-- Compatible with CraftOS programs; each task has a virtual terminal.
-- Hotkeys: Ctrl+N new shell, Ctrl+Tab next, Ctrl+Shift+Tab prev, Ctrl+W close

local isColor = term.isColor and term.isColor()
local nativeTerm = term.current()
local native = term.native()
local w, h = term.getSize()

-- ========== Small utils ==========
local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function shallow_copy(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end

-- Keys table is provided by CraftOS
local keys = keys

-- ========== Virtual Terminal ==========
local function makeVT(width, height)
  width  = width or w
  height = height or h - 1 -- leave room for status bar
  local cx, cy = 1, 1
  local tCol, bCol = colors.white, colors.black
  local blink = true

  local function blankLine(bg)
    return string.rep(" ", width), string.rep(string.char(bg), width)
  end

  -- Buffers: text and background colors; text color stored with blit per char
  local text = {}
  local textCol = {}
  local backCol = {}
  for y=1, height do
    text[y]    = string.rep(" ", width)
    textCol[y] = string.rep(string.char(colors.white), width)
    backCol[y] = string.rep(string.char(colors.black), width)
  end

  local vt = {}

  function vt.getSize() return width, height end
  function vt.isColor() return isColor end
  function vt.getCursorPos() return cx, cy end
  function vt.setCursorPos(x, y) cx = clamp(math.floor(x),1,width); cy = clamp(math.floor(y),1,height) end
  function vt.getCursorBlink() return blink end
  function vt.setCursorBlink(b) blink = not not b end
  function vt.setTextColor(c) tCol = c end
  function vt.setBackgroundColor(c) bCol = c end
  vt.setTextColour = vt.setTextColor
  vt.setBackgroundColour = vt.setBackgroundColor

  function vt.clear()
    for y=1, height do
      text[y]    = string.rep(" ", width)
      textCol[y] = string.rep(string.char(tCol), width)
      backCol[y] = string.rep(string.char(bCol), width)
    end
  end

  function vt.clearLine()
    text[cy]    = string.rep(" ", width)
    textCol[cy] = string.rep(string.char(tCol), width)
    backCol[cy] = string.rep(string.char(bCol), width)
  end

  local function writeAt(x, y, s, tcChar, bcChar)
    if y < 1 or y > height then return end
    if x < 1 then s = string.sub(s, 2 - x); x = 1 end
    if x > width then return end
    if x + #s - 1 > width then s = string.sub(s, 1, width - x + 1) end
    local pre  = x > 1 and string.sub(text[y], 1, x-1) or ""
    local post = x + #s <= width and string.sub(text[y], x + #s) or ""
    text[y] = pre .. s .. post

    -- Colors
    local tcLine = textCol[y]
    local bcLine = backCol[y]
    local tcMid  = string.rep(tcChar, #s)
    local bcMid  = string.rep(bcChar, #s)
    local tcPre  = x > 1 and string.sub(tcLine, 1, x-1) or ""
    local tcPost = x + #s <= width and string.sub(tcLine, x + #s) or ""
    local bcPre  = x > 1 and string.sub(bcLine, 1, x-1) or ""
    local bcPost = x + #s <= width and string.sub(bcLine, x + #s) or ""
    textCol[y] = tcPre .. tcMid .. tcPost
    backCol[y] = bcPre .. bcMid .. bcPost
  end

  function vt.write(s)
    s = tostring(s)
    local tcChar = string.char(tCol)
    local bcChar = string.char(bCol)
    writeAt(cx, cy, s, tcChar, bcChar)
    cx = math.min(w, cx + #s)
  end

  function vt.blit(s, cols, backs)
    -- cols/backs are strings of color chars (same as native blit)
    writeAt(cx, cy, s, cols:sub(1, #s), backs:sub(1, #s))
    cx = math.min(w, cx + #s)
  end

  function vt.scroll(n)
    n = math.floor(n)
    if n == 0 then return end
    if math.abs(n) >= height then
      vt.clear()
      return
    end
    if n > 0 then
      for y=1, height-n do
        text[y]    = text[y+n]
        textCol[y] = textCol[y+n]
        backCol[y] = backCol[y+n]
      end
      for y=height-n+1, height do
        text[y], backCol[y] = blankLine(bCol)
        textCol[y] = string.rep(string.char(tCol), width)
      end
    else
      for y=height, 1-n, -1 do
        text[y]    = text[y+n]
        textCol[y] = textCol[y+n]
        backCol[y] = backCol[y+n]
      end
      for y=1, -n do
        text[y], backCol[y] = blankLine(bCol)
        textCol[y] = string.rep(string.char(tCol), width)
      end
    end
  end

  -- Expose buffers for compositor
  function vt._getBuffers() return text, textCol, backCol end

  return vt
end

-- ========== Process table & scheduler ==========
local nextPid = 1
local procs = {}      -- pid -> {pid,name,co,vt,filter,env,alive}
local order = {}      -- round-robin order of pids
local focusIdx = 1    -- index into 'order' of focused task

local function drawStatusBar()
  term.redirect(native)
  term.setCursorPos(1, h)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.black)
  term.clearLine()
  local labels = {}
  for i,pid in ipairs(order) do
    local p = procs[pid]
    local mark = (i == focusIdx) and "*" or " "
    table.insert(labels, string.format("[%s%s]", mark, p and p.name or "?"))
  end
  local bar = table.concat(labels, " ")
  term.setCursorPos(1, h)
  term.write(string.sub(bar, 1, w))
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
end

local function composeFocused()
  local pid = order[focusIdx]
  local p = pid and procs[pid]
  if not p then return end
  local vt = p.vt
  local text, cols, backs = vt._getBuffers()
  term.redirect(native)
  -- draw the VT to the real screen (rows 1..h-1)
  for y=1, h-1 do
    term.setCursorPos(1, y)
    if text[y] then
      -- Convert color-id bytes to blit hex (legacy format), but CraftOS accepts char-encoded colors too.
      term.blit(text[y], cols[y], backs[y])
    else
      term.clearLine()
    end
  end
  drawStatusBar()
end

local function setFocus(index)
  if #order == 0 then return end
  focusIdx = ((index - 1) % #order) + 1
  composeFocused()
end

local function focusNext() setFocus(focusIdx + 1) end
local function focusPrev() setFocus(focusIdx - 1) end

local function removePid(pid)
  -- find index
  local idx
  for i,pp in ipairs(order) do if pp == pid then idx = i break end end
  if idx then table.remove(order, idx) end
  procs[pid] = nil
  if focusIdx > #order then focusIdx = #order end
  if focusIdx < 1 then focusIdx = 1 end
  composeFocused()
end

-- Spawns a new process; 'runner' is a function OR a path string to run under shell
local function spawn(runner, name, args)
  local pid = nextPid; nextPid = nextPid + 1
  local vt = makeVT(w, h-1)

  -- Build environment; keep global libs but replace 'term'
  local env = setmetatable({}, { __index = _G })
  env.term = vt

  local co
  if type(runner) == "function" then
    co = coroutine.create(function()
      runner(table.unpack(args or {}))
    end)
  elseif type(runner) == "string" then
    -- Run under shell so normal programs work (path lookup, args, etc)
    co = coroutine.create(function()
      -- Give the program the virtual term for its lifetime
      local old = term.redirect(vt)
      local ok, err = pcall(function()
        shell.run(runner, table.unpack(args or {}))
      end)
      term.redirect(old)
      if not ok and err then error(err, 0) end
    end)
  else
    error("spawn: runner must be function or path string")
  end

  procs[pid] = {
    pid = pid,
    name = name or ("task"..pid),
    co = co,
    vt = vt,
    filter = nil,
    env = env,
    alive = true,
  }
  table.insert(order, pid)
  focusIdx = #order
  composeFocused()
  return pid
end

local function resumeProc(p, event)
  if not p.alive then return end
  -- Event filter semantics like parallel: if p.filter is nil or matches event[1], deliver
  if p.filter ~= nil and p.filter ~= event[1] then return end
  local ok, newFilter = coroutine.resume(p.co, table.unpack(event))
  if not ok then
    -- crashed
    p.alive = false
    local msg = tostring(newFilter)
    -- Show error in its VT
    local vt = p.vt
    vt.setCursorPos(1, h-2); vt.setTextColor(colors.red); vt.write("[crashed] "); vt.setTextColor(colors.white); vt.write(msg)
    composeFocused()
    -- remove after a short delay queued
    os.queueEvent("__gros_dead", p.pid)
    return
  end
  if coroutine.status(p.co) == "dead" then
    p.alive = false
    os.queueEvent("__gros_dead", p.pid)
    return
  end
  p.filter = newFilter
end

-- ========== Hotkey handling ==========
local ctrlDown = false
local shiftDown = false
local function shouldSendTo(pid, ev)
  local e = ev[1]
  if e == "char" or e == "key" or e == "key_up" or e == "mouse_click" or e == "mouse_up"
     or e == "mouse_drag" or e == "mouse_scroll" or e == "paste" then
    -- only focused gets input
    return pid == order[focusIdx]
  end
  return true -- everything else goes to all
end

local function handleHotkeys(ev)
  local e = ev[1]
  if e == "key" then
    if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then ctrlDown = true end
    if ev[2] == keys.leftShift or ev[2] == keys.rightShift then shiftDown = true end

    if ctrlDown and ev[2] == keys.n then
      spawn("shell", "shell")
      composeFocused()
      return true
    elseif ctrlDown and ev[2] == keys.tab then
      if shiftDown then focusPrev() else focusNext() end
      return true
    elseif ctrlDown and ev[2] == keys.w then
      local pid = order[focusIdx]
      if pid and procs[pid] then procs[pid].alive = false; os.queueEvent("__gros_dead", pid) end
      return true
    end
  elseif e == "key_up" then
    if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then ctrlDown = false end
    if ev[2] == keys.leftShift or ev[2] == keys.rightShift then shiftDown = false end
  end
  return false
end

-- ========== Main ==========
local function main()
  term.redirect(native)
  term.setBackgroundColor(colors.black)
  term.clear()
  drawStatusBar()

  -- Start one interactive shell
  spawn("shell", "shell")

  while true do
    local ev = { os.pullEventRaw() }

    -- Let Ctrl+T terminate focused program (CraftOS behavior). Kernel continues.
    if ev[1] == "terminate" then
      local pid = order[focusIdx]
      if pid and procs[pid] then
        procs[pid].alive = false
        os.queueEvent("__gros_dead", pid)
      end
      goto continue
    end

    -- Resize support
    if ev[1] == "term_resize" then
      w, h = term.getSize()
      -- Recreate all VTs with new size
      local newOrder = shallow_copy(order)
      local newProcs = {}
      for _, pid in ipairs(newOrder) do
        local p = procs[pid]
        local oldVT = p.vt
        local newVT = makeVT(w, h-1)
        -- best-effort: render "Resized" marker
        newVT.setCursorPos(1,1); newVT.setTextColor(colors.yellow); newVT.write("[Resized]")
        p.vt = newVT
        newProcs[pid] = p
      end
      procs = newProcs
      composeFocused()
    end

    -- Kernel hotkeys (intercept before dispatch)
    if handleHotkeys(ev) then
      goto continue
    end

    -- Reap dead processes
    if ev[1] == "__gros_dead" then
      removePid(ev[2])
      if #order == 0 then
        -- all tasks closed; exit back to CraftOS
        term.redirect(native)
        term.clear()
        term.setCursorPos(1,1)
        print("gros: all tasks closed")
        return
      end
      goto continue
    end

    -- Dispatch events to processes
    for _, pid in ipairs(order) do
      local p = procs[pid]
      if p and p.alive and shouldSendTo(pid, ev) then
        resumeProc(p, ev)
      end
    end

    -- Keep composing the focused VT (many programs update often)
    composeFocused()

    ::continue::
  end
end

local ok, err = pcall(main)
term.redirect(native)
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  term.clear()
  term.setCursorPos(1,1)
  print("gros kernel error:")
  print(err)
end
