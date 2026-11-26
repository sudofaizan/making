# MAKING Docker

Single image **`dexterquazi/alphafx:making`** runs:

- Dashboard (`dashboard/server.py` on port **8877**)
- All worker processes via **`init.sh`** (start/stop from UI — same as host)

MT5 stays on the VPS; the container only needs outbound HTTP to `MT5_HOST`.

## Build and push

```bash
chmod +x docker/build-push.sh
./docker/build-push.sh
```

From Apple Silicon, builds **`linux/amd64`** by default for EC2.

## Local

```bash
docker compose up --build
# http://127.0.0.1:8877/making/
```

## EC2

`./deploy.sh` (after `./push.sh`) pulls the image and runs:

- Data volumes: `/home/ec2-user/making-data/{logs,pids,data,env,var.env,dashboard.env}`
- Port **8877** → host (nginx router still uses `172.17.0.1:8877`)

First deploy migrates from legacy `/home/ec2-user/making` and disables systemd `making-dashboard`.

**After image replace:** worker PIDs are gone — use the dashboard to **Start** each stack again.

Legacy git-on-host deploy: `MAKING_DEPLOY=git ./deploy.sh`