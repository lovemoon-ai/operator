# operator deploy on the volc box

This subdir holds the bits that make `operator.conductor-ai.top` run on
the same volc machine as `conductor-ai.top` (root@115.190.243.112). The
two sites coexist as independent nginx server blocks, independent
systemd units, independent ports, independent on-disk trees.

| file | purpose |
|---|---|
| `bootstrap.sh` | first-run setup: apt deps, data dir, build, systemd unit, nginx site |
| `deploy.sh` | re-deploy on every push: git pull, rebuild, restart |
| `nginx.conf` | nginx site block (canonical, both HTTP and HTTPS sections; bootstrap auto-strips HTTPS until certbot runs) |
| `operator-web.service` | systemd unit (Type=simple, nvm sourced via bash -lc) |

## One-time install

```bash
ssh -i ~/code/scripts/envrc/volcengine-robotcloud.pem root@115.190.243.112

# clone
mkdir -p /opt/conductor/operator
git clone github-dang217:lovemoon-ai/operator.git /opt/conductor/operator
cd /opt/conductor/operator

# run bootstrap
bash web/deploy/bootstrap.sh
```

The bootstrap prints next-step instructions for:
1. editing `web/app/.env.production` (especially OIDC + secret keys),
2. starting the service,
3. reloading nginx,
4. adding the DNS A record at your provider,
5. running `certbot --nginx -d operator.conductor-ai.top`.

## Re-deploy on every push

```bash
ssh ... root@115.190.243.112
bash /opt/conductor/operator/web/deploy/deploy.sh
```

`deploy.sh` does an atomic build (`.next.build` → swap to `.next`) so
the live process never reads a half-written bundle.

## Process isolation from conductor

Both apps use `tsx server.ts`, so a naïve `pkill -f "tsx server.ts"`
would catch both. We address it on two fronts:

1. **operator side**: `server.ts` sets `process.title = "operator-web"`
   so it shows up distinctly in `ps`.
2. **conductor side**: `conductor/scripts/deploy-prod.sh` scopes its
   pkill to `/opt/conductor/conductor/.*server.ts` (path-anchored
   regex) so it never matches an operator process.

If conductor reverts to a broad pkill, operator's systemd will restart
the killed process within 5 seconds (`Restart=on-failure`). The data
is on disk, so the brief downtime is the only cost.

## Layout

```
/opt/conductor/conductor/  ← conductor main app (port 6152)
/opt/conductor/operator/   ← this app (port 6153)
/opt/operator-data/        ← sqlite db + uploaded sessions + backups
  ├── operator.db
  ├── sessions/<sessionId>/{manifest.json,media.mp4,preview.mp4,session.rrd}
  └── seed/                ← drop demo files here, they hardlink into per-user demo sessions
```

The app's `web/app/data` is a symlink to `/opt/operator-data` so
relocating the data tier is a one-symlink change.
