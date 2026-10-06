#!/bin/bash
# usage: vast_run.sh <label> <full_sha> <outdir> -- <godot args>
# Wraps vast_job.py with a hard safety net that destroys any instance carrying this label after 45 min.
L=$1; OUT=$3
VAST=/root/.venvs/vast/bin/vastai
mkdir -p "$OUT"
( sleep 2700
  for id in $($VAST show instances --raw 2>/dev/null | python3 -c "import json,sys;[print(i['id']) for i in json.load(sys.stdin) if i.get('label')=='$L']"); do
    $VAST destroy instance $id -y; echo "SAFETY_NET destroyed $id" >> "$OUT/vast_job.log"; done ) &
NET=$!
cd /root/workspace/gpu-runner && python3 vast_job.py "$@"
RC=$?
kill $NET 2>/dev/null
echo "instances left: $($VAST show instances --raw | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" >> "$OUT/vast_job.log"
exit $RC
