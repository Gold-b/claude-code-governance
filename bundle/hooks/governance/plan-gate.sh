#!/usr/bin/env bash
# plan-gate.sh — Context Governance hook (UserPromptSubmit)
# Detects large implementation tasks and instructs Claude to run /plan-and-execute.
#
# Heuristic: user message is "large" (>500 chars) AND contains implementation
# keywords (Hebrew or English). If both conditions are met, output an instruction
# recommending /plan-and-execute. NEVER exit 2 (UserPromptSubmit rule — gotcha #218).
#
# The instruction is advisory — Claude follows it because it's a system-level
# message, but the user can override by saying "don't plan, just do it".
#
# Kill switch: GOVERNANCE_HOOKS=0

set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || { exit 0; }

gov_disabled && exit 0

# Only enforce in governed projects
if [ ! -f "docs/context/CONTEXT-MANIFEST.md" ]; then
  exit 0
fi

# Read user prompt from stdin (JSON: {"prompt":"...","session_id":"...","cwd":"...",...})
if [ -t 0 ]; then
  exit 0
fi

RAW_INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$RAW_INPUT" ]; then
  exit 0
fi

# Extract only the user's typed message from the JSON payload.
# Without this, metadata (session_id, transcript_path, cwd) inflates the length.
# Use exit code to distinguish "extraction failed" from "prompt is empty".
INPUT=$(echo "$RAW_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('prompt', ''))
except Exception:
    sys.exit(1)
" 2>/dev/null)
PY_RC=$?
# Fallback only if python3 genuinely failed (non-zero exit), not on empty prompt
if [ "$PY_RC" -ne 0 ]; then
  INPUT="$RAW_INPUT"
fi
# Empty prompt = nothing to analyze, skip
[ -z "$INPUT" ] && exit 0

INPUT_LEN=${#INPUT}

# Skip short messages — unlikely to be large implementation tasks
if [ "$INPUT_LEN" -lt 500 ]; then
  exit 0
fi

# Skip if user explicitly says not to plan (use -P for perl regex to handle UTF-8)
echo "$INPUT" | grep -qiP "don't plan|just do it|skip plan|no plan" && exit 0
# Hebrew skip phrases — separate grep to avoid UTF-8 issues with alternation
echo "$INPUT" | grep -q "בלי תכנית\|אל תתכנן\|ללא תכנון\|תעשה ישר\|בלי plan" && exit 0

# Skip if user is already invoking /plan-and-execute
echo "$INPUT" | grep -qi "^/plan-and-execute\|/plan-and-execute" && exit 0

# Count implementation signals
SIGNALS=0

# Signal 1: Implementation action keywords (Hebrew)
echo "$INPUT" | grep -qi "ליישם\|לבנות\|ליצור\|לפתח\|לשכתב\|לממש\|להוסיף פיצ׳ר\|להוסיף פיצר\|להוסיף תכונה\|לשנות ארכיטקטורה\|ריפקטור\|שדרוג\|להתחיל ליישם\|תיישם\|תבנה\|תפתח" && SIGNALS=$((SIGNALS + 1))

# Signal 2: Implementation action keywords (English)
echo "$INPUT" | grep -qiE 'implement|refactor|build.*feature|create.*system|redesign|rewrite|migrate|overhaul|add.*module|develop' && SIGNALS=$((SIGNALS + 1))

# Signal 3: Technical content — file paths, code blocks, function names
echo "$INPUT" | grep -qiE '\.(js|ts|py|sh|md)[\s:]|function |class |module\.|import |const |async |admin/|lib/|server\.js|config\.js' && SIGNALS=$((SIGNALS + 1))

# Signal 4: Multi-step task indicators
echo "$INPUT" | grep -qiE 'שלב [0-9]|step [0-9]|phase [0-9]|שלבים|steps:|phases:|first.*then|קודם.*אחרי|1\.|2\.|3\.' && SIGNALS=$((SIGNALS + 1))

# Signal 5: Architectural scope words
echo "$INPUT" | grep -qiE 'architecture|ארכיטקטורה|pipeline|container|endpoint|schema|database|API|service|middleware' && SIGNALS=$((SIGNALS + 1))

# Need at least 2 signals + length threshold to recommend planning
if [ "$SIGNALS" -ge 2 ]; then
  gov_log "plan-gate" "large implementation task detected ($SIGNALS signals, $INPUT_LEN chars) — recommending /plan-and-execute"

  # Show popup notification (async — does not block)
  gov_notify \
    "המלצת תכנון" \
    "זוהתה משימת יישום גדולה. מומלץ להריץ את הסקיל לפני שמתחילים לעבוד." \
    "/plan-and-execute"

  cat <<'INSTRUCTION'
[GOVERNANCE RECOMMENDATION] Large implementation task detected (multi-step, technical, >500 chars). You MUST ask the user before proceeding. Use the AskUserQuestion tool with:
- question: "זיהיתי משימת יישום גדולה. איך להתקדם?"
- options: ["להריץ /plan-and-execute (מומלץ — תכנון עם CTO/Architect/Coder/QA/PM)", "להתחיל לעבוד ישר בלי תכנית"]

If the user picks option 1 — invoke the /plan-and-execute skill with the Skill tool.
If the user picks option 2 — proceed directly with the implementation task.
Do NOT start implementing before asking. This is a governance gate, not a suggestion.
INSTRUCTION
  exit 0
fi

exit 0
