# godot-gpu-runner

Runs one Godot 4.7.2 job (an exact git revision of a project) on a disposable Vast.ai GPU and brings the results back.
The image holds only the engine and its Vulkan/X dependencies: no game code and no secrets.

| file | what it is |
|---|---|
| `gpu-job` | entry point: retries infrastructure failures on a fresh machine (`GPU_ATTEMPTS`, default 3) |
| `gpu-job-once` | one attempt: packs the revision, rents a machine, runs `run-job`, fetches `result.tgz`, destroys the machine |
| `run-job.sh` | inside the image (`/usr/local/bin/run-job`): display, GPU check, import, godot run, mp4 conversion, upload |
| `start-xorg-nvidia.sh` | inside the image: real Xorg on the NVIDIA driver (see Display) |
| `gpu-peek` | read-only look into a running instance |
| `Dockerfile`, `.github/workflows/build.yml` | the image, built by GitHub Actions |

```
gpu-job <repo_dir> <full_commit_sha> <project_subdir|.> <out_dir> -- <godot args...>
```

Main env vars (see the `gpu-job-once` header for all): `GPU_QUERY`, `GPU_MAX_DPH`, `GPU_MACHINE`, `GPU_EXCLUDE`,
`JOB_TIMEOUT`, `GPU_IMAGE_TAG`, `RUNNER_DISPLAY`.

## Display

Since 2026-10-11 godot runs by default on a **real Xorg on the NVIDIA driver** (`:1`, virtual 1920x1080 screen, no monitor).
Before that every job ran on Xvfb (`:99`), where each presented frame is copied back through the CPU: an empty 1080p window
cost 36-80 ms per frame on Xvfb against 0.26-0.38 ms on Xorg on the same machines.
**Frame times measured before 2026-10-11 (Xvfb) are not comparable 1:1 with later runs (Xorg).**

| `RUNNER_DISPLAY` | behaviour |
|---|---|
| unset / `xorg` | `start-xorg-nvidia` starts Xorg and checks it with a real Vulkan present (`vkcube`). If anything fails, the job falls back to Xvfb automatically |
| `xvfb` | old behaviour: Xvfb only |

Xvfb `:99` is started in both cases. The display actually used is written to:
- the last line of `gpu.txt`,
- `display.txt`,
- the first line of `run.log`,

as `RUNNER_DISPLAY=xorg (nvidia :1, driver <ver>, PCI:<bus>)`, `RUNNER_DISPLAY=xvfb (requested)` or
`RUNNER_DISPLAY=xvfb (fallback: <reason>)`. On a fallback, `xorg-start.log` and `Xorg1.log` are in the results.

The NVIDIA X driver (`nvidia_drv.so`, `libglxserver_nvidia.so.<ver>`) is not in the image: with
`NVIDIA_DRIVER_CAPABILITIES=all` the NVIDIA container toolkit mounts the host's own copy, which matches the host kernel
driver. If a host does not mount it, `start-xorg-nvidia` downloads the same driver version's `.run` from
download.nvidia.com and extracts only those two files. If that also fails, the job falls back to Xvfb.

## Image tags

`gpu-job-once` resolves `GPU_IMAGE_TAG` (default `4.7.2`) to a digest and rents with `image@digest`, so hosts never run
a stale cached tag. `GPU_IMAGE_TAG` also accepts `sha256:<digest>` and `sha-<commit>`.

| push / action | tags |
|---|---|
| push to `main` | `:4.7.2`, `:sha-<commit>` |
| push to `stage/<name>` | `:4.7.2-<name>`, `:sha-<commit>`; `:4.7.2` does not move |
| Actions, build-image, `workflow_dispatch` with `promote=<tag or sha256:digest>` | no build: the image now under `:<target>` (default `4.7.2`) is also tagged `:<backup_as>` (default `4.7.2-prev`, empty = none), then the given image is tagged `:<target>`; digests are kept exactly (`crane tag`) |

To validate an image change without touching other users: push it to `stage/<name>`, run jobs with
`GPU_IMAGE_TAG=4.7.2-<name>`, then promote the validated digest with
`gh workflow run build-image -R vaurdan/godot-gpu-runner --ref stage/<name> -f promote=sha256:<digest> -f backup_as=<tag>`.

## Rollback to the Xvfb-only image

```
GPU_IMAGE_TAG=4.7.2-xvfb gpu-job ...          # one job
RUNNER_DISPLAY=xvfb gpu-job ...               # current image, Xvfb display
```

To make it the default again for everyone:
`gh workflow run build-image -R vaurdan/godot-gpu-runner -f promote=4.7.2-xvfb -f backup_as=4.7.2-prev`.
