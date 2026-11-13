#!/bin/zsh
# Runs every reducer-model check sequentially. Raw output: run-<tag>.txt (first line: command; last lines: exit code, elapsed).
# Node only: no audio device is opened, no app is started.
# usage: ./run.sh all | ./run.sh <tag> <variant> [ENV=value ...]
cd "$(dirname "$0")"
A="MODEL_APPS=2 MODEL_DEVS=2 MODEL_TOT=1 MODEL_EXAPPS=0"
B="MODEL_APPS=1 MODEL_DEVS=2 MODEL_TOT=6 MODEL_EXAPPS=0"
C="MODEL_APPS=2 MODEL_DEVS=1 MODEL_TOT=2 MODEL_EXAPPS=1"
L="MODEL_TIMERS=1 MODEL_APPS=2 MODEL_DEVS=1 MODEL_TOT=1 MODEL_EXAPPS=1"
run() { tag=$1; v=$2; shift 2
  echo "command: env MODEL_VARIANT=$v $* node check.mjs session.model.mjs --max-states 600000 --max-mb 3000" > run-$tag.txt
  s=$(date +%s); env MODEL_VARIANT=$v "$@" node check.mjs session.model.mjs --max-states 600000 --max-mb 3000 2>&1 | grep -v '^exploring' >> run-$tag.txt; c=${pipestatus[1]}
  echo "exit code: $c" >> run-$tag.txt; echo "elapsed: $(( $(date +%s)-s ))s" >> run-$tag.txt; }
if [[ "$1" == "all" ]]; then
  run fix-A fix ${=A}; run fix-B fix ${=B}; run fix-C fix ${=C}; run fix-L fix ${=L}
  run no-a3-B no-a3 ${=B}
  run gaphold-A gaphold ${=A}; run gaphold-L gaphold ${=L}
  run flag-A flag ${=A}; run flag-L flag ${=L}
  run p5union-A p5union ${=A}; run stale-A stale ${=A}; run drainsess-A drainsess ${=A}; run drainsess-C drainsess ${=C}
  run nostep2-A nostep2 ${=A}; run ticks-A ticks ${=A}; run nofallback-A nofallback ${=A}
  run excl-late-C excl-late ${=C}; run excl-ignore-C excl-ignore ${=C}; run timer-C timer ${=C}; run excl-dropnosess-C excl-dropnosess ${=C}
  run a3-leak-B a3-leak ${=B}; run not-consumed-B not-consumed ${=B}
  F="MODEL_FINDINGS=1 MODEL_APPS=1 MODEL_DEVS=2 MODEL_TOT=3 MODEL_EXAPPS=0"
  run findings-nosleep fix ${=F} MODEL_NOSLEEP=1
  run findings-edge-true fix ${=F} MODEL_NOSLEEP=1 MODEL_EDGE=true
  run findings-edge-false fix ${=F} MODEL_NOSLEEP=1 MODEL_EDGE=false
  run tight-b7-L fix ${=L} MODEL_BSTOP=7; run tight-bex5-C fix ${=C} MODEL_BEX=5
else
  run "$@"
fi
