# vstparam — VST3 parameter reader / writer + preset tool

A minimal VST3 host (single C++ file) built against the Steinberg VST3 SDK that loads a `.vst3` plugin, connects its component ↔ controller, and lets you:

- **dump** — list all controller parameters (index, paramID, title, default/plain value, step count, units, flags)
- **find** — filter parameters by title substring
- **set** — set any parameter by normalized value `0.0–1.0`
- **save** — snapshot *all* parameter values to a text preset file
- **load** — restore parameter values from a preset file

Useful for sound design (e.g. shaping a **pad** vs a **lead** by setting Amp envelope, filter cutoff/resonance, oscillator mix, …) and for saving the resulting parameter state as a preset you can reload later.

## Build

```bash
g++ -std=c++17 -O2 -Wall -Wextra -I /path/to/vst3sdk vstparam.cpp -o vstparam -ldl
```

Example (SDK at `~/vst3sdk`):

```bash
g++ -std=c++17 -O2 -Wall -Wextra -I ~/vst3sdk vstparam.cpp -o vstparam -ldl
```

## Usage

```bash
./vstparam dump   [path]            # list all controller parameters
./vstparam find   [path] <substring>   # filter params by title
./vstparam set    [path] <paramID> <0..1>   # set a parameter (hex 0x.. or decimal)
./vstparam save   [path] <preset.txt>   # snapshot all params to a text file
./vstparam load   [path] <preset.txt>   # restore params from a text file
```

Default path is `~/.vst3/Discovery.vst3`.

## Example

```bash
# Shape a pad on Discovery (slow attack, long release, darker filter)
./vstparam set ~/.vst3/Discovery.vst3 0x640 0.8   # A:Amp_Attack
./vstparam set ~/.vst3/Discovery.vst3 0x646 0.7   # A:Amp_Release
./vstparam set ~/.vst3/Discovery.vst3 0x67C 0.4   # A:Fil_Freq
./vstparam save ~/.vst3/Discovery.vst3 ~/mypad.txt

# Recall later
./vstparam load ~/.vst3/Discovery.vst3 ~/mypad.txt
```

Preset format (`paramID value`, one per line, `#` comments ignored):

```
# VST3 parameter preset snapshot
48 0
49 0
...
```

## Notes

- A VST3 plugin's component must be connected to its controller via `IConnectionPoint` before `getParameterCount()` returns the real parameter count — this tool follows the SDK's `PlugProvider` reference pattern.
- Parameter IDs are per-plugin; a preset made for one plugin will not apply to another.
- "Pad" vs "lead" target values are sound-design knowledge you supply — the tool gives you read/write access to every parameter.

## License

MIT
