#!/bin/zsh
# Overnight learned-J estimate (Phase 3). Run when the Mac is free, plugged in, lid OPEN
# (closing the lid sleeps a MacBook without an external display; the screen may turn off).
#
#   scripts/overnight-jlens.sh            # start (or resume) in the background
#   tail -f ~/Library/Logs/Wade/jlens-build.log
#
# ~120 prompts x 32 tokens; 30s pause after each prompt, 60s after every 5th: roughly 8 hours. Progress is
# checkpointed after every prompt, so re-running resumes. Writes jlens-learned.npz (the
# J = I lens in use stays untouched) and prints J-lens vs logit-lens validation at the end.
set -euo pipefail
cd "${0:A:h}/.."

OUT="$HOME/Library/Application Support/Wade/jlens-learned.npz"
LOG="$HOME/Library/Logs/Wade/jlens-build.log"
mkdir -p "${LOG:h}"

if ! pmset -g batt | grep -q "AC Power"; then
  echo "warning: on battery; plug in for an overnight run" | tee -a "$LOG"
fi
echo "=== $(date) starting (resumes from checkpoint if present)" >> "$LOG"

# -i: no idle sleep, -s: no system sleep on AC. The display is allowed to sleep.
nohup caffeinate -is env PYTHONUNBUFFERED=1 uv run wade-stage2 build \
  --prompts 120 --max-tokens 32 --cooldown 30 --long-cooldown 60 --long-every 5 --out "$OUT" >> "$LOG" 2>&1 &
echo "started (pid $!); log: $LOG"
