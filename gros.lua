local jobs = {}
local jobId = 0
local currentFG = nil

-- Draws a simple status bar
local function drawBar()
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.setTextColor(colors.white)
  term.clearLine()
  term.write(" Jobs: ")
  for id, job in pairs(jobs) do
    if id == currentFG then
      term.write("[" .. id .. ":" .. job.name .. "*] ")
    else
      term.write("[" .. id .. ":" .. job.name .. "] ")
    end
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
end

-- Run a program in the background
local function runBG(name, ...)
  jobId = jobId + 1
  local args = {...}
  local co = coroutine.create(function()
    shell.run(name, table.unpack(args))
  end)
  jobs[jobId] = {co = co, name = name}
  return jobId
end

-- Bring job to foreground
local function runFG(id)
  if jobs[id] then
    currentFG = id
  else
    print("No such job")
  end
end

-- Simple job scheduler
local function scheduler()
  while true do
    drawBar()
    -- Run the current foreground job
    if currentFG and jobs[currentFG] then
      local ok, err = coroutine.resume(jobs[currentFG].co)
      if not ok or coroutine.status(jobs[currentFG].co) == "dead" then
        jobs[currentFG] = nil
        currentFG = nil
      end
    end

    -- Run background jobs without input
    for id, job in pairs(jobs) do
      if id ~= currentFG then
        if coroutine.status(job.co) ~= "dead" then
          coroutine.resume(job.co)
        else
          jobs[id] = nil
        end
      end
    end
    sleep(0)
  end
end

-- Example shell commands
shell.setAlias("bg", "bg.lua")
shell.setAlias("fg", "fg.lua")
shell.setAlias("jobs", "jobs.lua")

-- Tiny command handlers (you can make separate files if you want)
_G.bg = function(...) local id = runBG(...) print("Started job " .. id) end
_G.fg = function(id) runFG(tonumber(id)) end
_G.jobs = function()
  for id, job in pairs(jobs) do
    print(id .. ": " .. job.name .. (id == currentFG and " (fg)" or " (bg)"))
  end
end

scheduler()
