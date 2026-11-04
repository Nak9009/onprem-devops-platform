#!/usr/bin/env bash
# ==============================================================================
# Redis Server + Sentinel + Prometheus Exporter + redis-cli Installer
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

# Load global platform.env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

REDIS_PASS="${REDIS_PASS:-ChangeMe_RedisSecret_2026!}"
REDIS_MAXMEM="${REDIS_MAXMEM:-512mb}"

echo "[1/3] Installing redis-server, redis-sentinel, and prometheus-redis-exporter..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  redis-server redis-sentinel prometheus-redis-exporter

echo "[2/3] Writing hardened /etc/redis/redis.conf..."
cat >/etc/redis/redis.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize no
supervised systemd
pidfile /run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
databases 16
dir /var/lib/redis
requirepass ${REDIS_PASS}
maxmemory ${REDIS_MAXMEM}
maxmemory-policy allkeys-lru
appendonly yes
appendfsync everysec
EOF
chown redis:redis /etc/redis/redis.conf
chmod 0640 /etc/redis/redis.conf

echo "[3/3] Opening UFW ports and verifying Redis with redis-cli..."
ufw allow 6379/tcp comment 'Redis Server'
ufw allow 26379/tcp comment 'Redis Sentinel'
ufw allow 9121/tcp comment 'Prometheus Redis Exporter'

systemctl enable --now redis-server prometheus-redis-exporter
systemctl restart redis-server
REDISCLI_AUTH="${REDIS_PASS}" redis-cli ping
echo "Redis Server and redis-cli installation complete."

