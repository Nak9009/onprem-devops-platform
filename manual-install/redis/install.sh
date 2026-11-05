#!/usr/bin/env bash
# ==============================================================================
# Redis + Sentinel + Prometheus Exporter Installer (Ubuntu 24.04 LTS)
#
# Two modes, chosen automatically:
#   * Sentinel HA (production): this host's IP is one of REDIS_IP / REDIS02_IP /
#     REDIS03_IP (platform.env). Node 1 starts as master, nodes 2-3 as replicas,
#     and a Sentinel runs on every node (quorum 2).
#   * Standalone (lab): REDIS02_IP/REDIS03_IP are not set -> single Redis, no Sentinel.
# Force a mode with REDIS_MODE=sentinel|standalone (and REDIS_NODE_INDEX=1..3).
#
# Clients must be Sentinel-aware in HA mode (master name: ${SENTINEL_MASTER:-mymaster}).
#
# Usage: sudo ./install.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}" ]]; then
  # shellcheck disable=SC1090
  source "${PLATFORM_ENV_FILE:-${SCRIPT_DIR}/../platform.env}"
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./install.sh)" >&2
  exit 1
fi

REDIS_PASS="${REDIS_PASS:-ChangeMe_RedisSecret_2026!}"
REDIS_MAXMEM="${REDIS_MAXMEM:-512mb}"
REDIS_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"   # use noeviction/volatile-lru if Redis holds queues or sessions
SENTINEL_MASTER="${SENTINEL_MASTER:-mymaster}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
REDIS_CLIENT_CIDR="${REDIS_CLIENT_CIDR:-$(echo "${NODE_IP}" | awk -F. '{print $1"."$2".0.0/16"}')}"

if [[ "${PLATFORM_ENV:-}" == "production" ]]; then
  if [[ "${REDIS_PASS}" == ChangeMe_* || ${#REDIS_PASS} -lt 16 ]]; then
    echo "ERROR: set a real REDIS_PASS (16+ chars, not ChangeMe_*) before a production install" >&2
    exit 1
  fi
  if [[ "${REDIS_PASS}" =~ [[:space:]\"\'\\#] ]]; then
    echo "ERROR: REDIS_PASS must not contain spaces, quotes, backslash or #" >&2
    exit 1
  fi
fi

# ---- Mode / node detection ----------------------------------------------------
REDIS_MODE="${REDIS_MODE:-}"
REDIS_NODE_INDEX="${REDIS_NODE_INDEX:-}"
if [[ -z "${REDIS_MODE}" ]]; then
  if [[ -n "${REDIS02_IP:-}" && -n "${REDIS03_IP:-}" && -n "${REDIS_IP:-}" ]]; then
    case "${NODE_IP}" in
      "${REDIS_IP}")   REDIS_MODE=sentinel; REDIS_NODE_INDEX=1 ;;
      "${REDIS02_IP}") REDIS_MODE=sentinel; REDIS_NODE_INDEX=2 ;;
      "${REDIS03_IP}") REDIS_MODE=sentinel; REDIS_NODE_INDEX=3 ;;
      *) REDIS_MODE=standalone ;;
    esac
  else
    REDIS_MODE=standalone
  fi
fi
if [[ "${REDIS_MODE}" == "sentinel" ]]; then
  [[ "${REDIS_NODE_INDEX}" =~ ^[123]$ ]] || { echo "ERROR: REDIS_NODE_INDEX must be 1..3" >&2; exit 1; }
  : "${REDIS_IP:?REDIS_IP not set}" "${REDIS02_IP:?REDIS02_IP not set}" "${REDIS03_IP:?REDIS03_IP not set}"
elif [[ "${PLATFORM_ENV:-}" == "production" ]]; then
  echo "WARN: production Redis running standalone (no failover). Set REDIS02_IP/REDIS03_IP for Sentinel HA." >&2
fi
echo "Redis mode: ${REDIS_MODE}${REDIS_NODE_INDEX:+ (node ${REDIS_NODE_INDEX})} on ${NODE_IP}"

echo "[1/4] Installing redis-server, redis-sentinel and prometheus-redis-exporter..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server redis-sentinel prometheus-redis-exporter

# Kernel settings Redis asks for (background saves, AOF rewrite)
echo 'vm.overcommit_memory = 1' >/etc/sysctl.d/98-redis.conf
sysctl --system >/dev/null

echo "[2/4] Writing /etc/redis/redis.conf..."
REPLICA_LINES=""
if [[ "${REDIS_MODE}" == "sentinel" && "${REDIS_NODE_INDEX}" != "1" ]]; then
  REPLICA_LINES="replicaof ${REDIS_IP} 6379"
fi
# Sentinel rewrites this file during failover (replicaof lines), so it must stay writable by redis.
# Do NOT re-run this script on a live HA node after a failover: it would reset the node's role.
cat >/etc/redis/redis.conf <<EOF
bind 127.0.0.1 ${NODE_IP}
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
masterauth ${REDIS_PASS}
maxmemory ${REDIS_MAXMEM}
maxmemory-policy ${REDIS_MAXMEMORY_POLICY}
appendonly yes
appendfsync everysec
${REPLICA_LINES}
EOF
chown redis:redis /etc/redis/redis.conf
chmod 0640 /etc/redis/redis.conf

if [[ "${REDIS_MODE}" == "sentinel" ]]; then
  echo "[3/4] Writing /etc/redis/sentinel.conf (quorum 2)..."
  cat >/etc/redis/sentinel.conf <<EOF
bind 127.0.0.1 ${NODE_IP}
port 26379
daemonize no
supervised systemd
dir /var/lib/redis
logfile /var/log/redis/redis-sentinel.log
requirepass ${REDIS_PASS}
sentinel monitor ${SENTINEL_MASTER} ${REDIS_IP} 6379 2
sentinel auth-pass ${SENTINEL_MASTER} ${REDIS_PASS}
sentinel down-after-milliseconds ${SENTINEL_MASTER} 5000
sentinel failover-timeout ${SENTINEL_MASTER} 60000
sentinel parallel-syncs ${SENTINEL_MASTER} 1
sentinel announce-ip ${NODE_IP}
EOF
  chown redis:redis /etc/redis/sentinel.conf
  chmod 0640 /etc/redis/sentinel.conf
else
  echo "[3/4] Standalone mode: skipping Sentinel."
  systemctl disable --now redis-sentinel 2>/dev/null || true
fi

echo "[4/4] Firewall, exporter and service start..."
# Redis and Sentinel: peers + client network only
if [[ "${REDIS_MODE}" == "sentinel" ]]; then
  for peer in "${REDIS_IP}" "${REDIS02_IP}" "${REDIS03_IP}"; do
    [[ "${peer}" == "${NODE_IP}" ]] && continue
    ufw allow from "${peer}" to any port 6379 proto tcp comment 'Redis replication peer'
    ufw allow from "${peer}" to any port 26379 proto tcp comment 'Redis Sentinel peer'
  done
  ufw allow from "${REDIS_CLIENT_CIDR}" to any port 26379 proto tcp comment 'Redis Sentinel clients'
fi
ufw allow from "${REDIS_CLIENT_CIDR}" to any port 6379 proto tcp comment 'Redis clients'
if [[ -n "${MONITOR_IP:-}" ]]; then
  ufw allow from "${MONITOR_IP}" to any port 9121 proto tcp comment 'Prometheus Redis Exporter'
else
  echo "WARN: MONITOR_IP unset; opening 9121 to all" >&2
  ufw allow 9121/tcp comment 'Prometheus Redis Exporter'
fi

# Exporter authenticates with the same password (read by systemd as root)
cat >/etc/default/prometheus-redis-exporter <<EOF
ARGS=""
REDIS_ADDR="redis://127.0.0.1:6379"
REDIS_PASSWORD="${REDIS_PASS}"
EOF
chmod 0600 /etc/default/prometheus-redis-exporter

systemctl enable redis-server prometheus-redis-exporter
systemctl restart redis-server
[[ "${REDIS_MODE}" == "sentinel" ]] && { systemctl enable redis-sentinel; systemctl restart redis-sentinel; }
systemctl restart prometheus-redis-exporter

ok=0
for _ in $(seq 1 15); do
  if [[ "$(REDISCLI_AUTH="${REDIS_PASS}" redis-cli -h 127.0.0.1 ping 2>/dev/null)" == "PONG" ]]; then ok=1; break; fi
  sleep 2
done
[[ ${ok} -eq 1 ]] || { echo "ERROR: Redis did not answer PING; check 'journalctl -u redis-server'" >&2; exit 1; }

REDISCLI_AUTH="${REDIS_PASS}" redis-cli -h 127.0.0.1 info replication | grep -E "^role|^connected_slaves|^master_host|^master_link_status" || true
if [[ "${REDIS_MODE}" == "sentinel" ]]; then
  sleep 3
  REDISCLI_AUTH="${REDIS_PASS}" redis-cli -p 26379 sentinel master "${SENTINEL_MASTER}" 2>/dev/null | head -n 12 || true
  echo "Sentinel node ${REDIS_NODE_INDEX} ready. Install all 3 nodes, then check: redis-cli -p 26379 -a <pass> sentinel get-master-addr-by-name ${SENTINEL_MASTER}"
fi
echo "Redis installation complete."
