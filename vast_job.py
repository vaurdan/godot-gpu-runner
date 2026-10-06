#!/usr/bin/env python3
"""Run one Godot capture job on a rented Vast.ai GPU (ghcr.io/vaurdan/godot-gpu-runner:4.7.2).

usage: vast_job.py <label> <full_sha> <outdir> -- <godot args...>
Code = git archive <sha>:game (project root), uploaded to B2 code/<sha256>.tar.gz; result -> runs/<label>/result.tgz.
Hosts only get presigned URLs. Instance destroyed at the end; a background safety net is started by the caller.
"""
import hashlib, io, json, os, subprocess, sys, tarfile, time, gzip, pathlib

REPO = "/root/workspace/night-shift"
VAST = "/root/.venvs/vast/bin/vastai"
IMG = "ghcr.io/vaurdan/godot-gpu-runner:4.7.2"
KEY = os.path.expanduser("~/.ssh/vast_ed25519")


def env_b2():
    e = {}
    for line in open("/root/.config/b2/godot-gpu-queue.env"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            e[k.replace("export ", "").strip()] = v.strip().strip('"').strip("'")
    return e


def s3():
    import boto3
    from botocore.config import Config
    e = env_b2()
    c = boto3.client("s3", endpoint_url=e["B2_ENDPOINT"] if e["B2_ENDPOINT"].startswith("http") else "https://" + e["B2_ENDPOINT"],
                     aws_access_key_id=e["B2_KEY_ID"], aws_secret_access_key=e["B2_APP_KEY"],
                     region_name=e.get("B2_REGION"), config=Config(signature_version="s3v4"))
    return c, e["B2_BUCKET"]


def vast(*a):
    return subprocess.run([VAST, *a], capture_output=True, text=True)


def main():
    label, sha, outdir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    gargs = sys.argv[sys.argv.index("--") + 1:]
    outdir.mkdir(parents=True, exist_ok=True)
    log = open(outdir / "vast_job.log", "a")
    def say(*m):
        s = time.strftime("%H:%M:%S ") + " ".join(str(x) for x in m)
        print(s, flush=True); log.write(s + "\n"); log.flush()

    raw = subprocess.run(["git", "-C", REPO, "archive", "--format=tar", f"{sha}:game"], capture_output=True, check=True).stdout
    blob = gzip.compress(raw, 6)
    digest = hashlib.sha256(blob).hexdigest()
    c, bucket = s3()
    ckey = f"code/{digest}.tar.gz"
    try:
        c.head_object(Bucket=bucket, Key=ckey)
    except Exception:
        c.put_object(Bucket=bucket, Key=ckey, Body=blob)
    say("code", sha[:8], digest[:12], len(blob) // 1024, "KiB")
    rkey = f"runs/{label}/result.tgz"
    get = c.generate_presigned_url("get_object", Params={"Bucket": bucket, "Key": ckey}, ExpiresIn=7200)
    put = c.generate_presigned_url("put_object", Params={"Bucket": bucket, "Key": rkey}, ExpiresIn=7200)

    offers = json.loads(vast("search", "offers", "gpu_name=RTX_3060 num_gpus=1 reliability>0.98 rentable=true inet_down>500 disk_space>=20", "-o", "dph_total", "--raw").stdout)
    offers = [o for o in offers if (o.get("driver_version") or "0").split(".")[0].isdigit() and int((o.get("driver_version") or "0").split(".")[0]) >= 535]
    if not offers:
        say("NO_OFFERS"); sys.exit(3)
    o = offers[0]
    say("offer", o["id"], o.get("gpu_name"), round(o.get("dph_total", 0), 4), "$/h", o.get("geolocation"))
    r = vast("create", "instance", str(o["id"]), "--image", IMG, "--disk", "20", "--ssh", "--direct",
             "--env", "-e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all", "--label", label, "--raw")
    try:
        iid = json.loads(r.stdout)["new_contract"]
    except Exception:
        say("CREATE_FAIL", r.stdout[:300], r.stderr[:300]); sys.exit(4)
    (outdir / "instance_id").write_text(str(iid))
    say("instance", iid)
    rc = 99
    try:
        ip = port = None
        for _ in range(60):
            time.sleep(10)
            info = json.loads(vast("show", "instance", str(iid), "--raw").stdout or "{}")
            if info.get("actual_status") == "running" and info.get("public_ipaddr") and info.get("ports", {}).get("22/tcp"):
                ip, port = info["public_ipaddr"].strip(), info["ports"]["22/tcp"][0]["HostPort"]
                break
        if not ip:
            say("NOT_READY"); sys.exit(5)
        say("ready", ip, port)
        ssh = ["ssh", "-i", KEY, "-p", str(port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
               "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30", f"root@{ip}"]
        for _ in range(18):
            if subprocess.run(ssh + ["true"], capture_output=True).returncode == 0:
                break
            time.sleep(10)
        quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in gargs)
        cmd = f"JOB_TIMEOUT=1500 run-job '{get}' {digest} '{put}' -- {quoted}"
        say("run", " ".join(gargs))
        p = subprocess.run(ssh + [cmd], capture_output=True, text=True, timeout=2400)
        (outdir / "remote_stdout.txt").write_text(p.stdout + "\n--stderr--\n" + p.stderr)
        rc = p.returncode
        say("remote rc", rc, p.stdout.strip()[-200:])
    finally:
        d = vast("destroy", "instance", str(iid), "-y")
        say("destroy", d.stdout.strip()[:120])
    buf = io.BytesIO()
    try:
        c.download_fileobj(bucket, rkey, buf)
        buf.seek(0)
        with tarfile.open(fileobj=buf, mode="r:gz") as t:
            t.extractall(outdir / "out")
        say("result extracted", outdir / "out")
    except Exception as ex:
        say("NO_RESULT", ex)
    sys.exit(rc)


if __name__ == "__main__":
    main()
