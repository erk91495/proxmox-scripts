#!/usr/bin/env bash

# GoPhish Install Script
# Runs inside a Debian 12 LXC container created by ct/gophish.sh
# https://github.com/erk91495/proxmox-scripts

set -Eeuo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m")
CM='\xE2\x9C\x94\033[0m'
CROSS='\xE2\x9C\x97\033[0m'
BFR="\\r\\033[K"
HOLD="-"
CL=$(echo "\033[m")

msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; }

die() { msg_error "$1"; exit 1; }

# ── Must run as root ──────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."

# ── Resolve latest GoPhish release ───────────────────────────────────────────
msg_info "Fetching latest GoPhish release"
LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/gophish/gophish/releases/latest") \
  || die "Failed to query GitHub API."

GOPHISH_VERSION=$(echo "$LATEST_JSON" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[[ -n "$GOPHISH_VERSION" ]] || die "Could not determine latest GoPhish version."

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_LABEL="linux-amd64" ;;
  aarch64) ARCH_LABEL="linux-arm64" ;;
  *)       die "Unsupported architecture: $ARCH" ;;
esac

DOWNLOAD_URL=$(echo "$LATEST_JSON" \
  | grep '"browser_download_url"' \
  | grep "${ARCH_LABEL}" \
  | grep '\.zip"' \
  | head -1 \
  | cut -d'"' -f4)
[[ -n "$DOWNLOAD_URL" ]] || die "Could not find a download URL for ${ARCH_LABEL}."

msg_ok "Found GoPhish ${GOPHISH_VERSION} (${ARCH_LABEL})"

# ── System dependencies ───────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &>/dev/null
apt-get upgrade -y -qq &>/dev/null
msg_ok "System updated"

msg_info "Installing dependencies"
apt-get install -y -qq \
  curl wget unzip ca-certificates \
  &>/dev/null
msg_ok "Dependencies installed"

# ── Create dedicated service user ─────────────────────────────────────────────
msg_info "Creating gophish system user"
if ! id -u gophish &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin gophish
fi
msg_ok "User created"

# ── Download & install GoPhish ────────────────────────────────────────────────
INSTALL_DIR="/opt/gophish"
TMP_DIR=$(mktemp -d)

msg_info "Downloading GoPhish ${GOPHISH_VERSION}"
wget -qO "${TMP_DIR}/gophish.zip" "$DOWNLOAD_URL" \
  || die "Failed to download GoPhish."
msg_ok "Downloaded GoPhish"

msg_info "Installing GoPhish to ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
unzip -oq "${TMP_DIR}/gophish.zip" -d "${TMP_DIR}/extracted"
cp -r "${TMP_DIR}/extracted/." "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/gophish"
chown -R gophish:gophish "${INSTALL_DIR}"
rm -rf "$TMP_DIR"
msg_ok "GoPhish installed"

# ── Configure GoPhish ─────────────────────────────────────────────────────────
msg_info "Writing configuration"

# Backup original if present
[[ -f "${INSTALL_DIR}/config.json" ]] \
  && cp "${INSTALL_DIR}/config.json" "${INSTALL_DIR}/config.json.bak"

cat > "${INSTALL_DIR}/config.json" <<'EOF'
{
  "admin_server": {
    "listen_url": "0.0.0.0:3333",
    "use_tls": true,
    "cert_path": "gophish_admin.crt",
    "key_path": "gophish_admin.key"
  },
  "phish_server": {
    "listen_url": "0.0.0.0:80",
    "use_tls": false,
    "cert_path": "example.crt",
    "key_path": "example.key"
  },
  "db_name": "sqlite3",
  "db_path": "gophish.db",
  "migrations_prefix": "db/db_",
  "contact_address": "",
  "logging": {
    "filename": "",
    "level": ""
  }
}
EOF

chown gophish:gophish "${INSTALL_DIR}/config.json"
msg_ok "Configuration written"

# ── Systemd service ───────────────────────────────────────────────────────────
msg_info "Creating systemd service"
cat > /etc/systemd/system/gophish.service <<EOF
[Unit]
Description=GoPhish Phishing Framework
Documentation=https://getgophish.com/documentation/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=gophish
Group=gophish
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/gophish
Restart=on-failure
RestartSec=5
# Harden the service
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload &>/dev/null
systemctl enable --now gophish &>/dev/null
msg_ok "Systemd service enabled and started"

# ── Firewall (ufw) — optional ─────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  msg_info "Configuring UFW firewall rules"
  ufw allow 3333/tcp comment "GoPhish admin" &>/dev/null
  ufw allow 80/tcp   comment "GoPhish phishing (HTTP)" &>/dev/null
  ufw allow 443/tcp  comment "GoPhish phishing (HTTPS)" &>/dev/null
  msg_ok "UFW rules added"
fi

# ── Fetch initial admin password from logs ────────────────────────────────────
msg_info "Waiting for GoPhish to start and generate credentials"
sleep 5
INITIAL_PW=""
for i in {1..10}; do
  INITIAL_PW=$(journalctl -u gophish --no-pager -n 50 2>/dev/null \
    | grep -oP '(?<=Please login with the username admin and the password )[^\s]+' \
    | head -1 || true)
  [[ -n "$INITIAL_PW" ]] && break
  sleep 3
done
msg_ok "GoPhish started"

# ── Done ──────────────────────────────────────────────────────────────────────
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "
${GN}────────────────────────────────────────────────────${CL}
 GoPhish ${GOPHISH_VERSION} installation complete!

  Admin UI   : ${BL}https://${IP}:3333${CL}
  Phish HTTP : ${BL}http://${IP}:80${CL}
  Username   : ${YW}admin${CL}
  Password   : ${YW}${INITIAL_PW:-<see: journalctl -u gophish>}${CL}
  Install dir: ${INSTALL_DIR}

  IMPORTANT: You will be forced to change the password
  on first login. Store it safely!
${GN}────────────────────────────────────────────────────${CL}
"
