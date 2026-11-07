--[[
VST3 Parameter Console Script for Renoise
=========================================

Run this script in Renoise's Lua scripting console (Scripting > Show Console)
to programmatically read/write VST3 plugin parameters.

Usage examples in the console:

  -- List all available VST3 device paths
  vst3.list_devices()

  -- Insert a plugin into track 1 and select it
  vst3.insert("Discovery")

  -- Dump all parameters of the selected device
  vst3.dump()

  -- Set parameter by index (1-based) to a normalized value 0-1
  vst3.set(5, 0.7)

  -- Set parameter by name substring
  vst3.set_by_name("Cutoff", 0.8)
  vst3.set_by_name("Resonance", 0.6)

  -- Save current device state as a preset file
  vst3.save_preset("/tmp/opencode/mypad.xml")

  -- Load a preset from file
  vst3.load_preset("/tmp/opencode/mypad.xml")

--]]

local vst3 = {}
local OUTPUT = "/tmp/opencode/vst3_params_dump.txt"

-- Helper: find device path containing substring
local function find_device_path(substr)
  local song = renoise.song()
  if #song.tracks == 0 then return nil end
  for _, path in ipairs(song.tracks[1].available_devices) do
    if path:lower():find(substr:lower(), 1, true) then
      return path
    end
  end
  return nil
end

-- List available devices
function vst3.list_devices()
  local song = renoise.song()
  local avail = song.tracks[1].available_devices
  print("=== Available VST3/AudioUnit Devices ===")
  for i, path in ipairs(avail) do
    print(string.format("  [%d] %s", i, path))
  end
  print(string.format("Total: %d devices", #avail))
end

-- Insert device by name substring into track 1
function vst3.insert(substr)
  local path = find_device_path(substr)
  if not path then
    print("Device not found: " .. substr)
    vst3.list_devices()
    return nil
  end
  local song = renoise.song()
  local device = song.tracks[1]:insert_device_at(path, 1)
  print("Inserted: " .. device.name .. " (" .. path .. ")")
  return device
end

-- Dump parameters of selected device
function vst3.dump()
  local device = renoise.device()
  if not device then
    print("No device selected. Click a device in the device chain first.")
    return
  end

  local params = device.parameters
  print(string.format("=== Device: %s ===", device.name))
  print(string.format("  Parameters: %d", #params))
  print(string.format("%-5s %-35s %-10s %-10s %-10s %-10s %-8s %-8s",
    "Idx", "Name", "Value", "Min", "Max", "Default", "Quantum", "Auto"))
  print(string.rep("-", 100))

  local lines = {}
  table.insert(lines, string.format("=== Device: %s ===", device.name))
  table.insert(lines, string.format("  Parameters: %d", #params))

  for i, param in ipairs(params) do
    local auto = param.is_automatable and "yes" or "no"
    print(string.format("%-5d %-35s %-10.6f %-10.6f %-10.6f %-10.6f %-8.6f %-8s",
      i, param.name:sub(1, 33), param.value, param.value_min,
      param.value_max, param.value_default, param.value_quantum, auto))
    table.insert(lines, string.format("%-5d %-35s %-10.6f %-10.6f %-10.6f %-10.6f %-8.6f %-8s",
      i, param.name, param.value, param.value_min, param.value_max,
      param.value_default, param.value_quantum, auto))
  end

  local f = io.open(OUTPUT, "w")
  if f then
    f:write(table.concat(lines, "\n"))
    f:close()
    print(string.format("\nOutput saved to %s", OUTPUT))
  end
end

-- Set parameter by index (1-based)
function vst3.set(index, value)
  local device = renoise.device()
  if not device then
    print("No device selected.")
    return
  end
  local params = device.parameters
  if index < 1 or index > #params then
    print("Invalid index. Range: 1-" .. #params)
    return
  end
  local param = params[index]
  value = math.max(param.value_min, math.min(param.value_max, value))
  param.value = value
  print(string.format("Set [%d] %s = %.6f", index, param.name, value))
end

-- Set parameter by name substring
function vst3.set_by_name(substr, value)
  local device = renoise.device()
  if not device then
    print("No device selected.")
    return
  end
  for i, param in ipairs(device.parameters) do
    if param.name:lower():find(substr:lower(), 1, true) then
      value = math.max(param.value_min, math.min(param.value_max, value))
      param.value = value
      print(string.format("Set [%d] %s = %.6f", i, param.name, value))
      return
    end
  end
  print("Parameter not found: " .. substr)
end

-- Save preset
function vst3.save_preset(filepath)
  local device = renoise.device()
  if not device then
    print("No device selected.")
    return
  end
  local data = device.active_preset_data
  if not data or data == "" then
    print("No preset data available.")
    return
  end
  local f = io.open(filepath, "w")
  if not f then
    print("Cannot write: " .. filepath)
    return
  end
  f:write(data)
  f:close()
  print(string.format("Preset saved: %s", filepath))
end

-- Load preset
function vst3.load_preset(filepath)
  local device = renoise.device()
  if not device then
    print("No device selected.")
    return
  end
  local f = io.open(filepath, "r")
  if not f then
    print("Cannot read: " .. filepath)
    return
  end
  local data = f:read("*all")
  f:close()
  device.active_preset_data = data
  print(string.format("Preset loaded: %s", filepath))
end

-- Show currently selected device's parameter names (quick list)
function vst3.names()
  local device = renoise.device()
  if not device then
    print("No device selected.")
    return
  end
  print(string.format("=== Parameters of: %s (%d total) ===", device.name, #device.parameters))
  for i, param in ipairs(device.parameters) do
    print(string.format("  [%d] %s (%.4f / range: %.4f-%.4f)", i, param.name, param.value, param.value_min, param.value_max))
  end
end

print("vst3 module loaded. Use vst3.list_devices(), vst3.insert('Name'), vst3.dump(), etc.")
