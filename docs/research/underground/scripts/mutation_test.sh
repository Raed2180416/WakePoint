#!/bin/bash
export PATH=~/flutter/bin:$PATH
cd /home/raed/Projects/WakePoint
F=lib/core/reachability/reachability.dart
declare -a MUTS=(
  "s|final double freeRun = anchor.sHi + v \* dtClamped;|final double freeRun = anchor.sHi + v * 0.0;|;MUT1 no-elapsed-growth"
  "s|sMeters + (accuracyMeters.isFinite && accuracyMeters > 0 ? accuracyMeters : 0.0)|sMeters - (accuracyMeters.isFinite && accuracyMeters > 0 ? accuracyMeters : 0.0)|;MUT2 under-bound-anchor"
  "s|final dtClamped = dt.isFinite ? math.max(0.0, dt) : 0.0;|final dtClamped = dt.isFinite ? dt : 0.0;|;MUT3 allow-negative-dt"
  "s|return math.max(statistical, reach);|return math.min(statistical, reach);|;MUT4 effProgress-min-not-max"
  "s|return b.sMaxMeters >= targetMeters;|return b.sMaxMeters > targetMeters + 1e9;|;MUT5 never-reach-target"
  "s|static const double rrtsMps = 53.0;|static const double rrtsMps = 10.0;|;MUT6 rrts-ceiling-too-low"
  "s|if (reachableBoundMeters == double.infinity) return double.infinity;|if (reachableBoundMeters == double.infinity) return 0.0;|;MUT7 drop-watchdog-fire"
)
CAUGHT=0; SURVIVED=0
for m in "${MUTS[@]}"; do
  sed="${m%%;*}"; name="${m##*;}"
  cp "$F" "$F.bak"
  sed -i "$sed" "$F"
  if diff -q "$F" "$F.bak" >/dev/null; then echo "  [SKIP] $name (pattern didn't match)"; cp "$F.bak" "$F"; rm "$F.bak"; continue; fi
  # run reachability tests; a good mutation makes them FAIL
  if flutter test test/reachability/ >/tmp/mut_out.txt 2>&1; then
    echo "  [SURVIVED] $name  <-- tests still passed (coverage gap!)"; SURVIVED=$((SURVIVED+1))
  else
    echo "  [caught]    $name"; CAUGHT=$((CAUGHT+1))
  fi
  cp "$F.bak" "$F"; rm "$F.bak"
done
echo ""
echo "MUTATION RESULTS: caught=$CAUGHT survived=$SURVIVED"
# confirm tree restored
git diff --quiet "$F" && echo "tree restored clean" || echo "WARNING: tree not restored!"
