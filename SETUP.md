# GLPI Deployment — Setup Guide

This guide walks you through preparing your environment and running the GLPI 10.0.24 deployment script.

## Prerequisites

### Hardware

- **CPU**: 2+ cores
- **RAM**: 4 GB minimum (2 GB for containers, 2 GB buffer for host)
- **Disk**: 20 GB minimum
  - 5 GB for OS
  - 5 GB for GLPI + PHP + nginx
  - 5 GB for MariaDB
  - 5 GB for backups (configurable retention)

### Network

- **Static IP** or DHCP reservation for the GLPI host
- **DNS**: Resolvable hostname (or add to `/etc/hosts` manually)
- **Firewall rules**: Allow inbound TCP 80/443 from your network
- **Cross-subnet routing**: If LDAP (FreeIPA), mail, or Zabbix are on different subnets, ensure routing is in place

### OS

- AlmaLinux 9 or 10
- RHEL 9 or 10
- Internet access to download container images and GLPI release tarball

### Credentials

Before starting, gather:

- GLPI hostname (e.g., `glpi.ops.io`)
- GLPI host IP (e.g., `192.168.100.10`)
- SMTP relay IP/hostname (mail server)
- LDAP server IP/hostname and base DN (FreeIPA/Active Directory)
- Zabbix API URL (optional; for monitoring)

---

## Step 1: Prepare the Host

### 1.1 SSH into the Host

```bash
ssh root@192.168.100.10
```

Or use `sudo` from a user account:

```bash
ssh user@192.168.100.10
sudo -i
```

### 1.2 Update the System

```bash
dnf update -y
systemctl reboot
```

Wait for the reboot and SSH back in.

---

## Step 2: Clone the Repository

### 2.1 Install Git (if not present)

```bash
dnf install -y git
```

### 2.2 Clone the Repo

```bash
cd /opt
git clone https://github.com/KenshinJ/GLPI-Deployment-RHEL-9-.git
cd GLPI-Deployment-RHEL-9-
```

### 2.3 Verify Files

```bash
ls -la
```

You should see:

```
drwxr-xr-x  glpi.sh
-rw-r--r--  glpi.env.example
-rw-r--r--  README.md
-rw-r--r--  SETUP.md
```

---

## Step 3: Create and Configure glpi.env

### 3.1 Copy the Example

```bash
cp glpi.env.example glpi.env
```

### 3.2 Edit glpi.env

Open with your preferred editor:

```bash
nano glpi.env
```

Or use a heredoc to set specific variables:

```bash
cat >> glpi.env <<'EOF'
# Override defaults
GLPI_HOSTNAME="glpi.example.com"
GLPI_IP="192.168.100.10"
MAIL_HOST="mail.example.com"
ZABBIX_HOST="zabbix.example.com"
IDM_HOST="idm.example.com"
EOF
```

### 3.3 Minimal Configuration

At minimum, set these:

| Variable | Value | Example |
|----------|-------|----------|
| `GLPI_HOSTNAME` | Your GLPI FQDN | `glpi.example.com` |
| `GLPI_IP` | Static IP of GLPI host | `192.168.100.10` |
| `MAIL_HOST` | Hostname of mail relay | `mail.example.com` |
| `ZABBIX_HOST` | Hostname of Zabbix (if monitoring) | `zabbix.example.com` |
| `IDM_HOST` | Hostname of LDAP/FreeIPA (if auth) | `idm.example.com` |

All other variables have sensible defaults. Passwords are auto-generated.

### 3.4 Validate the File

```bash
source glpi.env
echo "GLPI_HOSTNAME=$GLPI_HOSTNAME"
echo "GLPI_IP=$GLPI_IP"
echo "MAIL_HOST=$MAIL_HOST"
```

---

## Step 4: Run the Deployment (Dry-Run First)

### 4.1 Test with --dry-run

**Always test first** without making changes:

```bash
sudo bash glpi.sh --dry-run
```

This will:

- Parse the environment file
- Print all actions it would take
- Exit without starting services

Review the output for errors or unexpected values.

### 4.2 Fix Any Issues

If the dry-run shows errors:

1. Check `glpi.env` for typos or invalid IPs
2. Verify network connectivity (e.g., `ping $MAIL_HOST`)
3. Fix the issue and re-run `--dry-run`

---

## Step 5: Run the Deployment

### 5.1 Start the Deployment

Once satisfied with the dry-run:

```bash
sudo bash glpi.sh
```

The script will run through 17 sections and output progress. Total time: **5–15 minutes** (image build is slowest).

### 5.2 Monitor Progress

Watch for:

```
[INFO]  0. Preflight checks
[OK]    Port 8081 is free.
...
[INFO]  13. Build GLPI app image
...
[INFO]  14. Start stack
...
[INFO]  16. Final health check
[OK]    GLPI is up — HTTPS 200 upstream 200.
```

### 5.3 Handle Build Failure

If the image build fails:

```bash
# Check what went wrong
podman logs glpi-app --tail 100

# Once fixed, rebuild
sudo bash glpi.sh --skip-db
```

The `--skip-db` flag re-runs the deployment without reinitializing the database.

---

## Step 6: Verify Installation

### 6.1 Check Container Status

```bash
podman-glpi ps
```

Expected output:

```
CONTAINER ID  IMAGE                              COMMAND             CREATED     STATUS                  PORTS
abcd1234      localhost/glpi-app:10.0.24         php-fpm             5 min ago   Up 5 minutes (healthy)
def56789      docker.io/library/nginx:latest     nginx -g daemon...  5 min ago   Up 5 minutes (healthy)  127.0.0.1:8081->8081/tcp
ghij0123      docker.io/library/mariadb:11       mariadbd            5 min ago   Up 5 minutes (healthy)
```

### 6.2 Check Service Status

```bash
systemctl status glpi-compose.service
systemctl status nginx
```

Both should show `active (running)`.

### 6.3 Test HTTPS Access

From the GLPI host or another machine on the network:

```bash
curl -sk https://glpi.example.com/
```

Or open a browser:

```
https://glpi.example.com/
```

(Ignore the self-signed certificate warning.)

### 6.4 Login

Use the default credentials:

- **Username**: `glpi`
- **Password**: `glpi`

---

## Step 7: Post-Installation Configuration

### 7.1 Change Default Passwords

1. Log in as `glpi`
2. Navigate to **Setup > Users**
3. Update passwords for:
   - `glpi` (admin)
   - `tech` (technician)
   - `normal` (user)
   - `post-only`

### 7.2 Configure SMTP / Email

1. Navigate to **Setup > Notifications > Email followups**
2. Fill in:
   - **SMTP server**: (from `SMTP_HOST` in `glpi.env`)
   - **SMTP port**: (from `SMTP_PORT`, default 25)
   - **From address**: (from `SMTP_FROM`, default `glpi@example.com`)
3. Test send: **Setup > Notifications > Email > Send test email**

### 7.3 Configure LDAP (FreeIPA or Active Directory)

1. Navigate to **Setup > Authentication > LDAP directories**
2. Create new directory:
   - **Name**: `FreeIPA` (or your org name)
   - **Server**: `idm.example.com` (from `IDM_HOST`)
   - **Port**: `389` (or `636` for LDAPS)
   - **Base DN**: `dc=example,dc=com` (adjust to your domain)
   - **Login attribute**: `uid`
   - **Full name attribute**: `cn`
3. Test: **Action > Test**

### 7.4 Configure Zabbix (Optional)

1. Navigate to **Setup > General**
2. Under **Zabbix**:
   - **URL**: `http://zabbix.example.com/api_jsonrpc.php`
   - **Token**: (generate in Zabbix UI)
3. Test connectivity

---

## Step 8: Enable Backups

Backups are already configured and scheduled. Verify:

```bash
systemctl list-timers glpi-backup.timer
```

Output:

```
NEXT                         LEFT          LAST PASSED UNIT                 ACTIVATES
Thu 2026-04-28 02:00:00 UTC  12h left      n/a  n/a    glpi-backup.timer    glpi-backup.service
```

To run a backup manually:

```bash
sudo /usr/local/bin/glpi-backup.sh
ls -lh /opt/glpi-backups/
```

---

## Step 9: Monitoring and Logs

### 9.1 View Logs Without sudo

```bash
podman-glpi logs glpi-app --tail 50
podman-glpi logs glpi-nginx --tail 50
podman-glpi logs glpi-db --tail 50
```

### 9.2 View Real-Time Logs

```bash
podman-glpi logs -f glpi-app
```

(Press Ctrl+C to exit.)

### 9.3 Systemd Journal

```bash
journalctl -u glpi-compose.service -n 50
journalctl -u nginx -n 50
```

---

## Troubleshooting During Setup

### Problem: "Port 8081 already in use"

Cause: A previous deploy left stale containers.

Solution:

```bash
sudo fuser -k 8081/tcp
sudo bash glpi.sh
```

### Problem: "Cannot reach IDM_HOST"

Cause: Network routing issue; GLPI is on a different subnet than LDAP.

Solution:

1. From the GLPI host, test ping:

```bash
ping -c1 idm.example.com
```

2. If it fails, add a static route on the LDAP server to allow traffic from 192.168.100.0/24
3. Re-run the script — it will warn but continue

### Problem: Container keeps restarting

Check logs:

```bash
podman-glpi logs glpi-app
```

Common causes:

- **PHP error**: Check the PHP syntax in the Dockerfile
- **DB not ready**: Wait 30 seconds, then check `podman-glpi logs glpi-db`
- **Permissions**: Ensure `/var/lib/glpi` is writable by the glpi user

Solution: Re-run with `--skip-build`:

```bash
sudo bash glpi.sh --skip-build --skip-db
```

### Problem: nginx returns 502 Bad Gateway

Cause: glpi-app container is not responding.

Solution:

```bash
# Check if glpi-app is running
podman-glpi ps | grep glpi-app

# If not running, check why
podman-glpi logs glpi-app --tail 100

# Restart glpi-app
podman-glpi restart glpi-app
```

### Problem: HTTPS certificate error in browser

This is normal for self-signed certificates. To use a production certificate:

1. Obtain a CA-signed certificate for your domain
2. Copy to host:

```bash
sudo cp /path/to/cert.crt /etc/pki/tls/certs/glpi.example.com.crt
sudo cp /path/to/key.key  /etc/pki/tls/private/glpi.example.com.key
sudo chmod 400 /etc/pki/tls/private/glpi.example.com.key
```

3. Restart nginx:

```bash
sudo systemctl restart nginx
```

---

## Next Steps

- **Backup**: Test a restore from backup to ensure data can be recovered
- **Monitoring**: Integrate Zabbix or Prometheus for container and host monitoring
- **Load balancer**: If deploying multiple GLPI instances, add HAProxy or AWS ALB
- **Disaster recovery**: Document runbooks for common failures (disk full, OOM, etc.)

---

## Support

For issues:

1. Check `/var/log/glpi/php-fpm-slow.log` and `/var/log/glpi/glpi.log`
2. Review SELinux denials: `ausearch -m avc | tail -20`
3. Open an issue on GitHub with:
   - OS version
   - Output of `podman-glpi ps`
   - Last 50 lines of relevant logs

---

## Additional Resources

- [GLPI Official Docs](https://docs.glpi-project.org/)
- [Podman Docs](https://docs.podman.io/)
- [MariaDB Docs](https://mariadb.com/kb/en/)
- [FreeIPA Docs](https://www.freeipa.org/page/Documentation)
