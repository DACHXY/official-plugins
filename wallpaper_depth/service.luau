--!nonstrict

noctalia.setUpdateInterval(1000)

local MODEL_SIZE = 99060839
local helperPath = noctalia.pluginDir() .. "/depth_helper.py"
local dataDir = noctalia.pluginDataDir()
if dataDir == nil then
  error("Wallpaper Depth requires a plugin data directory")
end
local operationPath = dataDir .. "/setup-operation.json"
local overridesPath = dataDir .. "/set-overrides.json"

local setupState = "checking"
local setupMessage = ""
local activeJob = nil
local cacheOperation = false
local pending = {}
local queued = {}
local outputs = {}
local lastAutoGenerate = nil
-- Per desktop widget set overrides: { [setId] = { threshold = 0-100, feather = 0-50 } }.
local overrides = {}
local pythonAvailable = noctalia.commandExists("python3")

local function decodeObject(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local value = noctalia.json.decode(raw)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function shortError(result, fallback)
  local message = ""
  if type(result) == "table" then
    message = noctalia.string.trim(result.stderr or "")
    if message == "" then
      message = noctalia.string.trim(result.stdout or "")
    end
  end
  if message == "" then
    message = fallback
  end
  if #message > 300 then
    message = string.sub(message, 1, 297) .. "..."
  end
  return message
end

local function parameters()
  local threshold = noctalia.getConfig("threshold")
  local feather = noctalia.getConfig("feather")
  local autoGenerate = noctalia.getConfig("auto_generate")
  if type(threshold) ~= "number" or type(feather) ~= "number" or type(autoGenerate) ~= "boolean" then
    return nil, noctalia.tr("service.invalid_settings")
  end
  threshold = math.max(0, math.min(100, threshold)) / 100
  feather = math.max(0, math.min(50, feather)) / 100
  return {
    threshold = threshold,
    feather = feather,
    autoGenerate = autoGenerate,
    key = string.format("%.4f:%.4f", threshold, feather),
  }, nil
end

-- The active desktop widget set on an output, or nil on shells without the API.
local function activeSetFor(outputName)
  if type(noctalia.activeWidgetSet) ~= "function" or type(outputName) ~= "string" then
    return nil
  end
  local set = noctalia.activeWidgetSet(outputName)
  if type(set) ~= "table" or type(set.id) ~= "string" or set.id == "" then
    return nil
  end
  return set
end

-- Global settings, overridden by the active widget set's entry. The key covers the effective
-- values plus the set id, so switching sets or editing an override invalidates cached work.
local function parametersFor(outputName)
  local base, err = parameters()
  if base == nil then
    return nil, err
  end
  local effective = {
    threshold = base.threshold,
    feather = base.feather,
    autoGenerate = base.autoGenerate,
    setId = nil,
    setName = nil,
    hasOverride = false,
  }
  local set = activeSetFor(outputName)
  if set ~= nil then
    effective.setId = set.id
    effective.setName = type(set.name) == "string" and set.name or set.id
    local override = overrides[set.id]
    if type(override) == "table" then
      if type(override.threshold) == "number" then
        effective.threshold = math.max(0, math.min(100, override.threshold)) / 100
        effective.hasOverride = true
      end
      if type(override.feather) == "number" then
        effective.feather = math.max(0, math.min(50, override.feather)) / 100
        effective.hasOverride = true
      end
    end
  end
  effective.key = string.format("%.4f:%.4f:%s", effective.threshold, effective.feather, effective.setId or "")
  return effective, nil
end

local function loadOverrides()
  local value = decodeObject(noctalia.readFile(overridesPath))
  return type(value) == "table" and value or {}
end

local function saveOverrides()
  local ok, err = noctalia.writeFile(overridesPath, noctalia.json.encode(overrides))
  if not ok then
    setupMessage = type(err) == "string" and err or noctalia.tr("service.override_save_failed")
  end
  return ok
end

local function clampSetting(value, minimum, maximum)
  if type(value) ~= "number" then
    return nil
  end
  return math.max(minimum, math.min(maximum, math.floor(value + 0.5)))
end

local function publish()
  local rows = {}
  for _, row in pairs(outputs) do
    local params = parametersFor(row.name)
    table.insert(rows, {
      name = row.name,
      wallpaperPath = row.wallpaperPath,
      state = row.state,
      message = row.message,
      cacheHit = row.cacheHit,
      elapsedMs = row.elapsedMs,
      setId = params ~= nil and params.setId or nil,
      setName = params ~= nil and params.setName or nil,
      hasOverride = params ~= nil and params.hasOverride or false,
      threshold = params ~= nil and math.floor(params.threshold * 100 + 0.5) or nil,
      feather = params ~= nil and math.floor(params.feather * 100 + 0.5) or nil,
    })
  end
  table.sort(rows, function(left, right)
    return left.name < right.name
  end)
  local params, parameterError = parameters()
  noctalia.state.set("wallpaper_depth.status", {
    setupState = setupState,
    setupMessage = setupMessage ~= "" and setupMessage or parameterError,
    busy = setupState == "running" or activeJob ~= nil or cacheOperation,
    offline = noctalia.getSetting("shell.offline_mode"),
    pythonAvailable = pythonAvailable,
    modelSize = MODEL_SIZE,
    threshold = params ~= nil and params.threshold or 0,
    feather = params ~= nil and params.feather or 0,
    autoGenerate = params ~= nil and params.autoGenerate or false,
    outputs = rows,
  })
end

local function setSetupState(state, message)
  setupState = state
  setupMessage = message or ""
  publish()
end

local function readOperation()
  return decodeObject(noctalia.readFile(operationPath))
end

local function enqueue(outputName, wallpaperPath, params)
  if setupState ~= "ready" or type(wallpaperPath) ~= "string" or wallpaperPath == "" then
    return
  end
  local key = wallpaperPath .. "\n" .. params.key
  if queued[outputName] == key then
    return
  end
  if activeJob ~= nil and activeJob.outputName == outputName and activeJob.key == key then
    return
  end
  queued[outputName] = key
  table.insert(pending, {
    outputName = outputName,
    wallpaperPath = wallpaperPath,
    threshold = params.threshold,
    feather = params.feather,
    parametersKey = params.key,
    key = key,
  })
end

local runNext

runNext = function()
  if activeJob ~= nil or cacheOperation or setupState ~= "ready" then
    return
  end
  local params = parameters()
  if params == nil then
    return
  end

  local job = nil
  while #pending > 0 do
    local candidate = table.remove(pending, 1)
    queued[candidate.outputName] = nil
    local currentPath = noctalia.wallpaperPath(candidate.outputName)
    local currentParameters = parametersFor(candidate.outputName)
    if currentPath == candidate.wallpaperPath
      and currentParameters ~= nil
      and candidate.parametersKey == currentParameters.key
    then
      job = candidate
      break
    end
  end
  if job == nil then
    publish()
    return
  end

  activeJob = job
  local row = outputs[job.outputName]
  if row ~= nil then
    row.state = "processing"
    row.message = ""
    row.cacheHit = nil
    row.elapsedMs = nil
  end
  publish()

  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "generate",
    "--wallpaper",
    job.wallpaperPath,
    "--threshold",
    tostring(job.threshold),
    "--feather",
    tostring(job.feather),
  }, function(result)
    local completedJob = activeJob
    activeJob = nil
    if completedJob == nil then
      runNext()
      return
    end

    local currentParameters = parametersFor(completedJob.outputName)
    local currentPath = noctalia.wallpaperPath(completedJob.outputName)
    local currentRow = outputs[completedJob.outputName]
    local stale = currentParameters == nil
      or currentParameters.key ~= completedJob.parametersKey
      or currentPath ~= completedJob.wallpaperPath
    if stale then
      if currentRow ~= nil then
        currentRow.state = currentPath ~= nil and "waiting" or "no_wallpaper"
      end
      if currentParameters ~= nil and currentPath ~= nil then
        enqueue(completedJob.outputName, currentPath, currentParameters)
      end
      publish()
      runNext()
      return
    end

    if result.exitCode ~= 0 or result.timedOut then
      noctalia.setWallpaperMask(completedJob.outputName, nil)
      if currentRow ~= nil then
        currentRow.state = "error"
        currentRow.message = shortError(result, noctalia.tr("service.generation_failed"))
      end
    else
      local generated = decodeObject(result.stdout)
      if generated == nil
        or type(generated.maskPath) ~= "string"
        or generated.maskPath == ""
        or generated.wallpaperPath ~= completedJob.wallpaperPath
      then
        noctalia.setWallpaperMask(completedJob.outputName, nil)
        if currentRow ~= nil then
          currentRow.state = "error"
          currentRow.message = noctalia.tr("service.invalid_result")
        end
      else
        noctalia.setWallpaperMask(completedJob.outputName, {
          path = generated.maskPath,
          wallpaperPath = completedJob.wallpaperPath,
        })
        if currentRow ~= nil then
          currentRow.state = "ready"
          currentRow.message = ""
          currentRow.cacheHit = generated.cacheHit == true
          currentRow.elapsedMs = tonumber(generated.elapsedMs)
        end
      end
    end
    publish()
    runNext()
  end, 60000)

  if not accepted then
    activeJob = nil
    noctalia.setWallpaperMask(job.outputName, nil)
    if row ~= nil then
      row.state = "error"
      row.message = noctalia.tr("service.start_helper_failed")
    end
    publish()
    runNext()
  end
end

local function enqueueAll(force)
  local params, parameterError = parameters()
  if params == nil then
    setSetupState(setupState, parameterError)
    return
  end
  for outputName, row in pairs(outputs) do
    local effective = parametersFor(outputName)
    if effective ~= nil and type(row.wallpaperPath) == "string" and row.wallpaperPath ~= "" then
      if force then
        noctalia.setWallpaperMask(outputName, nil)
        row.state = "waiting"
        row.message = ""
        row.parametersKey = effective.key
      end
      enqueue(outputName, row.wallpaperPath, effective)
    end
  end
  publish()
  runNext()
end

local function verifySetup()
  if not pythonAvailable then
    setSetupState("missing", noctalia.tr("service.python_missing"))
    return
  end
  setSetupState("checking", "")
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "status",
  }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      setSetupState("missing", shortError(result, noctalia.tr("service.validation_failed")))
      return
    end
    local value = decodeObject(result.stdout)
    if value ~= nil and value.ready == true then
      setSetupState("ready", "")
      enqueueAll(false)
    else
      setSetupState("missing", noctalia.tr("service.setup_missing"))
    end
  end, 60000)
  if not accepted then
    setSetupState("error", noctalia.tr("service.start_validation_failed"))
  end
end

local function startSetup()
  if noctalia.getSetting("shell.offline_mode") then
    setSetupState("error", noctalia.tr("service.offline"))
    return
  end
  if not pythonAvailable then
    setSetupState("error", noctalia.tr("service.python_missing"))
    return
  end
  if activeJob ~= nil or cacheOperation then
    setSetupState("error", noctalia.tr("service.busy"))
    return
  end

  noctalia.writeFile(operationPath, '{"state":"starting"}\n')
  setSetupState("running", noctalia.tr("service.setup_running"))
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "setup",
  })
  if not accepted then
    setSetupState("error", noctalia.tr("service.start_setup_failed"))
  end
end

local function pollSetup()
  if setupState ~= "running" then
    return
  end
  local operation = readOperation()
  if operation == nil or operation.state == "starting" or operation.state == "running" then
    return
  end
  if operation.state == "ready" then
    verifySetup()
  elseif operation.state == "error" then
    setSetupState(
      "error", type(operation.message) == "string" and operation.message or noctalia.tr("service.setup_failed")
    )
  end
end

local function clearCache()
  if activeJob ~= nil or cacheOperation or setupState == "running" then
    return
  end
  cacheOperation = true
  pending = {}
  queued = {}
  for outputName, row in pairs(outputs) do
    noctalia.setWallpaperMask(outputName, nil)
    row.state = row.wallpaperPath ~= nil and "waiting" or "no_wallpaper"
    row.message = ""
  end
  publish()
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "clear-cache",
  }, function(result)
    cacheOperation = false
    if result.exitCode ~= 0 or result.timedOut then
      setupMessage = shortError(result, noctalia.tr("service.clear_cache_failed"))
    else
      setupMessage = ""
    end
    publish()
    local params = parameters()
    if params ~= nil and params.autoGenerate then
      enqueueAll(false)
    end
  end, 60000)
  if not accepted then
    cacheOperation = false
    setupMessage = noctalia.tr("service.start_clear_cache_failed")
    publish()
  end
end

local function syncOutputs()
  local params, parameterError = parameters()
  if params == nil then
    setupMessage = parameterError
    publish()
    return
  end
  local current = {}
  for _, output in ipairs(noctalia.outputs()) do
    current[output.name] = true
    local wallpaperPath = noctalia.wallpaperPath(output.name)
    if wallpaperPath ~= nil and not noctalia.fileExists(wallpaperPath) then
      wallpaperPath = nil
    end
    local row = outputs[output.name]
    if row == nil then
      row = { name = output.name, state = "no_wallpaper", message = "" }
      outputs[output.name] = row
    end
    local effective = parametersFor(output.name)
    local parametersKey = effective ~= nil and effective.key or nil
    if row.wallpaperPath ~= wallpaperPath or row.parametersKey ~= parametersKey then
      noctalia.setWallpaperMask(output.name, nil)
      row.wallpaperPath = wallpaperPath
      row.parametersKey = parametersKey
      row.state = wallpaperPath ~= nil and "waiting" or "no_wallpaper"
      row.message = ""
      row.cacheHit = nil
      row.elapsedMs = nil
      queued[output.name] = nil
      if params.autoGenerate and wallpaperPath ~= nil and effective ~= nil then
        enqueue(output.name, wallpaperPath, effective)
      end
    end
  end
  for outputName, _ in pairs(outputs) do
    if current[outputName] ~= true then
      outputs[outputName] = nil
      queued[outputName] = nil
    end
  end

  if lastAutoGenerate == false and params.autoGenerate then
    for outputName, row in pairs(outputs) do
      if row.state == "waiting" and row.wallpaperPath ~= nil then
        local effective = parametersFor(outputName)
        if effective ~= nil then
          enqueue(outputName, row.wallpaperPath, effective)
        end
      end
    end
  end
  lastAutoGenerate = params.autoGenerate
  publish()
  runNext()
end

local function setOverride(outputName, threshold, feather)
  local set = activeSetFor(outputName)
  if set == nil then
    setupMessage = noctalia.tr("service.no_active_set")
    publish()
    return
  end
  local clampedThreshold = clampSetting(threshold, 0, 100)
  local clampedFeather = clampSetting(feather, 0, 50)
  if clampedThreshold == nil or clampedFeather == nil then
    setupMessage = noctalia.tr("service.invalid_settings")
    publish()
    return
  end
  overrides[set.id] = { threshold = clampedThreshold, feather = clampedFeather }
  setupMessage = ""
  saveOverrides()
  syncOutputs()
end

local function clearOverride(outputName)
  local set = activeSetFor(outputName)
  if set == nil then
    setupMessage = noctalia.tr("service.no_active_set")
    publish()
    return
  end
  if overrides[set.id] == nil then
    return
  end
  overrides[set.id] = nil
  setupMessage = ""
  saveOverrides()
  syncOutputs()
end

noctalia.state.watch("wallpaper_depth.command", function(command)
  if type(command) ~= "table" then
    return
  end
  noctalia.state.set("wallpaper_depth.command", nil)
  if command.action == "setup" then
    startSetup()
  elseif command.action == "generate" then
    enqueueAll(true)
  elseif command.action == "clear_cache" then
    clearCache()
  elseif command.action == "set_override" then
    setOverride(command.outputName, command.threshold, command.feather)
  elseif command.action == "clear_override" then
    clearOverride(command.outputName)
  end
end)

function onIpc(event, _payload)
  if event == "setup" then
    startSetup()
  elseif event == "generate" then
    enqueueAll(true)
  elseif event == "clear-cache" then
    clearCache()
  end
end

function onConfigChanged()
  syncOutputs()
end

function update()
  pollSetup()
  syncOutputs()
end

local operation = readOperation()
overrides = loadOverrides()
if operation ~= nil and (operation.state == "running" or operation.state == "starting") then
  setupState = "running"
  setupMessage = noctalia.tr("service.setup_running")
else
  verifySetup()
end
syncOutputs()
