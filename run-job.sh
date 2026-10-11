#!/bin/bash
# Usage: run-job <code_url> <code_sha256> <upload_url> -- <godot args...>
# code_url / upload_url are short-lived presigned URLs; no credentials live on the machine.
set -euo pipefail
trap 'echo "run-job failed at line $LINENO: $BASH_COMMAND" >&2' ERR
CODE_URL=$1; CODE_SHA=$2; UPLOAD_URL=$3; shift 3; [ "${1:-}" = "--" ] && shift
W=/job; rm -rf "$W"; mkdir -p "$W/src" "$W/out"

pgrep -x Xvfb >/dev/null || { Xvfb :99 -screen 0 1920x1080x24 >/dev/null 2>&1 & }
for i in $(seq 1 20); do DISPLAY=:99 xset q >/dev/null 2>&1 && break; sleep 0.5; done
# Display: RUNNER_DISPLAY=xorg (default) runs godot on a real Xorg on the NVIDIA driver (:1, virtual 1920x1080, presents on the
# GPU); if it cannot start, or with RUNNER_DISPLAY=xvfb, on Xvfb :99 (CPU readback of every frame) as before. Xvfb :99 is up
# either way. The display actually used goes to gpu.txt, display.txt and the first line of run.log.
case ${RUNNER_DISPLAY:-xorg} in
  xorg) if XR=$(timeout 300 start-xorg-nvidia :1 2>"$W/out/xorg-start.log"); then export DISPLAY=:1; USED="RUNNER_DISPLAY=xorg ($XR)"
        else USED="RUNNER_DISPLAY=xvfb (fallback: ${XR:-start-xorg-nvidia timed out})"; cp /tmp/Xorg1.log "$W/out/" 2>/dev/null || true; fi ;;
  xvfb) USED="RUNNER_DISPLAY=xvfb (requested)" ;;
  *) USED="RUNNER_DISPLAY=xvfb (fallback: unknown RUNNER_DISPLAY=$RUNNER_DISPLAY)" ;;
esac
echo "$USED" > "$W/out/display.txt"; echo "display: $USED" >&2
{ nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  vulkaninfo --summary 2>/dev/null | grep deviceName || true
  echo "$USED"; } > "$W/out/gpu.txt"
upload() { tar -C "$W/out" -czf "$W/result.tgz" . && curl -fsS -X PUT --upload-file "$W/result.tgz" "$UPLOAD_URL"; }
if ! grep -q 'deviceName.*NVIDIA' "$W/out/gpu.txt"; then
  { echo "== vulkaninfo"; vulkaninfo --summary 2>&1 | head -60; echo "== icd"; ls -la /etc/vulkan/icd.d /usr/share/vulkan/icd.d 2>&1; cat /etc/vulkan/icd.d/*.json 2>&1;
    echo "== libs"; ls /usr/lib/x86_64-linux-gnu | grep -iE 'nvidia|GLX' 2>&1; echo "== env"; env | grep -E '^NVIDIA_|^DISPLAY'; } > "$W/out/gpu-diag.txt" 2>&1 || true
  echo 2 > "$W/out/exit_code"; upload || true
  echo "no NVIDIA Vulkan device (diag in gpu-diag.txt)" >&2; exit 2
fi

curl -fsS -o "$W/code.tar" "$CODE_URL"
echo "$CODE_SHA  $W/code.tar" | sha256sum -c - >/dev/null
tar -xf "$W/code.tar" -C "$W/src"

cd "$W/src"
# Movie Maker records at the window size and ignores --resolution; set the window override only
# (viewport/stretch base untouched, so pixel-art/UI scaling is preserved).
RES=$(printf '%s\n' "$@" | grep -A1 -x -- --resolution | tail -1 | grep -xE '[0-9]+x[0-9]+' || true)
if [ -n "$RES" ]; then
  printf '\n[display]\nwindow/size/window_width_override=%s\nwindow/size/window_height_override=%s\n' "${RES%x*}" "${RES#*x}" >> override.cfg
fi
timeout 600 godot --headless --path . --import > "$W/out/import.log" 2>&1 || true
set +e
echo "$USED" > "$W/out/run.log"
timeout "${JOB_TIMEOUT:-1800}" godot --path . --rendering-driver vulkan --disable-vsync "$@" >> "$W/out/run.log" 2>&1
echo $? > "$W/out/exit_code"
set -e

for f in "$W"/out/*.avi; do [ -e "$f" ] && ffmpeg -loglevel error -y -i "$f" -c:v libx264 -crf 20 -pix_fmt yuv420p "${f%.avi}.mp4" && rm "$f"; done
upload
cat "$W/out/exit_code"
