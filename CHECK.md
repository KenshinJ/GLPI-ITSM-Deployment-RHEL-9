# Checking containers, logs, configs, and the Dockerfile

This file documents how to inspect GLPI containers, view logs, and access configurations.

## Container status

Run as the glpi user or via the convenience wrapper:

```bash
# Quick status
podman-glpi ps

# Detailed view with health status
podman-glpi ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Health check for each container
podman-glpi healthcheck run glpi-db
podman-glpi healthcheck run glpi-app
podman-glpi healthcheck run glpi-nginx
```

If you don't have `podman-glpi` available, run as the glpi user directly:

```bash
sudo -u glpi podman ps
```

## Logs

View and follow container logs:

```bash
# Last 50 lines from glpi-app
podman-glpi logs glpi-app --tail 50

# MariaDB startup and errors
podman-glpi logs glpi-db --tail 50

# nginx startup and proxy logs
podman-glpi logs glpi-nginx --tail 50

# Follow glpi-app logs live
podman-glpi logs -f glpi-app

# All logs since 10 minutes ago
podman-glpi logs glpi-app --since 10m

# Logs with timestamps
podman-glpi logs -t glpi-app --tail 20
```

## Configuration files

Read configurations without running containers:

### Host nginx (TLS proxy)

```bash
# nginx config pointing to the GLPI stack
cat /etc/nginx/conf.d/glpi.conf

# Test if config is valid
sudo nginx -t
```

### Container-level nginx (internal PHP proxy)

```bash
# Inside the podman container (used to proxy to PHP-FPM)
cat /glpi/nginx-conf/glpi.conf
```

### PHP-FPM configuration

```bash
# www.conf — process pool settings
cat /glpi/php-conf/www.conf

# glpi.ini — PHP runtime settings
cat /glpi/php-conf/glpi.ini
```

### Environment files (secrets)

These are read-only and owned by root:

```bash
# Application database connection details (read-only)
sudo cat /glpi/secrets/app.env

# Database environment variables (read-only)
sudo cat /glpi/secrets/db.env

# Database root password (read-only)
sudo cat /glpi/secrets/db-root-password
```

### Main environment file

```bash
# Your deployment configuration (readable by all users)
cat /glpi/glpi.env
```

## Dockerfile and entrypoint

### View the Dockerfile

```bash
cat /glpi/Dockerfile.glpi
```

This file:
- Installs PHP extensions (gd, intl, zip, ldap, opcache, etc.)
- Downloads GLPI from GitHub releases
- Symlinks config and files directories to volumes
- Creates a snapshot for initializing new installs

### View the entrypoint script

```bash
cat /glpi/entrypoint.sh
```

This script runs when each container starts. It:
- Restores config from the snapshot if the volume is empty
- Syncs GLPI source files to the webroot volume
- Sets permissions on all directories
- Runs as the www-data user

### Local define (PHP constants)

```bash
cat /glpi/glpi-local_define.php
```

This sets paths to config, var, and log directories inside the container.

## Container internals (exec into live containers)

Run commands inside running containers:

```bash
# Check what PHP extensions are loaded
podman-glpi exec glpi-app php -m | head -20

# View PHP configuration as seen by PHP-FPM
podman-glpi exec glpi-app php -i | grep -E "memory_limit|upload_max|timezone"

# MySQL/MariaDB running on glpi-db
podman-glpi exec glpi-db mysqladmin variables -uroot -p$(sudo cat /glpi/secrets/db-root-password) | head -20

# List all databases on glpi-db
podman-glpi exec glpi-db mysql -uroot -p$(sudo cat /glpi/secrets/db-root-password) -e "SHOW DATABASES;"

# Check GLPI webroot files
podman-glpi exec glpi-app ls -la /srv/glpi-webroot/

# Check if a PHP file has the right owner/permissions
podman-glpi exec glpi-app ls -la /srv/glpi-webroot/index.php

# Test PHP-FPM status page (from inside the container)
podman-glpi exec glpi-app curl http://127.0.0.1:9000/status
```

## Resource usage

See how much CPU, memory, and I/O each container is using:

```bash
# Current snapshot (not continuous)
podman-glpi stats --no-stream

# Continuous update (hit Ctrl+C to exit)
podman-glpi stats
```

## Volume management

List and inspect volumes used by GLPI:

```bash
# List all volumes with GLPI labels
podman-glpi volume ls --filter label=com.glpi.managed=true

# Inspect a specific volume
podman-glpi volume inspect glpi_glpi-config

# Check disk usage of volumes (approximate)
du -sh /var/lib/containers/storage/volumes/glpi_*/_data/

# Find the actual mount point
podman-glpi volume inspect glpi_glpi-mariadb | grep Mountpoint
```

## Full system snapshot

View everything at once:

```bash
ls -lah /glpi/
```

This shows all directories and files GLPI deployment creates.

## Troubleshooting common issues

### Container won't start

```bash
# Check full logs (not just tail)
podman-glpi logs glpi-app

# Check if container process exited
podman-glpi ps -a  # shows exited containers too

# Inspect the container state
podman-glpi inspect glpi-app --format '{{json .State}}' | jq .

# Check available disk space
df -h /var/lib/containers/

# Check available memory
free -h
```

### PHP-FPM not listening

```bash
# Test if port 9000 is listening inside the app container
podman-glpi exec glpi-app ss -tlnp | grep 9000

# Check PHP-FPM status
podman-glpi exec glpi-app php-fpm --test-config

# Verify process is running
podman-glpi exec glpi-app ps aux | grep fpm
```

### Database won't initialize

```bash
# Check MariaDB logs
podman-glpi logs glpi-db

# Test MySQL connection from app container
podman-glpi exec glpi-app mysql -h glpi-db -u glpi -p$(sudo cat /glpi/secrets/db-password) glpi -e "SELECT 1;"

# Check database size
podman-glpi exec glpi-db mysql -u glpi -p$(sudo cat /glpi/secrets/db-password) glpi -e "SELECT sum(data_length + index_length) / 1024 / 1024 AS size_mb FROM information_schema.tables WHERE table_schema='glpi';"
```

### Port already in use

```bash
# Find what's using the nginx proxy port
sudo ss -tlnp | grep 8081

# Kill process using the port (be careful)
sudo fuser -k 8081/tcp

# Or use podman to clear old containers
podman-glpi rm -f glpi-nginx
```

## Container network

All three containers are on the same podman network. They can reach each other by name:

```bash
# Test network connectivity from app to db
podman-glpi exec glpi-app ping glpi-db

# Check DNS resolution
podman-glpi exec glpi-app getent hosts glpi-db

# List all networks
podman-glpi network ls
```

## Useful aliases

Add these to your shell for quicker access:

```bash
alias pg='podman-glpi'
alias pgl='podman-glpi logs'
alias pgps='podman-glpi ps'
alias pge='podman-glpi exec'
```

Then use:
```bash
pg ps
pgl glpi-app --tail 50
pge glpi-app php -v
```
