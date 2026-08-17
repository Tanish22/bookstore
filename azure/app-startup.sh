#!/bin/bash
# /opt/bookstore/startup.sh
# Runs on every boot via systemd (bookstore-startup.service).
# Downloads app code from Blob Storage, fetches secrets from Key Vault,
# writes the .env file, installs dependencies, then enables the backend service.

# Exit immediately if any command fails.
# Without this, the script would silently continue past a failed download
# and try to start Node.js with missing or stale code.
set -e

# Redirect all output (stdout + stderr) to a log file AND to the journal.
# This means you can check both: cat /var/log/bookstore-startup.log
# and: journalctl -u bookstore-startup
exec > >(tee -a /var/log/bookstore-startup.log) 2>&1

echo "=============================================="
echo "Bookstore startup script — $(date)"
echo "=============================================="

# -------------------------------------------------------
# CONFIGURATION — change these if resource names change
# -------------------------------------------------------
UAMI_CLIENT_ID="YOUR_UAMI_CLIENT_ID_HERE"
STORAGE_ACCOUNT="stbookstorecentind01"
CONTAINER="app-code"
BACKEND_BLOB="backend.zip"
KEY_VAULT_NAME="kv-bookstore-cent-ind-01"
SECRET_NAME="cosmos-connection-string"
DEPLOY_DIR="/opt/bookstore/backend"
PORT="5555"

# -------------------------------------------------------
# Step 1: Authenticate az CLI using User-Assigned MI
# -------------------------------------------------------
# The IMDS (Instance Metadata Service) at 169.254.169.254 provides tokens.
# The az CLI knows to use IMDS when --identity is specified.
# --username with the Client ID specifies WHICH identity to use.
# This is important: if the VM had multiple UAMIs attached,
# az login --identity without --username picks one arbitrarily.
# Always specify the Client ID explicitly.

echo "Step 1: Authenticating with UAMI..."

# Retry loop — IMDS can take a few seconds to be ready at boot
MAX_RETRIES=12
RETRY_INTERVAL=5
AUTHENTICATED=false

for i in $(seq 1 $MAX_RETRIES); do
  if az login --identity --username "$UAMI_CLIENT_ID" --output none 2>/dev/null; then
    echo "UAMI authentication successful (attempt $i)"
    AUTHENTICATED=true
    break
  fi
  echo "Attempt $i/$MAX_RETRIES failed. Waiting ${RETRY_INTERVAL}s..."
  sleep "$RETRY_INTERVAL"
done

if [ "$AUTHENTICATED" = false ]; then
  echo "ERROR: Failed to authenticate with UAMI after $MAX_RETRIES attempts."
  echo "Check: Is the UAMI attached to this VM? Is the Client ID correct?"
  exit 1
fi

# -------------------------------------------------------
# Step 2: Download backend code from Blob Storage
# -------------------------------------------------------
echo "Step 2: Downloading backend.zip from Blob Storage..."

az storage blob download \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "$BACKEND_BLOB" \
  --file "/tmp/backend.zip" \
  --auth-mode login \
  --overwrite \
  --output none

echo "Download complete."

# -------------------------------------------------------
# Step 3: Extract backend code
# -------------------------------------------------------
echo "Step 3: Extracting backend.zip to $DEPLOY_DIR..."

# Clean the deploy directory first — ensures no stale files from previous boots
# (e.g., if you uploaded a new backend.zip that removed some files)
rm -rf "${DEPLOY_DIR:?}"/*

# Unzip into the deploy directory
# backend.zip was created with: cd backend/ && zip -r backend.zip .
# So the zip contains files at root: index.js, package.json, routes/, etc.
# After unzip, DEPLOY_DIR contains those files directly.
unzip -q /tmp/backend.zip -d "$DEPLOY_DIR/"

# Clean up the temp file
rm /tmp/backend.zip

echo "Extraction complete."

# -------------------------------------------------------
# Step 4: Fetch CosmosDB connection string from Key Vault
# -------------------------------------------------------
echo "Step 4: Fetching connection string from Key Vault..."

MONGO_URI=$(az keyvault secret show \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$SECRET_NAME" \
  --query "value" \
  --output tsv)

if [ -z "$MONGO_URI" ]; then
  echo "ERROR: Connection string is empty. Check Key Vault secret name and RBAC assignment."
  exit 1
fi

echo "Connection string fetched successfully."

# -------------------------------------------------------
# Step 5: Write the .env file
# -------------------------------------------------------
# The .env file is written fresh on every boot.
# It never exists in the image — only in the running instance's filesystem.
# If the instance is terminated, the secret is gone with it.
# The next instance fetches a fresh copy from Key Vault.

echo "Step 5: Writing .env file..."

# IMPORTANT: Check your actual backend env variable names.
# If your backend uses MONGODB_URI instead of MONGO_URI, change it here.
# The variable name here must match exactly what your backend code reads:
# e.g., process.env.MONGO_URI or process.env.MONGODB_URI
cat > "$DEPLOY_DIR/.env" << EOF
PORT=$PORT
NODE_ENV=production
MONGO_URI=$MONGO_URI
EOF

# Restrict to root only — nodeapp reads it via systemd EnvironmentFile (read by root)
chmod 600 "$DEPLOY_DIR/.env"
chown root:root "$DEPLOY_DIR/.env"

echo ".env file written."

# -------------------------------------------------------
# Step 6: Install npm dependencies
# -------------------------------------------------------
echo "Step 6: Running npm install..."

cd "$DEPLOY_DIR"

# --production: skips devDependencies (test libraries, build tools)
# These aren't needed on the server and add unnecessary size and security surface
npm install --production

echo "npm install complete."

# Set correct ownership after npm install creates node_modules
chown -R root:nodeapp "$DEPLOY_DIR"
chmod -R 750 "$DEPLOY_DIR"
# .env stays 600 root:root
chmod 600 "$DEPLOY_DIR/.env"
chown root:root "$DEPLOY_DIR/.env"

# -------------------------------------------------------
# Step 7: Start the backend service
# -------------------------------------------------------
echo "Step 7: Starting bookstore-backend service..."

systemctl daemon-reload
systemctl enable bookstore-backend
systemctl restart bookstore-backend

echo "bookstore-backend service started."
echo "=============================================="
echo "Startup script complete — $(date)"
echo "=============================================="