#!/bin/bash
# Usage: run-job <code_url> <code_sha256> <upload_url> -- <godot args...>
# code_url / upload_url are short-lived presigned URLs; no credentials live on the machine.
set -euo pipefail
CODE_URL=$1; CODE_SHA=$2; UPLOAD_URL=$3; shift 3; [ "${1:-}" = "--" ] && shift
W=/job; rm -rf "$W"; mkdir -p "$W/src" "$W/out"

pgrep -x Xvfb >/dev/null || { Xvfb :99 -screen 0 1920x1080x24 >/dev/null 2>&1 & sleep 1; }
{ nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  vulkaninfo --summary 2>/dev/null | grep -m1 deviceName; } > "$W/out/gpu.txt"
grep -q 'deviceName.*NVIDIA' "$W/out/gpu.txt" || { echo "no NVIDIA Vulkan device" >&2; exit 2; }

curl -fsS -o "$W/code.tar" "$CODE_URL"
echo "$CODE_SHA  $W/code.tar" | sha256sum -c - >/dev/null
tar -xf "$W/code.tar" -C "$W/src"

cd "$W/src"
# Movie Maker records at the project viewport size and ignores --resolution; mirror it into override.cfg.
RES=$(printf '%s\n' "$@" | grep -A1 -x -- --resolution | tail -1 | grep -xE '[0-9]+x[0-9]+' || true)
if [ -n "$RES" ]; then
  printf '\n[display]\nwindow/size/viewport_width=%s\nwindow/size/viewport_height=%s\n' "${RES%x*}" "${RES#*x}" >> override.cfg
fi
timeout 600 godot --headless --path . --import > "$W/out/import.log" 2>&1 || true
set +e
timeout "${JOB_TIMEOUT:-1800}" godot --path . --rendering-driver vulkan --disable-vsync "$@" > "$W/out/run.log" 2>&1
echo $? > "$W/out/exit_code"
set -e

for f in "$W"/out/*.avi; do [ -e "$f" ] && ffmpeg -loglevel error -y -i "$f" -c:v libx264 -crf 20 -pix_fmt yuv420p "${f%.avi}.mp4" && rm "$f"; done
tar -C "$W/out" -czf "$W/result.tgz" .
curl -fsS -X PUT --upload-file "$W/result.tgz" "$UPLOAD_URL"
cat "$W/out/exit_code"
