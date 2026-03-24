#!/usr/bin/env bash

# GoPhish Install Script
# Runs inside a Debian 12 LXC container created by ct/gophish.sh
# https://github.com/erk91495/proxmox-scripts

set -Eeuo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
YW=$'\033[33m'
GN=$'\033[1;92m'
RD=$'\033[01;31m'
BL=$'\033[36m'
CM=$'\xE2\x9C\x94\033[0m'
CROSS=$'\xE2\x9C\x97\033[0m'
BFR=$'\r\033[K'
HOLD="-"
CL=$'\033[m'

msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; }

die() { msg_error "$1"; exit 1; }

# ── Must run as root ──────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."

# ── Resolve latest GoPhish release (redirect — no API rate limits) ────────────
msg_info "Fetching latest GoPhish release"

GOPHISH_VERSION=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
  "https://github.com/gophish/gophish/releases/latest" \
  | grep -oP 'v[\d.]+$') \
  || die "Failed to resolve latest GoPhish version."
[[ -n "$GOPHISH_VERSION" ]] || die "Could not parse GoPhish version from redirect URL."

# GoPhish only ships linux-64bit; no ARM64 binary available upstream
DOWNLOAD_URL="https://github.com/gophish/gophish/releases/download/${GOPHISH_VERSION}/gophish-${GOPHISH_VERSION}-linux-64bit.zip"
msg_ok "Found GoPhish ${GOPHISH_VERSION}"

# ── System dependencies ───────────────────────────────────────────────────────
msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get upgrade -y -qq >/dev/null 2>&1
msg_ok "System updated"

msg_info "Installing dependencies"
apt-get install -y -qq curl wget unzip ca-certificates libcap2-bin >/dev/null 2>&1
msg_ok "Dependencies installed"

# ── Create dedicated service user ─────────────────────────────────────────────
msg_info "Creating gophish system user"
if ! id -u gophish >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin gophish
fi
msg_ok "User created"

# ── Download & install GoPhish ────────────────────────────────────────────────
INSTALL_DIR="/opt/gophish"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

msg_info "Downloading GoPhish ${GOPHISH_VERSION}"
wget -qO "${TMP_DIR}/gophish.zip" "$DOWNLOAD_URL" \
  || die "Failed to download GoPhish from ${DOWNLOAD_URL}."
msg_ok "Downloaded GoPhish"

msg_info "Installing GoPhish to ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
unzip -oq "${TMP_DIR}/gophish.zip" -d "${TMP_DIR}/extracted"
cp -r "${TMP_DIR}/extracted/." "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/gophish"
# Grant port 80/443 binding without running as root
setcap cap_net_bind_service=+ep "${INSTALL_DIR}/gophish"
chown -R gophish:gophish "${INSTALL_DIR}"
msg_ok "GoPhish installed"

# ── Configure GoPhish ─────────────────────────────────────────────────────────
msg_info "Writing configuration"

[[ -f "${INSTALL_DIR}/config.json" ]] \
  && cp "${INSTALL_DIR}/config.json" "${INSTALL_DIR}/config.json.bak"

cat > "${INSTALL_DIR}/config.json" <<'EOCFG'
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
EOCFG

chown gophish:gophish "${INSTALL_DIR}/config.json"
msg_ok "Configuration written"

# ── Systemd service ───────────────────────────────────────────────────────────
msg_info "Creating systemd service"
cat > /etc/systemd/system/gophish.service <<EOSERVICE
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

[Install]
WantedBy=multi-user.target
EOSERVICE
msg_ok "Systemd service file written"

# Detect whether systemd is the running init (PID 1)
SYSTEMD_ACTIVE=false
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
  SYSTEMD_ACTIVE=true
fi

if $SYSTEMD_ACTIVE; then
  msg_info "Enabling and starting GoPhish service"
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable gophish >/dev/null 2>&1
  if systemctl start gophish >/dev/null 2>&1; then
    msg_ok "GoPhish service started"
  else
    msg_error "Service failed to start — check: journalctl -u gophish"
    systemctl status gophish --no-pager 2>/dev/null || true
    exit 1
  fi

  # ── Fetch initial admin password from service logs ──────────────────────────
  msg_info "Waiting for GoPhish to generate credentials"
  INITIAL_PW=""
  for _ in {1..12}; do
    INITIAL_PW=$(journalctl -u gophish --no-pager -n 50 2>/dev/null \
      | grep -oP '(?<=Please login with the username admin and the password )[^\s]+' \
      | head -1 || true)
    [[ -n "$INITIAL_PW" ]] && break
    sleep 3
  done
  msg_ok "GoPhish is running"
else
  msg_ok "Service file written (systemd not active — start manually or reboot)"
  INITIAL_PW="<run: journalctl -u gophish | grep password>"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "
${GN}────────────────────────────────────────────────────${CL}
 GoPhish ${GOPHISH_VERSION} installation complete!

  Admin UI   : ${BL}https://${IP}:3333${CL}
  Phish HTTP : ${BL}http://${IP}:80${CL}
  Username   : ${YW}admin${CL}
  Password   : ${YW}${INITIAL_PW:-<run: journalctl -u gophish | grep password>}${CL}
  Install dir: ${INSTALL_DIR}

  IMPORTANT: You will be forced to change the password
  on first login. Store it safely!
${GN}────────────────────────────────────────────────────${CL}
"
