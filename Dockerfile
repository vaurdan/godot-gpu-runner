# Godot GPU runner for Vast.ai: engine + Vulkan/X deps only. No game code, no secrets.
FROM nvidia/cuda:12.4.1-base-ubuntu22.04

ARG GODOT_VERSION=4.7.2
ARG GODOT_SHA256=
ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_DRIVER_CAPABILITIES=all \
    NVIDIA_VISIBLE_DEVICES=all \
    DISPLAY=:99

RUN apt-get update && apt-get install -y --no-install-recommends \
      libvulkan1 vulkan-tools xvfb xauth libxcursor1 libxinerama1 libxrandr2 libxi6 \
      libgl1 libfontconfig1 libasound2 libpulse0 ffmpeg curl ca-certificates unzip zstd \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && if [ -n "$GODOT_SHA256" ]; then echo "$GODOT_SHA256  /tmp/godot.zip" | sha256sum -c -; fi \
    && unzip -q /tmp/godot.zip -d /opt/godot \
    && mv /opt/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && rm -rf /tmp/godot.zip /opt/godot

COPY run-job.sh /usr/local/bin/run-job
RUN chmod +x /usr/local/bin/run-job
