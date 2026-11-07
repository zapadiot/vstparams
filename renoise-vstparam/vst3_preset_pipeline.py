#!/usr/bin/env python3
"""
VST3 Preset Pipeline
====================

Reads VST3 parameters exported from Renoise, classifies the preset type
(pad/lead/drum/bass/etc.) using an LLM, searches the web for parameter
settings, and adapts them back to the specific plugin.

Usage:
    python3 vst3_preset_pipeline.py --input /tmp/opencode/vst3_params.json
    python3 vst3_preset_pipeline.py --input /tmp/opencode/vst3_params.json --classify --search --apply
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.parse

OLLAMA_URL = "http://69.57.210.224:11434"
OLLAMA_MODEL = "qwen2.5-coder:7b"  # good for reasoning/code, available per AGENTS.md


# ---------------------------------------------------------------------------
# 1. Read Renoise parameter JSON
# ---------------------------------------------------------------------------
def load_parameters(filepath):
    with open(filepath, "r") as f:
        return json.load(f)


def param_summary(data):
    """Return a human-readable summary of parameters for the LLM.

    Handles both single-device JSON (from 'Dump Selected Device'):
        {"plugin_name": "...", "parameters": [...]}
    and multi-device JSON (from 'Dump All Devices'):
        {"total_devices": N, "devices": [{"device_name": "...", "parameters": [...]}, ...]}
    """
    lines = []

    # Determine if multi-device format
    devices = data.get("devices")
    if devices and len(devices) > 0:
        # Multi-device format
        lines.append(f"Total devices: {data.get('total_devices', len(devices))}")
        for dev in devices[:5]:  # Limit to first 5 for LLM context
            lines.append(f"\nDevice: {dev.get('device_name', 'unknown')}")
            lines.append(f"  Track: {dev.get('track_name', 'unknown')}")
            lines.append(f"  Parameters: {dev.get('parameter_count', 0)}")
            lines.append("  Parameters (name, value, min, max, default):")
            for p in dev.get("parameters", [])[:20]:  # Limit params per device
                if not p.get("is_automatable", True):
                    continue
                lines.append(
                    f"    {p['name']}: {p['value']:.3f} "
                    f"(range {p['value_min']:.3f}-{p['value_max']:.3f}, "
                    f"default {p['value_default']:.3f})"
                )
        if len(devices) > 5:
            lines.append(f"\n... and {len(devices) - 5} more devices")
    else:
        # Single-device format
        lines.append(f"Plugin: {data.get('plugin_name', 'unknown')}")
        lines.append(f"Parameter count: {data.get('parameter_count', 0)}")
        lines.append(f"Presets: {', '.join(data.get('presets', []))}")
        lines.append("")
        lines.append("Parameters (name, current value, min, max, default):")
        for p in data.get("parameters", []):
            if not p.get("is_automatable", True):
                continue
            lines.append(
                f"  {p['name']}: {p['value']:.3f} "
                f"(range {p['value_min']:.3f}-{p['value_max']:.3f}, "
                f"default {p['value_default']:.3f})"
            )
    return "\n".join(lines)


def classify_preset(data, model=OLLAMA_MODEL):
    """Ask the LLM what preset type this plugin configuration represents."""
    summary = param_summary(data)

    # Determine plugin name for prompt
    devices = data.get("devices")
    if devices and len(devices) > 0:
        plugin_name = devices[0].get("device_name", "unknown plugin")
    else:
        plugin_name = data.get("plugin_name", "unknown plugin")

    prompt = f"""You are a sound design expert. Analyze the following VST3 plugin parameters and classify the preset type.

Plugin: {plugin_name}
{summary}

Classify this preset into ONE of these categories:
- pad: slow attack, long release, sustained, atmospheric
- lead: fast attack, bright, resonant, melodic
- bass: low frequency, punchy, sub-heavy
- drum: percussive, short decay, rhythmic
- arp: arpeggiated, rhythmic, repeating
- fx: sound effects, risers, impacts, transitions
- pluck: short decay, plucked string-like
- keys: piano/organ-like keyboard sound
- ambient: evolving, textural, spacious
- other: anything else

Respond with ONLY the category name (lowercase), followed by a brief one-sentence justification.
Example:
lead
Bright filter with fast attack envelope, suitable for melodic lines.
"""


# ---------------------------------------------------------------------------
# 2. Classify preset type using Ollama LLM
# ---------------------------------------------------------------------------
def classify_preset(data, model=OLLAMA_MODEL):
    """Ask the LLM what preset type this plugin configuration represents."""
    summary = param_summary(data)

    prompt = f"""You are a sound design expert. Analyze the following VST3 plugin parameters and classify the preset type.

Plugin: {data.get('plugin_name', 'unknown')}
Available parameters (name, current value, min, max, default):
{summary}

Classify this preset into ONE of these categories:
- pad: slow attack, long release, sustained, atmospheric
- lead: fast attack, bright, resonant, melodic
- bass: low frequency, punchy, sub-heavy
- drum: percussive, short decay, rhythmic
- arp: arpeggiated, rhythmic, repeating
- fx: sound effects, risers, impacts, transitions
- pluck: short decay, plucked string-like
- keys: piano/organ-like keyboard sound
- ambient: evolving, textural, spacious
- other: anything else

Respond with ONLY the category name (lowercase), followed by a brief one-sentence justification.
Example:
lead
Bright filter with fast attack envelope, suitable for melodic lines.
"""

    try:
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.3, "num_predict": 200}
        }
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        text = result.get("response", "").strip()

        # Extract category (first line, lowercase)
        category = text.split("\n")[0].strip().lower()
        # Clean up: remove any non-alphabetic chars
        category = re.sub(r"[^a-z]", "", category)

        valid = {"pad", "lead", "bass", "drum", "arp", "fx", "pluck", "keys", "ambient", "other"}
        if category not in valid:
            category = "other"

        justification = "\n".join(text.split("\n")[1:]).strip() if "\n" in text else ""
        return category, justification

    except Exception as e:
        print(f"[WARN] Ollama classification failed: {e}", file=sys.stderr)
        return heuristic_classify(data), "(fallback heuristic)"


def heuristic_classify(data):
    """Fallback classification based on parameter names.

    Handles both single-device and multi-device JSON formats.
    """
    names = ""
    devices = data.get("devices")
    if devices and len(devices) > 0:
        for dev in devices:
            for p in dev.get("parameters", []):
                names += " " + p.get("name", "").lower()
    else:
        for p in data.get("parameters", []):
            names += " " + p.get("name", "").lower()

    # Check for pad indicators
    pad_indicators = ["attack", "release", "sustain", "filter", "env", "amp"]
    lead_indicators = ["cutoff", "resonance", "osc", "detune", "vibrato"]
    drum_indicators = ["kick", "snare", "hihat", "perc", "drum", "transient"]
    bass_indicators = ["sub", "bass", "low", "subosc"]

    score = {"pad": 0, "lead": 0, "drum": 0, "bass": 0}

    for ind in pad_indicators:
        if ind in names:
            score["pad"] += 1
    for ind in lead_indicators:
        if ind in names:
            score["lead"] += 1
    for ind in drum_indicators:
        if ind in names:
            score["drum"] += 1
    for ind in bass_indicators:
        if ind in names:
            score["bass"] += 1

    return max(score, key=score.get) if max(score.values()) > 0 else "other"


# ---------------------------------------------------------------------------
# 3. Search the web for preset parameter settings
# ---------------------------------------------------------------------------
def web_search(query):
    """Search the web for preset parameter settings."""
    # Try DuckDuckGo HTML
    url = "https://duckduckgo.com/html/?q=" + urllib.parse.quote(query)
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="ignore")
        # Extract result snippets
        results = []
        for m in re.finditer(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', html):
            link = m.group(1)
            title = re.sub(r"<[^>]+>", "", m.group(2)).strip()
            results.append({"title": title, "url": link})
        return results[:5]
    except Exception as e:
        print(f"[WARN] Web search failed: {e}", file=sys.stderr)
        return []


def search_preset_settings(plugin_name, preset_type):
    """Search for recommended parameter settings for this plugin + preset type."""
    queries = [
        f"{plugin_name} {preset_type} preset settings parameters",
        f"{plugin_name} {preset_type} sound design tutorial",
        f"{plugin_name} {preset_type} patch parameters",
    ]
    all_results = []
    for q in queries:
        results = web_search(q)
        all_results.extend(results)
    # Deduplicate
    seen = set()
    unique = []
    for r in all_results:
        if r["url"] not in seen:
            seen.add(r["url"])
            unique.append(r)
    return unique[:10]


# ---------------------------------------------------------------------------
# 4. Map generic parameter settings to the specific plugin
# ---------------------------------------------------------------------------
def suggest_parameters(data, preset_type, search_results):
    """
    Use the LLM to map generic preset settings to this plugin's parameters.
    Returns a list of {name, value, reason} mappings.

    Handles both single-device and multi-device JSON formats.
    """
    # Collect parameters from all devices (multi-device) or single device
    params_list = []
    plugin_name = "unknown plugin"

    devices = data.get("devices")
    if devices and len(devices) > 0:
        # Multi-device format - use first device's name for plugin context
        plugin_name = devices[0].get("device_name", "unknown plugin")
        for dev in devices:
            for p in dev.get("parameters", []):
                if not p.get("is_automatable", True):
                    continue
                params_list.append(
                    f"  {p['name']}: current={p['value']:.3f}, "
                    f"range=[{p['value_min']:.3f}, {p['value_max']:.3f}], "
                    f"default={p['value_default']:.3f}"
                )
    else:
        # Single-device format
        plugin_name = data.get("plugin_name", "unknown plugin")
        for p in data.get("parameters", []):
            if not p.get("is_automatable", True):
                continue
            params_list.append(
                f"  {p['name']}: current={p['value']:.3f}, "
                f"range=[{p['value_min']:.3f}, {p['value_max']:.3f}], "
                f"default={p['value_default']:.3f}"
            )

    params_text = "\n".join(params_list)

    # Summarize search results
    search_text = ""
    for r in search_results[:5]:
        search_text += f"- {r['title']}: {r['url']}\n"

    prompt = f"""You are a sound design expert. I have a VST3 plugin "{plugin_name}"
and I want to create a "{preset_type}" preset.

The plugin has these automatable parameters:
{params_text}

I found these web resources about {preset_type} presets for this plugin:
{search_text}

Based on your knowledge of sound design and the search results, suggest specific
parameter values for a "{preset_type}" preset on THIS plugin.

For each parameter you recommend changing, provide:
- The exact parameter name (must match one of the listed names)
- A value between the parameter's min and max
- A brief reason

Respond with ONLY a JSON array of objects like this:
[{{"name": "Filter Cutoff", "value": 0.7, "reason": "Open filter for brighter lead sound"}},
 {{"name": "Amp Attack", "value": 0.1, "reason": "Fast attack for punchy lead"}}]

Only include parameters you are confident about. If unsure about a parameter, leave it at default.
"""

    try:
        payload = {
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.4, "num_predict": 800}
        }
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        text = result.get("response", "").strip()

        # Extract JSON array from response
        json_match = re.search(r"\[.*\]", text, re.DOTALL)
        if json_match:
            mappings = json.loads(json_match.group(0))
            # Validate each mapping has name and value
            valid_mappings = []
            for m in mappings:
                if "name" in m and "value" in m:
                    valid_mappings.append(m)
            return valid_mappings
        else:
            print("[WARN] No JSON array found in LLM response", file=sys.stderr)
            return []

    except Exception as e:
        print(f"[WARN] Parameter suggestion failed: {e}", file=sys.stderr)
        return []


def heuristic_suggest(data, preset_type):
    """Fallback: generic suggestions based on preset type and parameter names.

    Handles both single-device and multi-device JSON formats.
    """
    suggestions = []

    # Collect all automatable parameters from all devices
    devices = data.get("devices")
    if devices and len(devices) > 0:
        all_params = []
        for dev in devices:
            for p in dev.get("parameters", []):
                all_params.append(p)
    else:
        all_params = data.get("parameters", [])

    for p in all_params:
        if not p.get("is_automatable", True):
            continue
        name_lower = p["name"].lower()
        val = p["value_default"]

        if preset_type == "pad":
            if "attack" in name_lower:
                val = min(0.8, p["value_max"])
            elif "release" in name_lower:
                val = min(0.8, p["value_max"])
            elif "sustain" in name_lower:
                val = min(0.9, p["value_max"])
            elif "filter" in name_lower and "freq" in name_lower or "cutoff" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.35
        elif preset_type == "lead":
            if "attack" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.1
            elif "release" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.2
            elif "filter" in name_lower and "freq" in name_lower or "cutoff" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.8
            elif "resonance" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.6
        elif preset_type == "bass":
            if "filter" in name_lower and "freq" in name_lower or "cutoff" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.25
            elif "resonance" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.4
        elif preset_type == "drum":
            if "attack" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.05
            elif "decay" in name_lower or "release" in name_lower:
                val = p["value_min"] + (p["value_max"] - p["value_min"]) * 0.15

        if abs(val - p["value_default"]) > 0.05:
            suggestions.append({
                "name": p["name"],
                "value": round(val, 4),
                "reason": f"Heuristic {preset_type} setting for {p['name']}"
            })

    return suggestions


# ---------------------------------------------------------------------------
# 5. Generate JSON preset file for Renoise
# ---------------------------------------------------------------------------
def generate_preset_json(data, mappings, preset_type, output_path):
    """Generate a JSON preset file that can be applied via Renoise."""
    preset = {
        "plugin": data.get("plugin_name", "unknown"),
        "device_path": data.get("device_path", ""),
        "preset_type": preset_type,
        "parameters": mappings
    }
    with open(output_path, "w") as f:
        json.dump(preset, f, indent=2)
    return output_path


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="VST3 Preset Pipeline")
    parser.add_argument("--input", required=True, help="Path to Renoise parameter JSON")
    parser.add_argument("--classify", action="store_true", help="Classify preset type")
    parser.add_argument("--search", action="store_true", help="Search web for settings")
    parser.add_argument("--suggest", action="store_true", help="Suggest parameter values")
    parser.add_argument("--output", default="/tmp/opencode/vst3_preset.json",
                        help="Output preset JSON path")
    parser.add_argument("--ollama-model", default=OLLAMA_MODEL, help="Ollama model to use")
    args = parser.parse_args()

    # Load
    data = load_parameters(args.input)
    print(f"Loaded {data['parameter_count']} parameters from {data['plugin_name']}")

    # Classify
    preset_type = "other"
    justification = ""
    if args.classify:
        preset_type, justification = classify_preset(data, args.ollama_model)
        print(f"Classified as: {preset_type}  ({justification})")
    else:
        preset_type = heuristic_classify(data)
        print(f"Classified as (heuristic): {preset_type}")

    # Search
    search_results = []
    if args.search:
        plugin_name = data.get("plugin_name", "unknown")
        search_results = search_preset_settings(plugin_name, preset_type)
        print(f"Found {len(search_results)} web results")
        for r in search_results[:5]:
            print(f"  - {r['title']}: {r['url']}")

    # Suggest
    mappings = []
    if args.suggest:
        if search_results:
            mappings = suggest_parameters(data, preset_type, search_results)
        if not mappings:
            mappings = heuristic_suggest(data, preset_type)
        print(f"Suggested {len(mappings)} parameter changes")
        for m in mappings:
            print(f"  {m['name']} = {m['value']}  ({m.get('reason', '')})")

    # Output
    generate_preset_json(data, mappings, preset_type, args.output)
    print(f"Preset saved to {args.output}")


if __name__ == "__main__":
    main()
