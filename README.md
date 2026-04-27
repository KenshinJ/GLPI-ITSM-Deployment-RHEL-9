# GLPI 10.0.24 Deployment on AlmaLinux/RHEL 9-10

Production-ready deployment script for GLPI using rootless Podman, MariaDB, and nginx on AlmaLinux 9/10 or RHEL 9/10.

## What This Does

This repository automates the complete GLPI stack deployment:

- **Container orchestration**: Rootless Podman with podman-compose
- **Web tier**: nginx TLS reverse proxy + PHP-FPM
- **Database**: MariaDB 10.11 LTS
- **Security**: SELinux policy, self-signed TLS, rootless containers, firewall rules
- **Backup**: Automated daily database + files backups with retention policy
- **Monitoring**: Systemd health checks, container logging, optional Zabbix agent
- **Integration**: SMTP relay, LDAP/FreeIPA, Zabbix API ready

## Requirements

### Hardware

- **CPU**: 2+ cores
- **RAM**: 4 GB minimum (2 GB for containers)
- **Disk**: 20 GB minimum (5 GB OS, 5 GB GLPI, 5 GB MariaDB, 5 GB backups)

### Operating System

- AlmaLinux 9 or 10
- RHEL 9 or 10
- Internet access to download container images

### Network

- Static IP or DHCP reservation
- TCP 80/443 inbound from your network
- DNS-resolvable hostname (or manual `/etc/hosts` entry)
- Cross-subnet routing if LDAP/mail/Zabbix are on different subnets

## Quick Start

### 1. Clone the repository

```bash
cd /opt
git clone https://github.com/KenshinJ/GLPI-Deployment-RHEL-9-.git
cd GLPI-Deployment-RHEL-9-
```

### 2. Configure the environment

```bash
cp glpi.env.example glpi.env
nano glpi.env
```

Minimum edits:

```bash
GLPI_HOSTNAME="glpi.example.com"
GLPI_IP="192.168.100.10"
MAIL_HOST="mail.example.com"
ZABBIX_HOST="zabbix.example.com"
IDM_HOST="idm.example.com"
```

### 3. Test without making changes

```bash
sudo bash glpi.sh --env ./glpi.env --dry-run
```

### 4. Deploy

```bash
sudo bash glpi.sh --env ./glpi.env
```

Deployment takes 5–15 minutes (image build is slowest).

### 5. Verify

Once complete, access GLPI:

```
https://glpi.example.com/
```

Default credentials: `glpi` / `glpi` (change immediately).

For detailed instructions, see **[SETUP.md](SETUP.md)**.

---

## Configuration

All settings are in `glpi.env`. Key variables:

| Variable | Purpose | Example |
|----------|---------|----------|
| `GLPI_HOSTNAME` | FQDN for TLS and nginx | `glpi.example.com` |
| `GLPI_IP` | Static IP of GLPI host | `192.168.100.10` |
| `GLPI_BASE` | Container volume mount point | `/opt/glpi` |
| `NGINX_HTTPS_PORT` | External HTTPS port | `9443` |
| `NGINX_HTTP_PORT` | External HTTP port (redirects) | `9080` |
| `MAIL_HOST` | SMTP relay hostname | `mail.example.com` |
| `ZABBIX_HOST` | Zabbix server hostname | `zabbix.example.com` |
| `IDM_HOST` | LDAP/FreeIPA hostname | `idm.example.com` |
| `BACKUP_RETENTION_DAYS` | How long to keep backups | `14` |

See `glpi.env.example` for full documentation.

---

## Script Flags

```bash
sudo bash glpi.sh [--env FILE] [--skip-build] [--skip-db] [--dry-run]
```

| Flag | Purpose |
|------|----------|
| `--env FILE` | Path to glpi.env (default: `./glpi.env`) |
| `--skip-build` | Skip Podman image build (use existing) |
| `--skip-db` | Skip database initialization |
| `--dry-run` | Print actions, make no changes |

---

## Post-Deployment

### Change Default Passwords

1. Log in as `glpi` / `glpi`
2. Go to **Setup > Users**
3. Change passwords for `glpi`, `tech`, `normal`, `post-only`

### Configure SMTP

1. **Setup > Notifications > Email followups**
2. Fill in SMTP server, port, from address
3. Test send

### Configure LDAP (Optional)

1. **Setup > Authentication > LDAP directories**
2. Add server, base DN, login attribute
3. Test connection

### Configure Zabbix (Optional)

1. **Setup > General > Zabbix**
2. Enter Zabbix API URL and token
3. Test connectivity

Full post-install guide in **[SETUP.md](SETUP.md)**.

---

## View Containers Without sudo

The deployment creates a convenience wrapper:

```bash
podman-glpi ps
podman-glpi logs glpi-app --tail 50
podman-glpi exec glpi-db mysql -u root -p
```

Or as the service user:

```bash
sudo -u glpi bash
podman ps
podman logs glpi-app
```

---

## Backups

Backups run automatically via systemd timer (default: daily at 02:00).

Location: `/opt/glpi-backups/`

Retention: 14 days (configurable via `BACKUP_RETENTION_DAYS`)

### Manual Backup

```bash
sudo /usr/local/bin/glpi-backup.sh
ls -lh /opt/glpi-backups/
```

### Restore from Backup

Documented in **[SETUP.md](SETUP.md)** under troubleshooting.

---

## Troubleshooting

### Port Already in Use

```bash
sudo fuser -k 8081/tcp
sudo bash glpi.sh --env ./glpi.env
```

### Container Won't Start

```bash
podman-glpi logs glpi-app --tail 100
podman-glpi restart glpi-app
```

### nginx Returns 502

```bash
podman-glpi ps | grep glpi-app
podman-glpi logs glpi-nginx --tail 50
```

### Database Connection Failed

```bash
podman-glpi logs glpi-db
podman-glpi exec glpi-db mysqladmin ping -h 127.0.0.1 -u root -p
```

For more troubleshooting, see **[SETUP.md](SETUP.md)**.

---

## Monitoring

### Systemd Services

```bash
systemctl status glpi-compose.service
systemctl status nginx
systemctl list-timers glpi-backup.timer
```

### Container Logs

```bash
podman-glpi logs -f glpi-app
podman-glpi logs -f glpi-nginx
podman-glpi logs -f glpi-db
```

### Journalctl

```bash
journalctl -u glpi-compose.service -n 50
journalctl -u nginx -n 50
```

---

## Security

- **Rootless Podman**: Containers run as unprivileged `glpi` user
- **SELinux**: Custom policy isolates container filesystem
- **Firewall**: Only HTTP/HTTPS ports exposed to network; database and compose ports on loopback
- **TLS**: Self-signed by default; bring your own CA-signed cert
- **Secrets**: Database passwords auto-generated and stored in `secrets/` (mode 600)
- **File permissions**: `/opt/glpi/secrets` readable only by glpi user

---

## Upgrade GLPI

To upgrade to a new GLPI version:

1. Update `GLPI_VERSION` in `glpi.env`
2. Re-run the script:

```bash
sudo bash glpi.sh --env ./glpi.env
```

The script rebuilds the image and runs GLPI migrations automatically.

---

## Uninstall

To remove GLPI completely:

```bash
sudo systemctl stop glpi-compose.service
sudo systemctl disable glpi-compose.service
sudo podman-compose -f /opt/glpi/compose.yaml down -v
sudo rm -rf /opt/glpi /opt/glpi-backups
sudo userdel -r glpi
sudo firewall-cmd --permanent --remove-port=9080/tcp --remove-port=9443/tcp
sudo firewall-cmd --reload
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│ Host OS (AlmaLinux/RHEL 9-10)                       │
├─────────────────────────────────────────────────────┤
│ systemd unit: glpi-compose.service                  │
│ nginx (TLS reverse proxy) :9443 :9080               │
├─────────────────────────────────────────────────────┤
│ Rootless Podman (user: glpi)                        │
├──────────────────┬──────────────┬──────────────────┤
│ glpi-nginx       │ glpi-app     │ glpi-db          │
│ (nginx:1.26)     │ (php:8.3-fpm)│ (mariadb:10.11)  │
│ :127.0.0.1:8081 │ :9000        │ :3306            │
│                  │              │                  │
│ Volumes:         │ Volumes:     │ Volumes:         │
│ • glpi-webroot   │ • glpi-config│ • glpi-mariadb   │
│   (bind mount)   │ • glpi-files │                  │
│                  │ • glpi-log   │                  │
└──────────────────┴──────────────┴──────────────────┘
        │                                │
        └────────────── Network ─────────┘
                 • /etc/hosts injection
                 • Cross-host services
```

---

## Support

Issues? Check:

1. `glpi.env` for typos (especially hostnames, ports, paths)
2. Container logs: `podman-glpi logs <container>`
3. Systemd logs: `journalctl -u glpi-compose.service -n 50`
4. SELinux denials: `ausearch -m avc | tail -20`

Open an issue on GitHub with OS version, output of `podman-glpi ps`, and last 50 lines of relevant logs.

---

## Resources

- [GLPI Official Documentation](https://docs.glpi-project.org/)
- [Podman Documentation](https://docs.podman.io/)
- [MariaDB Documentation](https://mariadb.com/kb/en/)
- [FreeIPA/LDAP Setup](https://www.freeipa.org/page/Documentation)

---

## License

MIT
