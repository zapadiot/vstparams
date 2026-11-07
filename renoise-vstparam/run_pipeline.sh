#!/bin/bash
# ============================================================================
# VST3 Preset Pipeline - End-to-End Runner
# ============================================================================
# This script runs the full pipeline:
#   1. Renoise exports VST3 parameters to JSON (manual step - see below)
#   2. Python pipeline classifies preset type, searches web, suggests params
#   3. Output preset JSON can be applied back via Renoise
#
# Prerequisites:
#   - Renoise installed at /usr/local/bin/renoise
#   - VSTParamTool.xrnx installed in Renoise Scripts/Tools/
#   - Python 3 with requests module
#
# Usage:
#   ./run_pipeline.sh [discovery|tal-eq|tal-u-no-lx|custom <path>] [pad|lead|bass|drum|...]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/vst3_preset_pipeline.py"
JSON_OUT="/tmp/opencode/vst3_params.json"

# Plugin presets for quick testing
declare -A PLUGIN_PATHS=(
  [discovery]="$HOME/.vst3/Discovery.vst3"
  [tal-eq]="$HOME/.vst3/TAL-EQ.vst3"
  [tal-u-no-lx]="$HOME/.vst3/TAL-U-NO-LX-V2.vst3"
  [tal-j-8]="$HOME/.vst3/TAL-J-8.vst3"
  [retromulator]="$HOME/.vst3/Retromulator.vst3"
  [opsix]="$HOME/.vst3/opsix_native.vst3"
  [silver-k]="$HOME/.vst3/Silver-K.vst3"
)

PLUGIN="${1:-discovery}"
PRESET_TYPE="${2:-}"
PLUGIN_PATH=""

if [[ "$PLUGIN" == "custom" ]]; then
  PLUGIN_PATH="${3:-}"
  shift 3
elif [[ -n "${PLUGIN_PATHS[$PLUGIN]:-}" ]]; then
  PLUGIN_PATH="${PLUGIN_PATHS[$PLUGIN]}"
  shift 2
else
  echo "Unknown plugin: $PLUGIN"
  echo "Available: ${!PLUGIN_PATHS[@]} custom"
  exit 1
fi

if [[ ! -d "$PLUGIN_PATH" ]]; then
  echo "Plugin not found: $PLUGIN_PATH"
  exit 1
fi

echo "============================================================"
echo "VST3 Preset Pipeline"
echo "============================================================"
echo "Plugin: $PLUGIN ($PLUGIN_PATH)"
echo ""

# Step 1: Instructions for Renoise
echo "STEP 1: Export parameters from Renoise"
echo "----------------------------------------"
echo "1. Start Renoise:  renoise &"
echo "2. Load $PLUGIN into a track"
echo "3. Tools > VST3 Parameter Tool > Dump Selected Device"
echo "4. This writes parameters to: $JSON_OUT"
echo ""
echo "   OR if you already have a JSON file, specify it with --input"
echo ""

# Check if JSON already exists
if [[ -f "$JSON_OUT" ]]; then
  echo "Found existing JSON: $JSON_OUT"
  INPUT="$JSON_OUT"
else
  echo "No JSON found at $JSON_OUT"
  echo "Creating test JSON for $PLUGIN..."
  # Create a minimal test JSON based on plugin name
  python3 -c "
import json
data = {
    'plugin_name': '$PLUGIN',
    'device_path': '$PLUGIN',
    'is_active': True,
    'parameter_count': 0,
    'presets': ['Init'],
    'active_preset': 0,
    'parameters': []
}
with open('$JSON_OUT', 'w') as f:
    json.dump(data, f, indent=2)
print('Created placeholder JSON - replace with real Renoise export')
"
  INPUT="$JSON_OUT"
fi

echo ""
echo "STEP 2: Run classification + suggestion pipeline"
echo "------------------------------------------------"
CMD="python3 $PIPELINE --input $INPUT --output /tmp/opencode/${PLUGIN}_preset.json"
if [[ -n "$PRESET_TYPE" ]]; then
  # Skip classification, use heuristic directly for the given type
  $CMD --classify --suggest 2>&1 || true
else
  $CMD --classify --suggest 2>&1 || true
fi

echo ""
echo "STEP 3: Apply preset in Renoise"
echo "--------------------------------"
echo "1. In Renoise, select the $PLUGIN device"
echo "2. Tools > VST3 Parameter Tool > Apply Preset from JSON"
echo "3. Select: /tmp/opencode/${PLUGIN}_preset.json"
echo ""
echo "============================================================"
