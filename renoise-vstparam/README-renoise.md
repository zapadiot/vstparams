# VST3 Preset Pipeline — Renoise + LLM + Web Search

Complete system for automatically classifying VST3 presets (pad/lead/drum/bass/etc.),
searching the web for parameter settings, and adapting them to any VST3 plugin.

## Architecture

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│   Renoise DAW   │─────▶│  Parameter JSON  │─────▶│  Python Pipeline │
│  (VST3 host)    │      │  (all params)    │      │  (classify+search)│
└─────────────────┘      └──────────────────┘      └─────────────────┘
                                                          │
                                                          ▼
                                                  ┌─────────────────┐
                                                  │  Preset JSON    │
                                                  │ (adapted values)│
                                                  └─────────────────┘
                                                          │
                                                          ▼
                                                  ┌─────────────────┐
                                                  │   Renoise DAW   │
                                                  │ (apply params)  │
                                                  └─────────────────┘
```

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Renoise Lua tool | `com.renoise.VSTParamTool.xrnx/` | Exports VST3 parameters to JSON, applies presets |
| Pipeline script | `vst3_preset_pipeline.py` | Classifies preset type, searches web, suggests params |
| Console script | `vst3_param_console.lua` | Programmatic control from Renoise console |
| Runner script | `run_pipeline.sh` | End-to-end convenience script |

## Installation

### 1. Install Renoise tool

```bash
cp /tmp/opencode/renoise-vstparam/com.renoise.VSTParamTool.xrnx/VSTParamTool.xrnx \
   ~/.config/Renoise/V3.5.4/Scripts/Tools/
```

### 2. Start Renoise

```bash
renoise &
```

Renoise scans `~/.vst3/` and supports:
- **Native VST3** (Discovery, TAL, Retromulator, etc.)
- **u-he plugins** (Diva, Repro, Zebra, Hive, Bazille, ACE)
- **vstbridge plugins** (Roland D-50, JD-800, JUPITER-8, etc. via Wine)

## Workflow

### Option A: Manual step-by-step

```bash
# 1. Start Renoise
renoise &

# 2. In Renoise:
#    - Load your VST3 plugin into a track
#    - Tools > VST3 Parameter Tool > Dump Selected Device
#    - This exports parameters to /tmp/opencode/vst3_params.json

# 3. Run the pipeline
python3 vst3_preset_pipeline.py \
    --input /tmp/opencode/vst3_params.json \
    --classify --search --suggest \
    --output /tmp/opencode/my_preset.json

# 4. Apply back in Renoise:
#    - Select the plugin device
#    - Tools > VST3 Parameter Tool > Apply Preset from JSON
#    - Select your preset JSON
```

### Option B: Using the runner script

```bash
./run_pipeline.sh discovery pad
./run_pipeline.sh tal-eq lead
./run_pipeline.sh custom /path/to/plugin.vst3 bass
```

## What the pipeline does

1. **Read** — Loads parameter JSON exported from Renoise (names, values, ranges, defaults)
2. **Classify** — Asks an LLM (Ollama) what preset type this is: pad, lead, bass, drum, arp, fx, pluck, keys, ambient, other
   - Falls back to heuristic classification if Ollama is unavailable
3. **Search** — Searches the web for preset settings for this plugin + preset type
4. **Suggest** — Asks the LLM to map generic settings to this plugin's specific parameters
   - Falls back to heuristic suggestions (pad=slow attack/release, lead=bright filter, etc.)
5. **Output** — Generates a preset JSON with `{name, value, reason}` for each parameter

## Output preset JSON format

```json
{
  "plugin": "Discovery",
  "device_path": "discoDSP/Discovery",
  "preset_type": "pad",
  "parameters": [
    {"name": "A:Amp_Attack", "value": 0.8, "reason": "Slow attack for pad"},
    {"name": "A:Amp_Release", "value": 0.8, "reason": "Long release for pad"},
    {"name": "A:Fil_Freq", "value": 0.35, "reason": "Darker filter for pad"}
  ]
}
```

## Renoise Lua API reference

| Property | Description |
|----------|-------------|
| `device.name` | Plugin name |
| `device.parameters[]` | All automatable parameters |
| `device.device_path` | Unique path for re-insertion |
| `device.presets[]` | Available preset names |
| `device.active_preset_data` | XML preset data (read/write) |
| `param.name` / `param.value` | Parameter name and value |
| `param.value_min` / `param.value_max` | Valid range |
| `param.is_automatable` | Whether parameter can be automated |

## Console script (`vst3_param_console.lua`)

Paste into Renoise's Scripting Console for programmatic control:

```lua
vst3.list_devices()           -- list all available VST3 device paths
vst3.insert("Discovery")      -- load Discovery into track 1
vst3.dump()                   -- dump all parameters to file
vst3.names()                  -- quick parameter name list
vst3.set(5, 0.7)              -- set parameter index 5 to 0.7
vst3.set_by_name("Cutoff", 0.8) -- set by name substring
vst3.save_preset("/tmp/pad.xml") -- save native preset
vst3.load_preset("/tmp/pad.xml") -- load native preset
```

## Example: Creating a Pad on Discovery

```lua
-- In Renoise console:
vst3.insert("Discovery")
vst3.set_by_name("A:Amp_Attack", 0.8)     -- slow fade-in
vst3.set_by_name("A:Amp_Sustain", 0.9)     -- sustained
vst3.set_by_name("A:Amp_Release", 0.8)     -- long tail
vst3.set_by_name("A:Fil_Freq", 0.35)       -- darker filter
vst3.save_preset("/tmp/opencode/discovery_pad.xml")
```

## Example: Creating a Lead

```lua
vst3.set_by_name("A:Amp_Attack", 0.1)      -- fast attack
vst3.set_by_name("A:Amp_Release", 0.2)     -- short release
vst3.set_by_name("A:Fil_Freq", 0.8)        -- bright filter
vst3.set_by_name("A:Fil_Resonance", 0.6)   -- squelch
vst3.save_preset("/tmp/opencode/discovery_lead.xml")
```

## Ollama integration

The pipeline uses Ollama at `http://69.57.210.224:11434` with model `qwen2.5-coder:7b`.
If Ollama is unavailable, heuristic classification and suggestions are used as fallback.

## Files

```
/tmp/opencode/renoise-vstparam/
├── VSTParamTool.xrnx              # Installable Renoise tool
├── com.renoise.VSTParamTool.xrnx/
│   ├── manifest.xml
│   └── Main.lua                   # Exports JSON, applies presets
├── vst3_preset_pipeline.py        # Python orchestration pipeline
├── vst3_param_console.lua         # Renoise console script
├── run_pipeline.sh                # End-to-end runner
├── test_discovery.json            # Test input
├── README.md                      # This file
└── USAGE.md                       # Detailed usage
```
