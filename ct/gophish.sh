#!/usr/bin/env bash

# GoPhish LXC Container Creator for Proxmox VE
# https://github.com/erk91495/proxmox-scripts
#
# This script creates a Debian 12 LXC container and installs GoPhish
# (https://getgophish.com) — an open-source phishing framework.
#
# Usage: bash -c "$(wget -qLO - https://raw.githubusercontent.com/erk91495/proxmox-scripts/main/ct/gophish.sh)"

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

# ── Default container settings ────────────────────────────────────────────────
APP="GoPhish"
var_disk="4"       # GB
var_cpu="2"
var_ram="512"      # MB
var_os="debian"
var_version="12"
NSAPP=$(echo ${APP,,} | tr -d ' ')
var_install="${NSAPP}-install"
INTEGER='^[0-9]+([.][0-9]+)?$'

# ── Helpers ───────────────────────────────────────────────────────────────────
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; }

die() {
  msg_error "$1"
  exit 1
}

# ── Verify running on Proxmox ─────────────────────────────────────────────────
[[ -f /etc/pve/local/pve-ssl.pem ]] || die "This script must be run on a Proxmox VE node."
pveversion | grep -q "pve-manager/[89]" || die "Proxmox VE 8 or 9 required."

# ── Interactive setup ─────────────────────────────────────────────────────────
echo -e "\n${BL}Creating ${APP} LXC Container${CL}\n"

# Storage selection
STORAGE_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
  FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec 2>/dev/null | awk '{printf "%9sB", $6}')
  ITEM="${TAG} Type:${TYPE} Free:${FREE:-N/A} "
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content rootdir | awk 'NR>1')

if [[ ${#STORAGE_MENU[@]} -eq 0 ]]; then
  die "Unable to detect a valid storage location."
elif [[ ${#STORAGE_MENU[@]} -eq 3 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Storage Pools" \
    --radiolist "Select storage for the container:\n\n" \
    16 60 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || die "Storage selection cancelled."
fi

# Container ID
NEXTID=$(pvesh get /cluster/nextid)
CT_ID=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Container ID" \
  --inputbox "Set Container ID:" 8 58 "$NEXTID" \
  3>&1 1>&2 2>&3) || die "Container ID input cancelled."
[[ "$CT_ID" =~ $INTEGER ]] || die "Invalid Container ID."

# Hostname
HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Hostname" \
  --inputbox "Set hostname:" 8 58 "gophish" \
  3>&1 1>&2 2>&3) || die "Hostname input cancelled."

# Disk size
DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Disk Size (GB)" \
  --inputbox "Set disk size in GB:" 8 58 "$var_disk" \
  3>&1 1>&2 2>&3) || die "Disk size input cancelled."
[[ "$DISK_SIZE" =~ $INTEGER ]] || die "Invalid disk size."

# CPU cores
CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "CPU Cores" \
  --inputbox "Allocate CPU cores:" 8 58 "$var_cpu" \
  3>&1 1>&2 2>&3) || die "CPU input cancelled."
[[ "$CORE_COUNT" =~ $INTEGER ]] || die "Invalid CPU count."

# RAM
RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "RAM (MB)" \
  --inputbox "Allocate RAM in MB:" 8 58 "$var_ram" \
  3>&1 1>&2 2>&3) || die "RAM input cancelled."
[[ "$RAM_SIZE" =~ $INTEGER ]] || die "Invalid RAM size."

# Bridge
BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Network Bridge" \
  --inputbox "Set network bridge:" 8 58 "vmbr0" \
  3>&1 1>&2 2>&3) || die "Bridge input cancelled."

# IP
NET=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "IP Address" \
  --inputbox "Set IP address (cidr) or 'dhcp':" 8 58 "dhcp" \
  3>&1 1>&2 2>&3) || die "IP input cancelled."

if [[ "$NET" != "dhcp" ]]; then
  GATE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Gateway" \
    --inputbox "Set gateway IP address:" 8 58 "" \
    3>&1 1>&2 2>&3) || die "Gateway input cancelled."
fi

# Unprivileged
if whiptail --backtitle "Proxmox VE Helper Scripts" \
   --title "Container Type" \
   --yesno "Use unprivileged container?" 8 58; then
  PVE_FLAGS="-unprivileged 1"
else
  PVE_FLAGS="-unprivileged 0"
fi

# Root password
ROOT_PW=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Root Password" \
  --passwordbox "Set root password (leave blank for auto):" 9 58 "" \
  3>&1 1>&2 2>&3) || die "Password input cancelled."
[[ -z "$ROOT_PW" ]] && ROOT_PW=$(openssl rand -base64 18 | tr -d '=+/')

# SSH key
SSH_KEY=""
if whiptail --backtitle "Proxmox VE Helper Scripts" \
   --title "SSH Key" \
   --yesno "Add an SSH public key?" 8 58; then
  SSH_KEY=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "SSH Public Key" \
    --inputbox "Paste your SSH public key:" 8 72 "" \
    3>&1 1>&2 2>&3)
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} LXC — Summary" \
  --msgbox "
  App        : ${APP}
  CT ID      : ${CT_ID}
  Hostname   : ${HN}
  OS         : ${var_os} ${var_version}
  Disk       : ${DISK_SIZE} GB on ${STORAGE}
  CPU        : ${CORE_COUNT} cores
  RAM        : ${RAM_SIZE} MB
  Bridge     : ${BRG}
  IP         : ${NET}
  " 18 58 || die "Aborted."

# ── Download template ─────────────────────────────────────────────────────────
TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1{print $1; exit}')
[[ -z "$TEMPLATE_STORAGE" ]] && TEMPLATE_STORAGE="local"

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Downloading ${var_os} ${var_version} template"
  pveam update &>/dev/null
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" &>/dev/null \
    || die "Failed to download template."
  msg_ok "Downloaded template"
fi

# ── Create container ──────────────────────────────────────────────────────────
msg_info "Creating ${APP} LXC container (${CT_ID})"

DISK_REF="${STORAGE}:${DISK_SIZE}"
NET_CONFIG="name=eth0,bridge=${BRG},firewall=1"
if [[ "$NET" == "dhcp" ]]; then
  NET_CONFIG+=",ip=dhcp"
else
  NET_CONFIG+=",ip=${NET}"
  [[ -n "${GATE:-}" ]] && NET_CONFIG+=",gw=${GATE}"
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
  -hostname "$HN" \
  -cores "$CORE_COUNT" \
  -memory "$RAM_SIZE" \
  -rootfs "$DISK_REF" \
  -net0 "$NET_CONFIG" \
  -onboot 1 \
  -features nesting=1 \
  $PVE_FLAGS \
  &>/dev/null || die "Failed to create container."

msg_ok "Created LXC container ${CT_ID}"

# ── Set root password (and optional SSH key) ──────────────────────────────────
echo "root:${ROOT_PW}" | pct exec "$CT_ID" -- /bin/sh -c "chpasswd" 2>/dev/null || true

if [[ -n "$SSH_KEY" ]]; then
  pct exec "$CT_ID" -- /bin/sh -c "
    mkdir -p /root/.ssh
    echo '${SSH_KEY}' >> /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
  " 2>/dev/null || true
fi

# ── Start container and run installer ────────────────────────────────────────
msg_info "Starting container"
pct start "$CT_ID" &>/dev/null
sleep 5
msg_ok "Container started"

msg_info "Installing ${APP} (this may take a few minutes)"

SCRIPT_URL="https://raw.githubusercontent.com/erk91495/proxmox-scripts/main/install/${var_install}.sh"

pct exec "$CT_ID" -- /bin/bash -c "
  apt-get update -qq &>/dev/null
  apt-get install -y curl wget &>/dev/null
  bash <(curl -fsSL '${SCRIPT_URL}')
" || die "Installation script failed."

msg_ok "${APP} installed"

# ── Summary ───────────────────────────────────────────────────────────────────
IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
echo -e "
${GN}────────────────────────────────────────────────────${CL}
 ${APP} is ready!

  Admin UI  : ${BL}https://${IP}:3333${CL}
  Username  : ${YW}admin${CL}
  Password  : (set on first login)
  CT ID     : ${CT_ID}
  Root PW   : ${YW}${ROOT_PW}${CL}

  NOTE: Change the admin password immediately after
  your first login at https://${IP}:3333/login
${GN}────────────────────────────────────────────────────${CL}
"
