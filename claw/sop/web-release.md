# SOP: release `web/` to production

Standard procedure for shipping changes to the operator dashboard
(`https://operator.conductor-ai.top`).

The site rides on the same volc box as conductor, but with its own
systemd unit, nginx server block, port, and data directory — so this
SOP is independent of conductor's release.

## Establish deployment context first

Before doing anything, gather these facts so the rest of the steps
are unambiguous.

1. **Repo structure**
   - `web/app/` — Next.js 15 dashboard + custom Express server
     (`server.ts`). Includes auth, ingest read API, reviews router,
     post-ingest workers.
   - `web/modules/ego-ingest/` — workspace package; TUS upload
     middleware + session store interfaces. Built into `dist/` by
     `build:ingest` before each Next build.
   - `web/deploy/` — deploy assets (`bootstrap.sh`, `deploy.sh`,
     `nginx.conf`, `operator-web.service`). **The scripts already live
     on the production box** at `/opt/conductor/operator/web/deploy/`;
     a local change to them only takes effect after the next deploy
     finishes running the old version of `deploy.sh`.

2. **Key deployment semantics**
   - The production site is `https://operator.conductor-ai.top`.
   - **The production machine connection method and remote path are
     subject to `make -f ~/code/scripts/makefile/Makefile.conductor info-volc`.**
     Run that locally to print the current ssh command + repo path; do
     not hard-code either of those values into commits, chat, or
     scripts that get checked in.
   - The current standard remote path is `/opt/conductor/operator`.
   - The branch on `origin` that production tracks is
     `multi-user-dashboard`. **Code that hasn't been pushed to that
     branch will not be on the box** — `deploy.sh` does
     `git pull --ff-only` on whatever branch is checked out remotely.
   - `web/app/data/` is a **symlink** to `/opt/operator-data/`. Don't
     touch it in commits; the DB and uploaded sessions live there
     across deploys.
   - There's no DB migration tool. Schema lives in
     `web/app/lib/db.ts` and is applied by `CREATE TABLE IF NOT EXISTS`
     on every boot. **Adding columns** requires writing an explicit
     `ALTER TABLE` underneath the schema (idempotent guard with a
     `PRAGMA table_info` check).
   - **`web/app/.env.production`** holds production secrets
     (`AUTH_SESSION_SECRET`, `INGEST_CONNECT_SECRET`,
     `CONDUCTOR_CLIENT_SECRET`, etc.). Edited in place on the box;
     never committed.
   - Better-sqlite3 is a native module — if Node major version
     changes on the box, run `npm rebuild better-sqlite3` before the
     next deploy.

3. **Signals to check during deployment**
   - Local `git status --short`
   - Local `git push origin multi-user-dashboard` succeeded
   - Whether the diff touches `web/app/lib/db.ts` (schema changes
     need extra care)
   - Whether the diff touches `web/app/package.json` (deps change
     means `npm install` is needed; `deploy.sh` runs it
     unconditionally so this is fine)
   - Whether the diff touches `web/deploy/operator-web.service` or
     `web/deploy/nginx.conf` (need a manual extra step — see below)
   - Remote `git rev-parse --short HEAD` after the pull
   - `journalctl -u operator-web -n 30 --no-pager` for healthy boot
     log: `[ego-app] http://localhost:6153/` and
     `[ego-app] auth Conductor SSO https://conductor-ai.top`
   - Status code of `http://127.0.0.1:6153/api/ingest-read/sessions`
     should be `401` (auth-gated; that means the service is up and
     middleware works)
   - `https://operator.conductor-ai.top/login` returns `200` with
     `login-shell` and `SSO 登录` markers in the body

## Recommended deployment workflow

### 1. Local

```bash
# confirm clean tree + push
git status --short
git diff --stat HEAD~1                            # eyeball what's shipping
git push origin multi-user-dashboard

# pull the volc connection details (do NOT paste the output into
# commits or shared docs — it includes a private key path):
make -f ~/code/scripts/makefile/Makefile.conductor info-volc
```

### 2. Remote (ssh into volc using the output above)

```bash
cd /opt/conductor/operator
git rev-parse --short HEAD                        # current live commit
git status --short                                # expect: clean

# the standard path — git pull + npm install + build + restart + health:
bash web/deploy/deploy.sh
```

`deploy.sh` does, in order:

1. `git pull --ff-only` on the current branch
2. `npm install` (idempotent; only pulls deltas)
3. `npm run build:ingest` (compiles the ego-ingest workspace package)
4. `NEXT_DIST_DIR=.next.build npx next build` (writes the new
   bundle to `app/.next.build/`, **leaves the live `.next/` alone**)
5. Atomic swap: `mv .next .next.old && mv .next.build .next`
6. `systemctl restart operator-web`
7. Polls `http://127.0.0.1:6153/api/ingest-read/sessions` until it
   answers `401` (auth-gated, so 401 = service up + middleware OK)

If step 4 fails, the live `.next/` is untouched and the service stays
on the old version. If step 6/7 fails, see "Rollback" below.

### 3. Manual smoke (recommended for non-trivial diffs)

```bash
# from your laptop
curl -sS -o /dev/null -w '%{http_code}\n' https://operator.conductor-ai.top/login
# expect 200

# open in browser, click "SSO 登录", confirm it bounces through
# conductor-ai.top and lands back on operator's home page
open https://operator.conductor-ai.top/
```

## Workflow variations by what changed

| Change | Extra step beyond `deploy.sh` |
| --- | --- |
| TS / TSX / CSS only | none — `deploy.sh` covers it |
| `web/app/lib/db.ts` schema | sqlite has no migration tool; add an `ALTER TABLE IF NOT EXISTS` next to the `CREATE TABLE` block, idempotent. Test against a copy of the DB first. |
| `web/app/package.json` deps | `deploy.sh` runs `npm install` every time, so nothing extra. If a dep change broke the build, the atomic swap protects production. |
| `web/deploy/operator-web.service` | `deploy.sh` does NOT reload systemd units. Manually: `cp web/deploy/operator-web.service /etc/systemd/system/ && systemctl daemon-reload && systemctl restart operator-web` |
| `web/deploy/nginx.conf` | certbot has already rewritten the live `/etc/nginx/sites-available/operator` to include the 443 + ssl_* block; copying `nginx.conf` over would erase that. Either hand-patch the live file or copy + re-run `certbot --nginx -d operator.conductor-ai.top` to re-add the cert block. |
| `web/app/.env.production` content | edit on the box; `systemctl restart operator-web`. No build. |
| Demo seed data in `/opt/operator-data/seed/` | `scp` the new files. Optionally `sqlite3 /opt/operator-data/operator.db "UPDATE users SET seeded=0;"` to have existing users get the refreshed demo on next login. |
| Conductor SSO client config | This is a **conductor-side** change, not operator. Edit conductor's `web/.env.production.local` and restart conductor; operator just needs its `CONDUCTOR_CLIENT_SECRET` to match. |

## Rollback

If a deploy is bad, get back to the previous commit:

```bash
# on the volc box, inside /opt/conductor/operator
PREV=$(git log -1 --format=%H 'HEAD@{1}')         # commit before the pull
echo "rolling back to $PREV"
git reset --hard "$PREV"
bash web/deploy/deploy.sh
```

The build will reproduce the old bundle. `journalctl -u operator-web -f`
to watch it come back.

If the build itself is what failed (you never got to the systemd
restart), `app/.next/` is still the old bundle — just
`git reset --hard $PREV` and skip the rebuild; the service is already
on the working code.

## Healthy state checklist

After every deploy, the box should look like this:

```
systemctl is-active operator-web      → active
systemctl is-active nginx             → active
ss -tlnp | grep :6153                 → operator-web listening
ss -tlnp | grep :6152                 → conductor listening (unrelated, just confirming we didn't break it)
ls /opt/conductor/operator/web/app/.next/BUILD_ID  → exists
ls /opt/operator-data/operator.db                  → exists
```

API smokes:

```
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://operator.conductor-ai.top/login                  → 200
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://operator.conductor-ai.top/                       → 302  (→ /login)
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X OPTIONS -H 'Tus-Resumable: 1.0.0' \
  https://operator.conductor-ai.top/api/ingest             → 401  (auth gate)
```

## Logs

```
journalctl -u operator-web -f             # application logs (Express + Next)
journalctl -u operator-web -n 200         # last 200 lines, useful after deploy
tail -f /var/log/nginx/access.log         # request log
tail -f /var/log/nginx/error.log          # 5xx / upstream issues
sqlite3 /opt/operator-data/operator.db    # poke the DB
```

## Recommended commands

```
make -f ~/code/scripts/makefile/Makefile.conductor info-volc
git status --short
git push origin multi-user-dashboard
git diff --name-only HEAD~1 -- web/app/lib/db.ts web/app/package.json web/deploy/
ssh <use info-volc output>
cd /opt/conductor/operator
git rev-parse --short HEAD
bash web/deploy/deploy.sh
journalctl -u operator-web -n 50 --no-pager
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6153/api/ingest-read/sessions
```

## When NOT to use `deploy.sh`

- **First-time setup on a fresh box**: use `web/deploy/bootstrap.sh`
  instead. It additionally `apt`-installs ffmpeg + sqlite3, creates
  `/opt/operator-data/`, writes the systemd unit, installs the nginx
  site, generates a starter `.env.production`. After bootstrap, the
  box runs `deploy.sh` for every subsequent release.
- **Env-only changes**: just edit `.env.production` and
  `systemctl restart operator-web`. Faster, no rebuild.
- **Conductor (the parent app, not operator)** redeploys: that's a
  different SOP entirely — see conductor's own `claw/sop/deploy-to-prod.md`.
  Our patched `pkill` regex in conductor's deploy script means a
  conductor redeploy will not touch operator, but the deploys are
  independent operations.

## References

- `web/deploy/README.md` — deploy asset layout
- `web/deploy/bootstrap.sh` — one-time provisioning
- `web/deploy/deploy.sh` — per-release flow (source of truth for the
  steps above)
- `claw/rfcs/` — architecture decisions affecting the dashboard
