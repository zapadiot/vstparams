# Using Renoise to Parse VST3 Parameters

Renoise 3.5.4 is installed at `/usr/local/bin/renoise` and has a complete Lua API for VST3 device parameter access. This works with plugins that the standalone C++ `vstparam` tool cannot load (u-he Diva, vstbridge plugins, etc.).

## What's Installed

| Item | Location |
|------|----------|
| Renoise binary | `/usr/local/bin/renoise` |
| Renoise config | `/home/baboon/.config/Renoise/V3.5.4/` |
| VST3 Parameter Tool (xrnx) | `/home/baboon/.config/Renoise/V3.5.4/Scripts/Tools/VSTParamTool.xrnx` |
| Tool source | `/tmp/opencode/renoise-vstparam/com.renoise.VSTParamTool.xrnx/` |
| Console script | `/tmp/opencode/renoise-vstparam/vst3_param_console.lua` |

## Method 1: Renoise GUI Menu Tool

1. Start Renoise:
   ```bash
   renoise &
   ```

2. In Renoise, go to **Tools → VST3 Parameter Tool**:
   - **"List Devices & Dump First"** — scans all available VST3/AudioUnit devices, inserts the first one into Track 1, and dumps all parameters
   - **"Dump Selected Device"** — dumps all parameters of the currently selected device (click a device in the device chain first)

3. Output is written to `/tmp/opencode/vst3_params_dump.txt` and shown in a popup

## Method 2: Lua Scripting Console

1. In Renoise, go to **Scripting → Show Console**
2. Paste the contents of `/tmp/opencode/renoise-vstparam/vst3_param_console.lua`
3. Use the `vst3` module:

```lua
vst3.list_devices()           -- list all available VST3 device paths
vst3.insert("Discovery")      -- insert plugin by name substring into track 1
vst3.dump()                   -- dump all parameters of selected device
vst3.names()                  -- quick list of parameter names
vst3.set(5, 0.7)              -- set parameter index 5 to 0.7 (0-1 range)
vst3.set_by_name("Cutoff", 0.8) -- set parameter by name substring
vst3.save_preset("/tmp/pad.xml") -- save current device state as preset
vst3.load_preset("/tmp/pad.xml") -- load preset from file
```

## Example: Creating a Pad Sound with Discovery

```lua
-- In Renoise console:
vst3.insert("Discovery")       -- load Discovery into track 1
vst3.dump()                    -- see all 2346 parameters

-- Pad settings (slow attack, long release, darker filter)
vst3.set_by_name("A:Amp_Attack", 0.8)
vst3.set_by_name("A:Amp_Decay",  0.4)
vst3.set_by_name("A:Amp_Sustain", 0.9)
vst3.set_by_name("A:Amp_Release", 0.8)
vst3.set_by_name("A:Fil_Freq",    0.35)
vst3.set_by_name("A:Fil_Resonance", 0.2)

-- Save the pad preset
vst3.save_preset("/tmp/opencode/discovery_pad.xml")
```

## Example: Creating a Lead Sound

```lua
vst3.set_by_name("A:Amp_Attack", 0.1)     -- fast attack
vst3.set_by_name("A:Amp_Decay",  0.3)
vst3.set_by_name("A:Amp_Sustain", 0.7)
vst3.set_by_name("A:Amp_Release", 0.2)    -- short release
vst3.set_by_name("A:Fil_Freq",    0.8)    -- bright filter
vst3.set_by_name("A:Fil_Resonance", 0.6)  -- squelch

vst3.save_preset("/tmp/opencode/discovery_lead.xml")
```

## Loading Presets Back

```lua
vst3.insert("Discovery")
vst3.load_preset("/tmp/opencode/discovery_pad.xml")
```

## Renoise's VST3 Device Parameter API

| Property | Description |
|----------|-------------|
| `device.name` | Plugin name |
| `device.parameters[]` | Array of all parameters |
| `device.device_path` | Unique device path (for re-insertion) |
| `device.presets[]` | Available preset names |
| `device.active_preset` | Currently active preset index |
| `device.active_preset_data` | XML preset data (read/write) |
| `param.name` | Parameter name |
| `param.value` | Current value (read/write) |
| `param.value_min` / `param.value_max` | Valid range |
| `param.value_default` | Default value |
| `param.value_quantum` | Step size |
| `param.is_automatable` | Whether automatable |

## Why Renoise over the C++ vstparam tool

| Feature | C++ vstparam | Renoise Lua |
|---------|-------------|-------------|
| Native VST3 plugins | ✅ | ✅ |
| u-he plugins (Diva, etc.) | ❌ (0 automatable params) | ✅ |
| vstbridge plugins (Roland, etc.) | ❌ (crashes headless) | ✅ (via Wine bridge) |
| Parameter read | ✅ | ✅ |
| Parameter write | ✅ | ✅ |
| Preset save/load | ✅ (text snapshot) | ✅ (native XML presets) |
| GUI plugin editor | ❌ | ✅ |
| Headless operation | ✅ | ❌ (needs X11) |

## Notes

- Renoise requires an X11/Wayland display (DISPLAY=:0 is set)
- Renoise takes ~1-2 minutes to start
- vstbridge plugins need Wine + D-Bus (already configured via `vstbridgectl sync`)
- Plugin presets saved in Renoise are `.xrni` instrument files or device-specific XML

## Files in this project

```
/tmp/opencode/renoise-vstparam/
├── VSTParamTool.xrnx          # Installable Renoise tool
├── com.renoise.VSTParamTool.xrnx/
│   ├── manifest.xml           # Tool manifest
│   └── Main.lua               # Main tool script
├── vst3_param_console.lua     # Console script for programmatic use
├── README.md                  # Tool documentation
└── USAGE.md                   # This file
```
