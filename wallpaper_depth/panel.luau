--!nonstrict

local closeButton = true

local render

local status = {
  setupState = "checking",
  setupMessage = "",
  busy = true,
  outputs = {},
}

local function tr(key, params)
  return noctalia.tr(key, params)
end

local function outputState(row)
  if row.state == "ready" then
    local detail = tr("panel.output.ready")
    if type(row.elapsedMs) == "number" then
      detail = tr("panel.output.ready_time", { seconds = string.format("%.1f", row.elapsedMs / 1000) })
    end
    if row.cacheHit == true then
      detail = detail .. " · " .. tr("panel.output.cached")
    end
    return "check", "primary", detail
  elseif row.state == "processing" then
    return "loader-2", "primary", tr("panel.output.processing")
  elseif row.state == "waiting" then
    return "hourglass", "on_surface_variant", tr("panel.output.waiting")
  elseif row.state == "error" then
    return "alert-triangle", "error", row.message or tr("panel.output.error")
  end
  return "photo-off", "on_surface_variant", tr("panel.output.no_wallpaper")
end

local drafts = {}

local function draftValue(row, field, fallback)
  local draft = drafts[row.name]
  local value = type(draft) == "table" and draft[field] or nil
  if type(value) == "number" then
    return value
  end
  return fallback or 0
end

local function setDraft(row, field, value)
  local number = tonumber(value)
  if number == nil then
    return
  end
  local draft = drafts[row.name] or {}
  draft[field] = math.floor(number + 0.5)
  drafts[row.name] = draft
end

local function clearSetOverride(row)
  drafts[row.name] = nil
  noctalia.state.set("wallpaper_depth.command", { action = "clear_override", outputName = row.name })
end

local function commitSetOverride(row)
  local draft = drafts[row.name]
  if type(draft) ~= "table" then
    return
  end
  drafts[row.name] = nil
  noctalia.state.set("wallpaper_depth.command", {
    action = "set_override",
    outputName = row.name,
    threshold = draftValue(row, "threshold", row.threshold),
    feather = draftValue(row, "feather", row.feather),
  })
end

local function setSlider(row, field, maximum, title)
  local value = draftValue(row, field, row[field])
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = title, color = "on_surface_variant", fontSize = 10, flexGrow = 1 }),
    ui.label({ text = tostring(value) .. "%", fontSize = 10, fontWeight = "bold" }),
    ui.slider({
      min = 0,
      max = maximum,
      step = 1,
      value = value,
      width = 160,
      onChange = function(changed)
        setDraft(row, field, changed)
        render()
      end,
      onDragEnd = function() commitSetOverride(row) end,
    }),
  })
end

local function setControls(row)
  if type(row.setId) ~= "string" then
    return nil
  end
  return ui.column({ gap = 6, paddingH = 10 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({
        name = "layers-subtract",
        size = 14,
        color = row.hasOverride == true and "primary" or "on_surface_variant",
      }),
      ui.label({
        text = tr("panel.set") .. ": " .. (row.setName or row.setId),
        color = "on_surface_variant",
        fontSize = 11,
        flexGrow = 1,
      }),
      ui.button({
        text = tr("panel.reset"),
        glyph = "arrow-back-up",
        variant = "ghost",
        controlSize = "sm",
        enabled = row.hasOverride == true,
        onClick = function() clearSetOverride(row) end,
      }),
    }),
    setSlider(row, "threshold", 100, tr("panel.threshold")),
    setSlider(row, "feather", 50, tr("panel.feather")),
  })
end

local function outputRow(row)
  local glyph, color, detail = outputState(row)
  local card = ui.row({
    gap = 10,
    align = "center",
    padding = 10,
    radius = 8,
    fill = "surface_container/0.35",
  }, {
    ui.glyph({ name = glyph, size = 18, color = color }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = row.name or "", fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = detail, color = color, fontSize = 11, wrap = true }),
    }),
  })
  local controls = setControls(row)
  if controls == nil then
    return card
  end
  return ui.column({ gap = 6 }, { card, controls })
end

local function anySetActive()
  for _, row in ipairs(status.outputs or {}) do
    if type(row.setId) == "string" then
      return true
    end
  end
  return false
end

local function outputRows()
  local rows = {}
  for _, row in ipairs(status.outputs or {}) do
    table.insert(rows, outputRow(row))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({
      text = tr("panel.no_outputs"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end
  return rows
end

local function setupCard()
  local state = status.setupState or "checking"
  local glyph = "loader-2"
  local color = "on_surface_variant"
  local title = tr("panel.setup.checking")
  if state == "ready" then
    glyph = "circle-check"
    color = "primary"
    title = tr("panel.setup.ready")
  elseif state == "running" then
    glyph = "download"
    color = "primary"
    title = tr("panel.setup.running")
  elseif state == "missing" then
    glyph = "package"
    title = tr("panel.setup.missing")
  elseif state == "error" then
    glyph = "alert-triangle"
    color = "error"
    title = tr("panel.setup.error")
  end

  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = glyph, size = 20, color = color }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = title, fontWeight = "bold", fontSize = 13 }),
        ui.label({
          text = status.setupMessage or "",
          color = color,
          fontSize = 11,
          wrap = true,
          visible = type(status.setupMessage) == "string" and status.setupMessage ~= "",
        }),
      }),
    }),
  }

  if state ~= "ready" then
    local prerequisites = {}
    if status.pythonAvailable ~= true then
      table.insert(prerequisites, "python3")
    end
    if #prerequisites > 0 then
      table.insert(children, ui.label({
        text = tr("panel.setup.prerequisites", { commands = table.concat(prerequisites, ", ") }),
        color = "error",
        fontSize = 11,
        wrap = true,
      }))
    end
    if status.offline == true then
      table.insert(children, ui.label({
        text = tr("panel.setup.offline"),
        color = "error",
        fontSize = 11,
        wrap = true,
      }))
    end
    table.insert(children, ui.label({
      text = tr("panel.setup.disclosure"),
      color = "on_surface_variant",
      fontSize = 11,
      wrap = true,
    }))
    table.insert(children, ui.button({
      text = state == "error" and tr("panel.setup.retry") or tr("panel.setup.install"),
      glyph = "download",
      variant = "primary",
      enabled = state ~= "running"
        and status.offline ~= true
        and status.pythonAvailable == true
        and status.busy ~= true,
      onClick = "onSetup",
    }))
  end

  return ui.column({ gap = 8, padding = 10, radius = 8, fill = "surface_container/0.35" }, children)
end

function render()
  local ready = status.setupState == "ready"
  local threshold = math.floor((status.threshold or 0) * 100 + 0.5)
  local feather = math.floor((status.feather or 0) * 100 + 0.5)

  local headerContent = {
    ui.glyph({ name = "layers-subtract", size = 20, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, {
    ui.row({ align = "center", gap = 8 }, headerContent),
    ui.label({
      text = tr("panel.description"),
      color = "on_surface_variant",
      fontSize = 12,
      wrap = true,
    }),
    setupCard(),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.parameters"), fontWeight = "bold", fontSize = 13 }),
      ui.button({ text = tr("panel.settings"), glyph = "settings", variant = "ghost", onClick = "onSettings" }),
    }),
    ui.row({ gap = 12, paddingH = 4 }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.threshold"), color = "on_surface_variant", fontSize = 11 }),
        ui.label({ text = tostring(threshold) .. "%", fontWeight = "bold", fontSize = 13 }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.feather"), color = "on_surface_variant", fontSize = 11 }),
        ui.label({ text = tostring(feather) .. "%", fontWeight = "bold", fontSize = 13 }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.automatic"), color = "on_surface_variant", fontSize = 11 }),
        ui.label({
          text = status.autoGenerate == true and tr("panel.on") or tr("panel.off"),
          fontWeight = "bold",
          fontSize = 13,
        }),
      }),
    }),
    ui.separator({}),
    ui.label({ text = tr("panel.outputs"), fontWeight = "bold", fontSize = 13 }),
    ui.label({
      text = tr("panel.set_hint"),
      color = "on_surface_variant",
      fontSize = 11,
      wrap = true,
      visible = anySetActive(),
    }),
    ui.scroll({ flexGrow = 1, gap = 6 }, outputRows()),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.generate"),
        glyph = "sparkles",
        variant = "primary",
        flexGrow = 1,
        enabled = ready and status.busy ~= true,
        onClick = "onGenerate",
      }),
      ui.button({
        text = tr("panel.clear_cache"),
        glyph = "trash",
        variant = "outline",
        enabled = status.busy ~= true,
        onClick = "onClearCache",
      }),
    }),
  }))
end

function onSetup()
  noctalia.state.set("wallpaper_depth.command", { action = "setup" })
end

function onGenerate()
  noctalia.state.set("wallpaper_depth.command", { action = "generate" })
end

function onClearCache()
  noctalia.state.set("wallpaper_depth.command", { action = "clear_cache" })
end

function onSettings()
  noctalia.openSettings()
end

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  status = noctalia.state.get("wallpaper_depth.status") or status
  render()
end

noctalia.state.watch("wallpaper_depth.status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)
