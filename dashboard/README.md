# MAKING dashboard

Simple status UI for `init.sh` worker stacks (GOLD, ETHUSD, …) at **`https://zone4.xauusd.bar/making/`**.

## Docker (default)

Image **`dexterquazi/alphafx:making`** runs the dashboard and all `init.sh` workers in one container.

```bash
./docker/build-push.sh    # build + push (laptop or CI)
./deploy.sh               # EC2: pull image, volumes under ~/making-data, port 8877
```

See **`docker/README.md`**. After a container recreate, **Start** each stack from the UI (PIDs do not survive).

## Install (legacy systemd on host)

```bash
cd ~/making && git pull
chmod +x dashboard/install-dashboard.sh
./dashboard/install-dashboard.sh
```

1. **`making-dashboard.service`** — Python server on `127.0.0.1:8877`
2. **`nginx-making-proxy.inc`** — copied into `~/alphafx-router-docker/nginx/conf.d/` and included from `xauusd-bar-routes.inc`
3. Rebuild/restart **`alphafx-router`** so nginx picks up `/making/` and can reach the host (`host.docker.internal:8877` or host gateway IP)

## Router container

The router image must resolve the EC2 host from inside Docker. Prefer recreate with:

```text
--add-host=host.docker.internal:host-gateway
```

If `host.docker.internal` is unavailable, edit `making-proxy.inc` upstream to `172.17.0.1:8877` (docker bridge gateway).

## Login

- Password is `DASHBOARD_PASSWORD` in `dashboard/dashboard.env` (default **alphafx** on fresh install).
- Open **https://zone4.xauusd.bar/making/login** — session cookie lasts 14 days; **Log out** on the main page.

## API

| Method | Path | Auth |
|--------|------|------|
| GET | `/making/api/health` | no |
| POST | `/making/api/login` | `{"password":"..."}` → Set-Cookie |
| POST | `/making/api/logout` | clears cookie |
| GET | `/making/api/session` | cookie optional |
| GET | `/making/api/status` | session cookie |
| POST | `/making/api/control` | session cookie |

Control body: `{"env_file":"env/ETH.env","action":"restart","skip_primary":false}`

## Stacks / env files (UI)

- **+ Add stack** — upload `.env` from your laptop, clone an existing file on the server, or start from the GOLD template; saves under `env/*.env`.
- **Edit .env** — form fields or raw file; updates `var.env` or `env/*`.
- **Delete** — stops workers and removes `env/*.env` only (`var.env` cannot be deleted).

CLI equivalent: `./init.sh ps --all --json`