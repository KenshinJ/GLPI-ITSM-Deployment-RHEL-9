# GLPI 10.0.24 — Full Deployment Guide

**Target**: RHEL 9.7 VM on Proxmox (`partybus.ops.io`)  
**Stack**: Rootless Podman + MariaDB 10.11 + nginx (TLS proxy)  
**Script**: `glpi.sh` (native podman, no podman-compose required)

---

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Proxmox Host: partybus.ops.io                               │
│  └─ VM: glpi.ops.io (192.168.10.31)                         │
│      └─ RHEL 9.7                                            │
├─────────────────────────────────────────────────────────────┤
│ Host OS                                                     │
│  ├─ nginx (TLS reverse proxy)   :9080 (HTTP) :9443 (HTTPS)  │
│  ├─ firewalld                                               │
│  └─ systemd: glpi-compose.service                           │
├─────────────────────────────────────────────────────────────┤
│ Rootless Podman (user: glpi, UID 1500)                      │
│  ├─ glpi-nginx   (nginx:1.26-alpine)   :127.0.0.1:8081→8082 │
│  ├─ glpi-app     (php:8.3-fpm-alpine)  :9000 (PHP-FPM)      │
│  └─ glpi-db      (mariadb:10.11)       :3306                 │
│      └─ Network: glpi_glpi-net (internal podman bridge)     │
└─────────────────────────────────────────────────────────────┘
```

**Port flow**:  
Client → `:9443` (host nginx TLS) → `:8081` (loopback) → `glpi-nginx` `:8082` → `glpi-app` `:9000` → `glpi-db` `:3306`

---

## Phase 1: Deploy VM in Proxmox

### 1.1 Access Proxmox

```
https://partybus.ops.io:8006
```

Log in with your Proxmox credentials.

### 1.2 Create the VM

In the Proxmox UI:

1. Click **Create VM**
2. **General**
   - Node: `sup-glpi-01`
   - VM ID: `139`
   - Name: `glpi`
3. **OS**
   - Template/ISO: `RHEL 9.7`
4. **System**
   - Machine: `q35`
   - BIOS: `OVMF (UEFI)` or `SeaBIOS` — match your environment
   - SCSI Controller: `VirtIO SCSI`
5. **Disks**
   - Disk size: `20 GB` minimum (5 GB OS + 5 GB GLPI + 5 GB MariaDB + 5 GB backups)
   - Storage: `[PLACEHOLDER: local-lvm or your storage pool]`
   - Bus: `VirtIO`
6. **CPU**
   - Cores: `2` minimum
   - Type: `host` (recommended for RHEL)
7. **Memory**
   - RAM: `4096 MB` (4 GB) minimum
8. **Network — NIC 1 (LANNet)**
   - Bridge: `LANNet`
   - Model: `VirtIO`
9. **Network — NIC 2 (FDSNet)**
   - Click **Add** to add a second network interface
   - Bridge: `FDSNet`
   - Model: `VirtIO`
10. Click **Finish**, then **Start** the VM.

### 1.3 Install the OS

Complete the RHEL 9.7 interactive installer:

- Partition: default (or LVM with `/opt` on a separate volume for GLPI data)
- Hostname: `glpi.ops.io`
- Root password: `[PLACEHOLDER]`
- Create an operator user account: `[PLACEHOLDER: your-username]` with sudo/wheel access

---

## Phase 2: Configure Network

The VM has two NICs — `enp6s18` on **LANNet** (primary, carries GLPI traffic) and `enp6s19` on **FDSNet**.

### 2.1 Configure LANNet (Primary — Static IP)

```bash
nmcli con mod "enp6s18" \
  ipv4.method manual \
  ipv4.addresses "192.168.10.31/24" \
  ipv4.gateway "192.168.10.254" \
  connection.autoconnect yes

nmcli con up "enp6s18"
```

### 2.2 Configure FDSNet (Secondary)

```bash
nmcli con mod "enp6s19" \
  ipv4.method manual \
  ipv4.addresses "192.168.95.115/24" \
  connection.autoconnect yes

nmcli con up "enp6s19"
```

Verify both interfaces:

```bash
ip a
ping -c3 192.168.10.31
```

### 2.3 Set the Hostname

```bash
hostnamectl set-hostname glpi.ops.io
```

### 2.4 Register with RHSM (RHEL only)

Skip this step on AlmaLinux.

```bash
subscription-manager register --username [PLACEHOLDER] --password [PLACEHOLDER]
subscription-manager attach --auto
```

### 2.5 Initial System Update

```bash
dnf update -y
systemctl reboot
```

SSH back in after reboot.

---

## Phase 3: Trust the Internal Root CA

> Skip this phase if no internal CA is in use (e.g., public certificate or self-signed is acceptable).

### 3.1 Copy the Root CA Certificate

Transfer your organization's root CA certificate to the VM:

```bash
# From your workstation:
scp [PLACEHOLDER: /path/to/internal-root-ca.crt] [PLACEHOLDER: user]@192.168.10.31:/tmp/
```

Or place it directly on the VM via Proxmox console or config management.

### 3.2 Install the CA Certificate (RHEL 9)

```bash
sudo cp /tmp/[PLACEHOLDER: internal-root-ca.crt] /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

Verify:

```bash
trust list | grep -i "[PLACEHOLDER: CA name]"
```

### 3.3 Trust the CA for Podman (Container Pulls)

If container images are pulled from an internal registry signed by the CA:

```bash
# Podman inherits system CA trust automatically on RHEL 9
# Verify with a test pull:
podman pull [PLACEHOLDER: internal-registry.ops.io/image:tag]
```

If using a corporate proxy with TLS inspection:

```bash
# Set proxy environment variables in /etc/environment
echo "HTTPS_PROXY=[PLACEHOLDER: https://proxy.ops.io:3128]" | sudo tee -a /etc/environment
echo "HTTP_PROXY=[PLACEHOLDER: http://proxy.ops.io:3128]"   | sudo tee -a /etc/environment
echo "NO_PROXY=localhost,127.0.0.1,[PLACEHOLDER: 192.168.0.0/16]" | sudo tee -a /etc/environment
```

---

## Phase 4: Install Podman

> The deployment script (`glpi.sh`) handles this automatically as part of Phase 5. This phase documents what the script does for visibility or manual pre-installation.

### 4.1 Enable the container-tools Module

```bash
sudo dnf module enable -y container-tools
```

### 4.2 Install Podman and Dependencies

```bash
sudo dnf install -y \
  podman \
  netavark aardvark-dns \
  firewalld nginx openssl \
  jq curl nftables rsync \
  policycoreutils-python-utils container-selinux \
  checkpolicy policycoreutils setools-console \
  acl psmisc iproute tzdata
```

### 4.3 Enable the Podman Socket

```bash
sudo systemctl enable --now podman.socket
```

Verify:

```bash
podman --version
podman info | grep -E "version|os"
```

---

## Phase 5: Deploy GLPI via the Script

### 5.1 Clone the Repository

```bash
cd /opt
sudo git clone https://github.com/KenshinJ/GLPI-Deployment-RHEL-9-.git
cd GLPI-Deployment-RHEL-9-
```

### 5.2 Configure the Environment File

```bash
sudo cp glpi.env.example glpi.env
sudo chmod 600 glpi.env
sudo nano glpi.env
```

**Minimum required values** (fill these in):

| Variable | Description | Your Value |
|----------|-------------|------------|
| `GLPI_HOSTNAME` | FQDN for TLS cert and nginx | `glpi.ops.io` |
| `GLPI_IP` | Static IP of the GLPI VM | `192.168.10.31` |
| `MAIL_HOST` | SMTP relay hostname | `mail.ops.io` |
| `MAIL_IP` | SMTP relay IP | `[PLACEHOLDER]` |
| `ZABBIX_HOST` | Zabbix server hostname | `zabbix.ops.io` |
| `ZABBIX_IP` | Zabbix server IP | `[PLACEHOLDER]` |
| `IDM_HOST` | LDAP/FreeIPA hostname | `idm.ops.io` |
| `IDM_IP` | LDAP/FreeIPA IP | `[PLACEHOLDER]` |

**Defaults that are acceptable for most deployments** (no changes needed unless specified):

| Variable | Default | Notes |
|----------|---------|-------|
| `GLPI_VERSION` | `10.0.24` | Match GitHub release tag |
| `GLPI_BASE` | `/opt/glpi` | Container volume mount root |
| `GLPI_USER` | `glpi` | Rootless podman service account |
| `GLPI_UID` / `GLPI_GID` | `1500` | Fixed for consistency |
| `NGINX_HTTPS_PORT` | `9443` | External HTTPS |
| `NGINX_HTTP_PORT` | `9080` | External HTTP (redirects to HTTPS) |
| `POD_HOST_PORT` | `8081` | Internal loopback, not exposed to network |
| `COMPOSE_PORT` | `8082` | Container-internal nginx port |
| `IMG_PHP` | `docker.io/library/php:8.3-fpm-alpine` | PHP-FPM base image |
| `IMG_NGINX` | `docker.io/library/nginx:1.26-alpine` | nginx image |
| `IMG_MARIADB` | `docker.io/library/mariadb:10.11` | MariaDB LTS image |
| `MARIADB_DATABASE` | `glpidb` | Schema name |
| `MARIADB_USER` | `glpiuser` | App DB user |
| `BACKUP_DIR` | `/opt/glpi-backups` | Backup destination |
| `BACKUP_RETENTION_DAYS` | `14` | Days to keep backups |

Leave `DB_ROOT_PASSWORD_HINT` and `DB_PASSWORD_HINT` empty — the script auto-generates 32-byte passwords via `openssl rand`.

### 5.3 Dry-Run First

Always validate before making changes:

```bash
sudo bash glpi.sh --env ./glpi.env --dry-run
```

Review output for unexpected values or errors. Fix `glpi.env` if needed.

### 5.4 Deploy

```bash
sudo bash glpi.sh --env ./glpi.env
```

Expected runtime: **5–15 minutes** (image build is the slowest step).

The script runs 14 sections:

| Section | What Happens |
|---------|-------------|
| 0 | Preflight — port availability check |
| 1 | Install packages: podman, nginx, firewalld, SELinux tools |
| 2 | Create rootless service user `glpi` (UID 1500), enable podman socket |
| 3 | Open firewall ports 9080/tcp and 9443/tcp |
| 4 | Inject internal service hosts into `/etc/hosts` |
| 5 | Apply SELinux booleans (`httpd_can_network_connect`, etc.) |
| 6 | Create directories under `/opt/glpi`, generate DB secrets |
| 7 | Write PHP-FPM (`www.conf`, `glpi.ini`) and container nginx configs |
| 8 | Write `Dockerfile.glpi` and `entrypoint.sh` to `/opt/glpi/` |
| 9 | Generate self-signed TLS cert, configure host nginx as TLS proxy |
| 10 | Install and enable `glpi-compose.service` systemd unit |
| 11 | Build GLPI container image (`localhost/glpi-app:10.0.24`) |
| 12 | Start container stack: `glpi-db` → `glpi-app` → `glpi-nginx` |
| 13 | Initialize GLPI database (`db:install`) if < 100 tables found |
| 14 | Health check: container status + HTTPS curl test |

---

## Phase 6: Verify Deployment

### 6.1 Container Status

```bash
podman-glpi ps
```

All three containers must show `healthy`:

```
NAMES        STATUS
glpi-db      Up X minutes (healthy)
glpi-app     Up X minutes (healthy)
glpi-nginx   Up X minutes (healthy)
```

### 6.2 Service Status

```bash
systemctl status glpi-compose.service
systemctl status nginx
```

### 6.3 Access GLPI

```
https://glpi.ops.io:9443/
```

Default credentials: `glpi` / `glpi` — **change immediately after first login**.

---

## Phase 7: Post-Deployment Configuration

### 7.1 Change Default Passwords

1. Log in as `glpi` / `glpi`
2. Navigate to **Setup > Users**
3. Update passwords for: `glpi`, `tech`, `normal`, `post-only`

### 7.2 Configure SMTP

1. **Setup > Notifications > Email followups**
2. Fill in SMTP server (`SMTP_HOST`), port (`SMTP_PORT`), and from address (`SMTP_FROM`) from `glpi.env`
3. Send a test email

### 7.3 Configure Zabbix Monitoring (Optional)

1. **Setup > General > Zabbix**
2. Enter Zabbix API URL and token

---

## File Locations Reference

| Path | Purpose |
|------|---------|
| `/opt/glpi/` | GLPI base directory |
| `/opt/glpi/secrets/db.env` | MariaDB container env vars (mode 400) |
| `/opt/glpi/secrets/app.env` | App container DB connection (mode 400) |
| `/opt/glpi/secrets/db-root-password` | MariaDB root password (mode 400) |
| `/opt/glpi/secrets/db-password` | MariaDB glpiuser password (mode 400) |
| `/opt/glpi/nginx-conf/glpi.conf` | Container nginx config (PHP-FPM proxy) |
| `/opt/glpi/php-conf/www.conf` | PHP-FPM pool config |
| `/opt/glpi/php-conf/glpi.ini` | PHP runtime settings |
| `/opt/glpi/Dockerfile.glpi` | GLPI app image definition |
| `/opt/glpi/entrypoint.sh` | Container entrypoint script |
| `/opt/glpi/webroot/` | GLPI web files (shared volume) |
| `/opt/glpi-backups/` | Automated backup destination |
| `/etc/nginx/conf.d/glpi.conf` | Host nginx TLS reverse proxy config |
| `/etc/systemd/system/glpi-compose.service` | systemd unit |
| `/etc/pki/tls/certs/[GLPI_HOSTNAME].crt` | TLS certificate |
| `/etc/pki/tls/private/[GLPI_HOSTNAME].key` | TLS private key (mode 400) |
| `/usr/local/bin/podman-glpi` | Convenience wrapper for podman as glpi user |

---

## Common Operations

### View Logs

```bash
podman-glpi logs glpi-app   --tail 50
podman-glpi logs glpi-nginx --tail 50
podman-glpi logs glpi-db    --tail 50
podman-glpi logs -f glpi-app   # live follow
```

### Restart the Stack

```bash
sudo systemctl restart glpi-compose.service
```

### Manual Backup

```bash
sudo /usr/local/bin/glpi-backup.sh
ls -lh /opt/glpi-backups/
```

### Redeploy / Upgrade

1. Update `GLPI_VERSION` in `glpi.env`
2. Re-run the script (idempotent):

```bash
sudo bash glpi.sh --env ./glpi.env
```

Use `--skip-db` if the database is already initialized and does not need re-initialization.

---

## Troubleshooting

| Symptom | Command | Likely Cause |
|---------|---------|-------------|
| Port 8081 already in use | `sudo fuser -k 8081/tcp` | Stale container from previous run |
| nginx returns 502 | `podman-glpi logs glpi-app --tail 100` | PHP-FPM not running |
| DB connection failed | `podman-glpi logs glpi-db` | MariaDB still starting up |
| Container won't start | `podman-glpi ps -a` | Check exit code, disk/memory |
| SELinux denial | `ausearch -m avc \| tail -20` | Missing SELinux boolean or policy |
| TLS cert error | Normal for self-signed | Replace with CA-signed cert in `/etc/pki/tls/` |

---

## Placeholders Summary

The following values still need to be confirmed and filled in before deployment:

| Placeholder | Description |
|-------------|-------------|
| `[PLACEHOLDER: internal-root-ca.crt]` | Internal root CA certificate filename |
| `[PLACEHOLDER: CA name]` | Common name of the root CA (for `trust list` grep) |
