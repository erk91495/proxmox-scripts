# proxmox-scripts

Proxmox VE helper scripts for deploying self-hosted services inside LXC containers.

## GoPhish

Installs [GoPhish](https://getgophish.com) (open-source phishing framework) into a Debian 12 LXC container.

**Run on your Proxmox VE node:**

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/erk91495/proxmox-scripts/main/ct/gophish.sh)"
```

The wizard will prompt for: storage pool, CT ID, hostname, disk/CPU/RAM, network (DHCP or static IP), container type (privileged/unprivileged), root password, and an optional SSH public key.

**After install:**

- Admin UI: `https://<CT-IP>:3333`
- Username: `admin`
- Password: printed at end of install (also visible via `journalctl -u gophish` inside the container)
- Change the password on first login — GoPhish enforces this automatically.

**Defaults:**

| Setting | Value |
|---------|-------|
| OS | Debian 12 |
| Disk | 4 GB |
| CPU | 2 cores |
| RAM | 512 MB |
| Admin port | 3333 (TLS) |
| Phish port | 80 |
| Install path | `/opt/gophish` |
| Service | `systemctl status gophish` |
