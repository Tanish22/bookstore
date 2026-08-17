# VMSS Instance Bootstrap Sequence

When Azure creates a new VMSS instance,it boots from a generalized image that has no running application. The instance
bootstraps itself using systemd services and startup scripts baked into the image.


## App VMSS (Node.js backend)

Three files work in sequence:

### 1. `bookstore-startup.service` (Type=oneshot)
- Triggered: automatically at boot, after `network-online.target`
- Runs : `/opt/bookstore/app-startup.sh`
- What the script does:
  1. Authenticates to Azure using UAMI via IMDS endpoint (no credentials stored on disk)
  2. Pulls `COSMOSDB_URI` and `SECRET` from Key Vault (`kv-bookstore-cent-ind-01`)
  3. Writes them to `/opt/bookstore/.env`
  4. Downloads `backend.zip` from Blob Storage (`stgbookstorecentind`)
  5. Extracts to `/opt/bookstore/backend/`
- Why oneshot: this script runs once and exits. `RemainAfterExit=yes` keeps the
  unit in "active" state so `bookstore-backend.service` can depend on it.

### 2. `bookstore-backend.service` (Type=simple)
- Triggered: only after `bookstore-startup.service` completes (via `After=` + `Requires=`)
- Runs: `node index.js` as user `nodeapp` (no shell, no login — least privilege)
- Reads secrets from `/opt/bookstore/.env` via `EnvironmentFile=`
- Listens on port 5555

**Why the dependency chain matters:**
If startup.sh fails (e.g. Key Vault unreachable), `bookstore-startup.service`
exits with error. `bookstore-backend.service` never starts. The VMSS health probe at `/api/health` on port 5555 gets no response => instance marked unhealthy => Azure replaces it. The failure surfaces through the health probe, not silently.


## Web VMSS (Nginx frontend)

Two files. No dedicated frontend service because nginx itself is already a service.

### 1. `bookstore-web-startup.service` (Type=oneshot)
- Triggered: at boot, after `network-online.target` and `nginx.service`
- Runs: `/opt/bookstore-web/startup.sh`
- What the script does:
  1. Authenticates via UAMI
  2. Downloads `frontend-dist.zip` from Blob Storage
  3. Extracts React build to `/var/www/bookstore/dist/`
  4. Sets ownership to `www-data` (the user Nginx runs as)
  5. Runs `systemctl reload nginx` to serve the new files

### 2. `nginx.service` (system-managed)
- Already running when startup script completes
- Serves static files from `/var/www/bookstore/dist/`
- Proxies `/api/*` requests to Internal Load Balancer at `10.0.2.4:5555`
- The `try_files` directive handles SPA client-side routing (all paths fall back
  to `index.html`)

---

## Why no credentials are stored in the image

The generalized image has no `.env`, no secrets, no connection strings. Each
instance fetches its own secrets at runtime from Key Vault using its UAMI identity.
This means rotating a secret requires only a Key Vault update — no new image needed.