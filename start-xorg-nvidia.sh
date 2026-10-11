#!/bin/bash
# start-xorg-nvidia [display]: a real Xorg on the NVIDIA driver with a virtual 1920x1080 screen and no monitor, so Godot
# presents on the GPU instead of through Xvfb's CPU readback (night-shift #137: empty 1080p window 0.3 ms vs 54-62 ms on Xvfb).
# The X driver files (nvidia_drv.so, libglxserver_nvidia.so.<ver>) are not in the image: with NVIDIA_DRIVER_CAPABILITIES=all
# the container toolkit mounts the host's own copies, so they match the host kernel driver. If they are missing, the matching
# .run is downloaded from download.nvidia.com and only those two files are extracted.
# Prints ONE line on stdout: on success "nvidia <display>, driver <ver>, <BusID>" (exit 0); on failure the reason (exit 1).
# Details (Xorg log tail, download errors) go to stderr.
set -u
D=${1:-:1}
fail() { echo "$*"; exit 1; }
command -v Xorg >/dev/null || fail "no Xorg binary"
[ -e /dev/nvidia-modeset ] || fail "no /dev/nvidia-modeset"
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
BUS=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
[ -n "$DRV" ] && [ -n "$BUS" ] || fail "nvidia-smi gave no driver/bus id"
find_x() { NVDRV=$(find /usr/lib/xorg /usr/lib/x86_64-linux-gnu -name nvidia_drv.so 2>/dev/null | head -1)
           GLXS=$(find /usr/lib/xorg /usr/lib/x86_64-linux-gnu -name 'libglxserver_nvidia.so*' 2>/dev/null | head -1); }
find_x
if [ -z "$NVDRV" ] || [ -z "$GLXS" ]; then
  echo "X driver files not mounted, fetching NVIDIA-Linux-x86_64-$DRV.run" >&2
  for h in download.nvidia.com us.download.nvidia.com; do
    curl -fsSL --max-time 240 -o /tmp/nv.run "https://$h/XFree86/Linux-x86_64/$DRV/NVIDIA-Linux-x86_64-$DRV.run" >&2 && break
  done
  [ -s /tmp/nv.run ] || fail "X driver files not mounted and no NVIDIA-Linux-x86_64-$DRV.run to download"
  (cd /tmp && sh /tmp/nv.run -x --target /tmp/nvx >/dev/null 2>&1) || fail "cannot extract NVIDIA-Linux-x86_64-$DRV.run"
  mkdir -p /usr/lib/xorg/modules/drivers /usr/lib/xorg/modules/extensions
  cp /tmp/nvx/nvidia_drv.so /usr/lib/xorg/modules/drivers/ \
    && cp "/tmp/nvx/libglxserver_nvidia.so.$DRV" /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so \
    || fail "NVIDIA-Linux-x86_64-$DRV.run has no X driver files"
  rm -rf /tmp/nv.run /tmp/nvx
  find_x
fi
# BusID in decimal: 00000000:2B:00.0 -> PCI:43:0:0
IFS=':.' read -r _dom _bus _dev _fn <<< "$BUS"
B=$(printf "PCI:%d:%d:%d" "0x$_bus" "0x$_dev" "0x$_fn")
cat > /tmp/xorg-nv.conf <<XC
Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "AutoAddGPU" "false"
    Option "DontVTSwitch" "true"
EndSection
Section "Files"
    ModulePath "/usr/lib/xorg/modules"
    ModulePath "$(dirname "$NVDRV")"
    ModulePath "$(dirname "$GLXS")"
EndSection
Section "Device"
    Identifier "nv"
    Driver "nvidia"
    BusID "$B"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "ConnectedMonitor" "DFP-0"
    Option "HardDPMS" "false"
    Option "ProbeAllGpus" "false"
EndSection
Section "Monitor"
    Identifier "mon"
    HorizSync 5.0-1000.0
    VertRefresh 5.0-1000.0
    ModeLine "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection
Section "Screen"
    Identifier "scr"
    Device "nv"
    Monitor "mon"
    DefaultDepth 24
    Option "UseDisplayDevice" "None"
    SubSection "Display"
        Depth 24
        Virtual 1920 1080
        Modes "1920x1080"
    EndSubSection
EndSection
XC
LOG=/tmp/Xorg${D#:}.log
# stdout/stderr of the server must not hold the caller's pipe open
Xorg "$D" -config /tmp/xorg-nv.conf -noreset -nolisten tcp -novtswitch -sharevts +extension GLX +extension RANDR +extension RENDER \
  -logfile "$LOG" >/tmp/Xorg${D#:}.out 2>&1 </dev/null &
XPID=$!
for i in $(seq 1 30); do
  sleep 1; DISPLAY=$D xset q >/dev/null 2>&1 && break
  kill -0 $XPID 2>/dev/null || break
done
if ! DISPLAY=$D xset q >/dev/null 2>&1; then
  tail -30 "$LOG" >&2 2>/dev/null; kill $XPID 2>/dev/null
  fail "Xorg $D did not start ($(grep -m1 -E '^\[.*\] \(EE\) [A-Za-z]' "$LOG" 2>/dev/null | sed 's/^\[[^]]*\] (EE) //' | cut -c1-120))"
fi
# a real Vulkan present on this display, so a host whose X/Vulkan path is broken falls back instead of failing the job
if command -v vkcube >/dev/null && ! DISPLAY=$D timeout 30 vkcube --c 120 --present_mode 0 --suppress_popups >&2 2>&1; then
  kill $XPID 2>/dev/null
  fail "vkcube could not present on Xorg $D"
fi
echo "nvidia $D, driver $DRV, $B"
