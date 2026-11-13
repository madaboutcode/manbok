#!/bin/zsh
# Runs the supervisor order checks and writes run-<name>.txt (command, output, exit code, elapsed).
# Each run stops at ${TMO:-1200} s (exit 124, marked BOUND); a stopped run is a gap, not a pass.
# usage: ./run.sh <name> [ENV=value ...]      e.g. ./run.sh base MODEL_VARIANT=base
#        ./run.sh all                         every run listed in the README table
# Every run is node only: no audio device is opened, no app is started.
cd "$(dirname "$0")"
MS=${MS:-6000000}
one() {
  name=$1; shift
  echo "command: env $* node check.mjs supervisor.model.mjs --max-states $MS --max-mb 3000" > run-$name.txt
  s=$(date +%s)
  timeout --signal=TERM ${TMO:-1200} env "$@" node check.mjs supervisor.model.mjs --max-states $MS --max-mb 3000 >> run-$name.txt 2>&1; c=$?
  echo "exit code: $c" >> run-$name.txt
  [[ $c -eq 124 ]] && echo "BOUND: stopped at the ${TMO:-1200} s time limit; not a pass (gap)" >> run-$name.txt
  echo "elapsed: $(( $(date +%s) - s ))s" >> run-$name.txt
}
if [[ "$1" == "all" ]]; then
  one base MODEL_VARIANT=base
  one sustain-scaled MODEL_VARIANT=base MODEL_SUSTAIN=1 MODEL_MAX=60
  one storm4 MODEL_VARIANT=base MODEL_RECOV_MAX=4
  one switch-only MODEL_VARIANT=base MODEL_RESTRICT=switch
  one switch-only-k2 MODEL_VARIANT=base MODEL_RESTRICT=switch MODEL_SWITCH_MAX=2
  one switch-only-defer12 MODEL_VARIANT=base MODEL_RESTRICT=switch MODEL_DEFER_MAX=12
  one switch-only-defer13 MODEL_VARIANT=base MODEL_RESTRICT=switch MODEL_DEFER_MAX=13
  one switch-only-defer14 MODEL_VARIANT=base MODEL_RESTRICT=switch MODEL_DEFER_MAX=14
  for v in m-clear-on-release m-never-reset m-stall-lastdata-only m-ladder-skip m-leak-empty m-gaphold m-uncapped-delay; do
    one $v MODEL_VARIANT=$v
  done
else
  one "$@"
fi
