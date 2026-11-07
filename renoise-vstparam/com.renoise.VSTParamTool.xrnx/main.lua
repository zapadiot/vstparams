--[[
VST3 Parameter Tool for Renoise
Reads, writes, and saves VST3 plugin parameters via Renoise's Lua API.
Exports full parameter data to JSON for AI classification and preset adaptation.

Installation:
1. Copy this .xrnx file to ~/.config/Renoise/V3.5.4/Scripts/Tools/
2. Start Renoise
3. Access via Tools menu: "VST3 Parameter Tool"

Output files:
- /tmp/opencode/vst3_params.json     Full parameter dump (JSON)
- /tmp/opencode/vst3_params_summary.txt Human-readable summary
--]]

local JSON_FILE = "/tmp/opencode/vst3_params.json"
local SUMMARY_FILE = "/tmp/opencode/vst3_params_summary.txt"

-- -----------------------------------------------------------------------------
-- show_prompt wrapper (Renoise requires a buttons table as 4th arg)
-- -----------------------------------------------------------------------------
local function show_prompt(title, message, buttons)
  local btns = buttons or {"OK"}
  renoise.app():show_prompt(title, message, btns)
end

-- -----------------------------------------------------------------------------
-- JSON encoding helper (minimal, no external library needed)
-- -----------------------------------------------------------------------------
local function json_escape(s)
  if type(s) == "string" then
    return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
  elseif type(s) == "number" then
    return tostring(s)
  elseif type(s) == "boolean" then
    return s and "true" or "false"
  elseif type(s) == "nil" then
    return "null"
  end
  return '""'
end

local function json_encode(t)
  if type(t) ~= "table" then return json_escape(t) end
  local is_array = true
  local max_index = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" then is_array = false end
    if type(k) == "number" and k > max_index then max_index = k end
  end
  if is_array and max_index > 0 then
    local parts = {}
    for i = 1, max_index do
      table.insert(parts, json_encode(t[i]))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  else
    local parts = {}
    for k, v in pairs(t) do
      if type(k) == "string" then
        table.insert(parts, json_escape(k) .. ":" .. json_encode(v))
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
end

-- -----------------------------------------------------------------------------
-- Get all available VST3/AudioUnit device paths
-- -----------------------------------------------------------------------------
local function get_available_devices()
  local song = renoise.song()
  local tracks = song.tracks
  local devices = {}
  if #tracks > 0 then
    local avail = tracks[1].available_devices
    for _, path in ipairs(avail) do
      table.insert(devices, path)
    end
  end
  return devices
end

-- -----------------------------------------------------------------------------
-- Insert a device by path into track 1
-- -----------------------------------------------------------------------------
local function insert_device(device_path)
  local song = renoise.song()
  local track = song.tracks[1]
  return track:insert_device_at(device_path, 1)
end

-- -----------------------------------------------------------------------------
-- Export full parameter data to JSON
-- -----------------------------------------------------------------------------
local function export_parameters_json(device, filepath)
  local params = device.parameters
  local data = {
    plugin_name = device.name,
    device_path = tostring(device.device_path),
    is_active = device.is_active,
    parameter_count = #params,
    presets = device.presets,
    active_preset = device.active_preset,
    parameters = {}
  }

  for i, param in ipairs(params) do
    table.insert(data.parameters, {
      index = i,
      name = param.name,
      value = param.value,
      value_min = param.value_min,
      value_max = param.value_max,
      value_default = param.value_default,
      value_quantum = param.value_quantum,
      is_automatable = param.is_automatable,
      polarity = tostring(param.polarity),
      value_string = tostring(param.value_string)
    })
  end

  local f = io.open(filepath, "w")
  if f then
    f:write(json_encode(data))
    f:close()
    return true
  end
  return false
end

-- -----------------------------------------------------------------------------
-- Human-readable summary
-- -----------------------------------------------------------------------------
local function export_summary(device, filepath)
  local params = device.parameters
  local lines = {}
  table.insert(lines, string.format("=== Device: %s ===", device.name))
  table.insert(lines, string.format("  Path: %s", tostring(device.device_path)))
  table.insert(lines, string.format("  Parameters: %d", #params))
  table.insert(lines, string.format("  Presets: %s", table.concat(device.presets, ", ")))
  table.insert(lines, string.format("  Active preset: %d", device.active_preset))
  table.insert(lines, "")
  table.insert(lines, string.format("%-5s %-40s %-10s %-12s %-12s %-12s %-10s %-10s",
    "Idx", "Name", "Value", "Min", "Max", "Default", "Quantum", "Auto?"))
  table.insert(lines, string.rep("-", 115))

  for i, param in ipairs(params) do
    local auto_str = param.is_automatable and "yes" or "no"
    table.insert(lines, string.format("%-5d %-40s %-10.6f %-12.6f %-12.6f %-12.6f %-10.6f %-10s",
      i, param.name:sub(1, 38), param.value, param.value_min,
      param.value_max, param.value_default, param.value_quantum, auto_str))
  end

  local f = io.open(filepath, "w")
  if f then
    f:write(table.concat(lines, "\n"))
    f:close()
  end
end

-- -----------------------------------------------------------------------------
-- Apply parameters from a mapping table
-- mapping = { {name="Filter Cutoff", value=0.7}, ... }
-- -----------------------------------------------------------------------------
local function apply_parameters(device, mapping)
  local params = device.parameters
  local applied = 0
  local results = {}

  for _, entry in ipairs(mapping) do
    local target_name = entry.name
    local target_value = entry.value

    -- Try exact match first, then fuzzy match
    local found = false
    for i, param in ipairs(params) do
      if param.name == target_name then
        param.value = math.max(param.value_min, math.min(param.value_max, target_value))
        applied = applied + 1
        table.insert(results, string.format("  [OK] %s = %.4f", param.name, param.value))
        found = true
        break
      end
    end

    if not found then
      -- Fuzzy match: check if target_name is contained in param.name or vice versa
      for i, param in ipairs(params) do
        if param.name:lower():find(target_name:lower(), 1, true)
           or target_name:lower():find(param.name:lower(), 1, true) then
          param.value = math.max(param.value_min, math.min(param.value_max, target_value))
          applied = applied + 1
          table.insert(results, string.format("  [OK] %s = %.4f (matched '%s')",
            param.name, param.value, target_name))
          found = true
          break
        end
      end
    end

    if not found then
      table.insert(results, string.format("  [MISS] %s = %.4f (no matching parameter)",
        target_name, target_value))
    end
  end

  return applied, results
end

-- -----------------------------------------------------------------------------
-- Get the currently selected device from the song
-- -----------------------------------------------------------------------------
local function get_selected_device()
  local song = renoise.song()
  local track = song.selected_track
  if not track or #track.devices == 0 then
    return nil
  end
  local idx = song.selected_device_index
  if idx and idx >= 1 and idx <= #track.devices then
    return track.devices[idx]
  end
  return nil
end

-- -----------------------------------------------------------------------------
-- Menu Actions
-- -----------------------------------------------------------------------------

local function list_and_dump_devices()
  local devices = get_available_devices()
  if #devices == 0 then
    show_prompt("No Devices",
      "No VST3/AudioUnit devices found.\nScan plugins in Preferences > Plug-ins.")
    return
  end

  local lines = {}
  table.insert(lines, "=== Available VST3 / AudioUnit Devices ===")
  for i, path in ipairs(devices) do
    table.insert(lines, string.format("  [%d] %s", i, path))
  end
  table.insert(lines, "")

  local first_path = devices[1]
  local ok, device = pcall(insert_device, first_path)

  if not ok or not device then
    table.insert(lines, string.format("  ERROR inserting %s: %s", first_path, tostring(device)))
  else
    table.insert(lines, string.format("=== Parameters of: %s ===", device.name))
    -- Export JSON
    export_parameters_json(device, JSON_FILE)
    -- Export summary
    export_summary(device, SUMMARY_FILE)
    table.insert(lines, string.format("Exported %d parameters to %s", #device.parameters, JSON_FILE))
    table.insert(lines, string.format("Summary written to %s", SUMMARY_FILE))
  end

  local output = table.concat(lines, "\n")
  local display = output:sub(1, 2500)
  if #output > 2500 then display = display .. "\n... (see " .. SUMMARY_FILE .. ")" end
  show_prompt("VST3 Devices", display)
end

local function dump_selected_device()
  local device = get_selected_device()
  if not device then
    show_prompt("No Device",
      "No device selected. Select a device in the device chain first.")
    return
  end

  export_parameters_json(device, JSON_FILE)
  export_summary(device, SUMMARY_FILE)

  local dump = ""
  dump = dump .. string.format("=== Device: %s ===\n", device.name)
  dump = dump .. string.format("Parameters: %d\n", #device.parameters)
  dump = dump .. string.format("Exported to %s\n", JSON_FILE)

  show_prompt("Device: " .. device.name, dump)
end

-- Apply a preset mapping from JSON file
-- File format: { [{"name": "Param Name", "value": 0.5}, ...] }
local function apply_preset_from_json(filepath)
  local device = get_selected_device()
  if not device then
    show_prompt("No Device", "No device selected.")
    return
  end

  local f = io.open(filepath, "r")
  if not f then
    show_prompt("Error", "Cannot open file: " .. filepath)
    return
  end
  local content = f:read("*all")
  f:close()

  -- Simple JSON array parser for our format
  -- We expect: [{"name":"...","value":0.5}, ...]
  local mapping = {}
  -- Very basic parsing - split by },{
  local entries = {}
  for entry in content:gmatch("%b{}") do
    local name = entry:match('"name"%s*:%s*"([^"]*)"')
    local value = tonumber(entry:match('"value"%s*:%s*([%d%.]+)'))
    if name and value then
      table.insert(entries, {name = name, value = value})
    end
  end

  local applied, results = apply_parameters(device, entries)
  local msg = string.format("Applied %d/%d parameters:\n", applied, #entries)
  for i = 1, math.min(#results, 30) do
    msg = msg .. results[i] .. "\n"
  end
  if #results > 30 then msg = msg .. "...\n" end
  show_prompt("Apply Preset Result", msg)
end

-- -----------------------------------------------------------------------------
-- Tool Menu Registration
-- -----------------------------------------------------------------------------

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:VST3 Parameter Tool:List Devices & Export JSON",
  invoke = list_and_dump_devices
}

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:VST3 Parameter Tool:Dump Selected Device",
  invoke = dump_selected_device
}

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:VST3 Parameter Tool:Apply Preset from JSON",
  invoke = function()
    local path = renoise.app():prompt_for_filename_to_read("json", "Select preset JSON")
    if path then apply_preset_from_json(path) end
  end
}

print("=== VST3 Parameter Tool loaded ===")
print("Access via: Tools > VST3 Parameter Tool")
print("JSON output: " .. JSON_FILE)
print("Summary output: " .. SUMMARY_FILE)
