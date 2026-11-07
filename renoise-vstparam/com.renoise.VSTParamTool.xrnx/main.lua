--[[
VST3 Parameter Tool for Renoise
Reads, writes, and saves VST3 plugin parameters via Renoise's Lua API.
Exports full parameter data to JSON for AI classification and preset adaptation.

Installation:
1. Copy com.renoise.VSTParamTool.xrnx/ to ~/.config/Renoise/V3.5.4/Scripts/Tools/
2. Start (or restart) Renoise
3. Access via Tools menu: "VST3 Parameter Tool"

Output files:
- /tmp/opencode/vst3_params.json     Full parameter dump (JSON, all devices)
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
-- Collect ALL devices from ALL tracks AND instruments
-- -----------------------------------------------------------------------------
local function collect_all_devices()
  local song = renoise.song()
  local all_devices = {}

  -- Regular tracks
  for t_idx, track in ipairs(song.tracks) do
    for d_idx, device in ipairs(track.devices) do
      table.insert(all_devices, {
        track_index = t_idx,
        track_name = track.name,
        device_index = d_idx,
        device = device,
        device_name = device.name,
        device_path = tostring(device.device_path),
        is_active = device.is_active,
        parameter_count = #device.parameters,
        is_instrument = false,
        instrument_index = nil,
        chain_index = nil,
      })
    end
  end

  -- Send tracks
  for s_idx, track in ipairs(song.send_tracks) do
    for d_idx, device in ipairs(track.devices) do
      table.insert(all_devices, {
        track_index = -s_idx,
        track_name = "Send " .. s_idx,
        device_index = d_idx,
        device = device,
        device_name = device.name,
        device_path = tostring(device.device_path),
        is_active = device.is_active,
        parameter_count = #device.parameters,
        is_instrument = false,
        instrument_index = nil,
        chain_index = nil,
      })
    end
  end

  -- Master track
  local master = song.master_track
  if master then
    for d_idx, device in ipairs(master.devices) do
      table.insert(all_devices, {
        track_index = 0,
        track_name = "Master",
        device_index = d_idx,
        device = device,
        device_name = device.name,
        device_path = tostring(device.device_path),
        is_active = device.is_active,
        parameter_count = #device.parameters,
        is_instrument = false,
        instrument_index = nil,
        chain_index = nil,
      })
    end
  end

  -- Instruments (their sample device chains)
  for i_idx, instrument in ipairs(song.instruments) do
    local chains = instrument.sample_device_chains
    if chains and #chains > 0 then
      for c_idx = 1, #chains do
        local chain = instrument:sample_device_chain(c_idx)
        if chain and #chain.devices > 0 then
          for d_idx, device in ipairs(chain.devices) do
            table.insert(all_devices, {
              track_index = -1000 - i_idx,
              track_name = "Instrument: " .. instrument.name .. " (chain " .. c_idx .. ")",
              device_index = d_idx,
              device = device,
              device_name = device.name,
              device_path = tostring(device.device_path),
              is_active = device.is_active,
              parameter_count = #device.parameters,
              is_instrument = true,
              instrument_index = i_idx,
              chain_index = c_idx,
            })
          end
        end
      end
    end
  end

  return all_devices
end

-- -----------------------------------------------------------------------------
-- Get the currently selected device (track OR instrument)
-- Returns: {device = renoise.AudioDevice, context = "track"|"instrument",
--           track_index, track_name, instrument_index, chain_index}
-- -----------------------------------------------------------------------------
local function get_selected_device()
  local song = renoise.song()

  -- Try track device first
  local track = song.selected_track
  if track and #track.devices > 0 then
    local idx = song.selected_device_index
    if idx and idx >= 1 and idx <= #track.devices then
      return {
        device = track.devices[idx],
        context = "track",
        track_index = song.selected_track_index,
        track_name = track.name,
        instrument_index = nil,
        chain_index = nil,
      }
    end
  end

  -- Try instrument device chain
  local instrument = song.selected_instrument
  if instrument then
    local chains = instrument.sample_device_chains
    if chains and #chains > 0 then
      local chain_idx = song.selected_sample_device_chain_index
      if not chain_idx or chain_idx < 1 or chain_idx > #chains then
        chain_idx = 1
      end
      local chain = instrument:sample_device_chain(chain_idx)
      if chain and #chain.devices > 0 then
        -- Try selected_device_index on instrument chain too
        local idx = song.selected_device_index
        local dev_idx = (idx and idx >= 1 and idx <= #chain.devices) and idx or 1
        return {
          device = chain.devices[dev_idx],
          context = "instrument",
          track_index = nil,
          track_name = "Instrument: " .. instrument.name,
          instrument_index = song.selected_instrument_index,
          chain_index = chain_idx,
        }
      end
    end
  end

  return nil
end

-- -----------------------------------------------------------------------------
-- Export full parameter data for a single device to JSON
-- -----------------------------------------------------------------------------
local function export_device_json(device, filepath)
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
-- Export ALL devices to a single JSON file
-- -----------------------------------------------------------------------------
local function export_all_devices_json(all_devices, filepath)
  local data = {
    total_devices = #all_devices,
    devices = {}
  }

  for _, entry in ipairs(all_devices) do
    local device = entry.device
    local params = device.parameters
    local dev_data = {
      track_index = entry.track_index,
      track_name = entry.track_name,
      device_index = entry.device_index,
      device_name = entry.device_name,
      device_path = entry.device_path,
      is_active = entry.is_active,
      parameter_count = entry.parameter_count,
      presets = device.presets,
      active_preset = device.active_preset,
      parameters = {}
    }

    for i, param in ipairs(params) do
      table.insert(dev_data.parameters, {
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

    table.insert(data.devices, dev_data)
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
-- Human-readable summary for a single device
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
    table.insert(lines, string.format("%-5d %-40s %-10.6f %-12.6f %-12s %-12s %-10.6f %-10s",
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
-- Apply parameters from a mapping table to a device
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
      -- Fuzzy match
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
-- Menu Actions
-- -----------------------------------------------------------------------------

-- Dump ALL devices from ALL tracks AND instruments to JSON
local function dump_all_devices()
  local all_devices = collect_all_devices()

  if #all_devices == 0 then
    show_prompt("No Devices",
      "No devices found in any track or instrument.\nLoad some VST3 plugins first.")
    return
  end

  -- Export all devices to JSON
  export_all_devices_json(all_devices, JSON_FILE)

  -- Build summary text
  local lines = {}
  table.insert(lines, string.format("=== All Devices (%d total) ===", #all_devices))
  table.insert(lines, "")
  for _, entry in ipairs(all_devices) do
    local ctx = entry.is_instrument and "INSTRUMENT" or "TRACK"
    table.insert(lines, string.format("  [%s] Track[%d] %-20s | Dev[%d] %-30s | %d params",
      ctx, entry.track_index, entry.track_name, entry.device_index,
      entry.device_name, entry.parameter_count))
  end
  table.insert(lines, "")
  table.insert(lines, "Exported to: " .. JSON_FILE)
  table.insert(lines, "")
  table.insert(lines, "Classify preset type with the Python pipeline:")
  table.insert(lines, "  python3 vst3_preset_pipeline.py --input " .. JSON_FILE .. " --classify --search --suggest")

  local output = table.concat(lines, "\n")
  local display = output:sub(1, 3000)
  if #output > 3000 then display = display .. "\n... (see " .. JSON_FILE .. ")" end
  show_prompt("All Devices Dumped", display)
end

-- Dump the currently selected device (track or instrument)
local function dump_selected_device()
  local result = get_selected_device()
  if not result then
    show_prompt("No Device",
      "No device selected.\nClick on a device in any track or instrument device chain first.")
    return
  end

  local device = result.device
  export_device_json(device, JSON_FILE)
  export_summary(device, SUMMARY_FILE)

  local dump = string.format("=== Device: %s ===\n", device.name)
  dump = dump .. string.format("Context: %s\n", result.context)
  if result.track_name then
    dump = dump .. string.format("Track: %s\n", result.track_name)
  end
  dump = dump .. string.format("Parameters: %d\n", #device.parameters)
  dump = dump .. string.format("Exported to %s\n", JSON_FILE)

  show_prompt("Device: " .. device.name, dump)
end

-- Apply a preset mapping from JSON file to the selected device
local function apply_preset_from_json(filepath)
  local result = get_selected_device()
  if not result then
    show_prompt("No Device", "No device selected.")
    return
  end

  local device = result.device

  local f = io.open(filepath, "r")
  if not f then
    show_prompt("Error", "Cannot open file: " .. filepath)
    return
  end
  local content = f:read("*all")
  f:close()

  local entries = {}
  for entry in content:gmatch("%b{}") do
    local name = entry:match('"name"%s*:%s*"([^"]*)"')
    local value = tonumber(entry:match('"value"%s*:%s*([%d%.]+)'))
    if name and value then
      table.insert(entries, {name = name, value = value})
    end
  end

  local applied, results = apply_parameters(device, entries)
  local msg = string.format("Applied %d/%d parameters to '%s':\n",
    applied, #entries, device.name)
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
  name = "Main Menu:Tools:VST3 Parameter Tool:Dump All Devices (All Tracks + Instruments)",
  invoke = dump_all_devices
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
