# Redis Cache & Sentinel HA Manual Installation & `redis-cli` Guide (`redis`)

- **Target Host(s):** `pg-db1` (local Minimal) or `prod-redis-01..03` (`10.20.50.21..23`, `VLAN 50`)
- **Version:** Redis `7.x` + Redis Sentinel + Prometheus Redis Exporter (`:9121`)
- **Installed CLI:** `redis-cli`
- **Automated Script:** [`manual-install/redis/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/redis/install.sh)

---

## 0. Automated Install (`install.sh`) — Read This First

The script picks its mode from the host IP:

| Mode | When | Result |
|---|---|---|
| **Sentinel HA** | host IP is `REDIS_IP` / `REDIS02_IP` / `REDIS03_IP` | node 1 = master, nodes 2–3 = replicas, a Sentinel on every node (quorum 2) |
| **Standalone** | `REDIS02_IP`/`REDIS03_IP` unset (local lab) | single Redis, Sentinel disabled |

```bash
# On prod-redis-01, 02 and 03 (start with node 1):
sudo PLATFORM_ENV=production REDIS_PASS='<16+ chars>' ./install.sh
```

- Redis and Sentinel bind to `127.0.0.1` + the node IP (not `0.0.0.0`). Firewall: peers on 6379/26379, `REDIS_CLIENT_CIDR` (default: node `/16`) for clients, `MONITOR_IP` for the exporter.
- `masterauth`, Sentinel `auth-pass`/`requirepass` and the exporter password all use `REDIS_PASS`. The exporter now authenticates correctly.
- `REDIS_MAXMEMORY_POLICY` defaults to `allkeys-lru` (cache). **Use `noeviction` or `volatile-lru` if Redis holds queues or sessions**, or Redis will silently evict them.
- Applications must use a **Sentinel-aware client** (master name `mymaster`, Sentinels on `:26379` of all 3 nodes).
- Don't re-run the script on a live HA node after a failover: Sentinel rewrites `redis.conf` and the script would reset the node's role.
- Production refuses `ChangeMe_*` or short passwords.

**Verify:**
```bash
redis-cli -p 26379 -a "$REDIS_PASS" sentinel get-master-addr-by-name mymaster
redis-cli -a "$REDIS_PASS" info replication     # role + connected_slaves
```
**Rehearse:** stop `redis-server` on the master and confirm a replica is promoted within ~10–15 s, then bring the old master back and check it rejoins as a replica.

> The manual steps below are the single-node reference. For HA, the script is authoritative.

---

## 1. Install Redis Server, Sentinel & Prometheus Exporter

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  redis-server redis-sentinel prometheus-redis-exporter
```

---

## 2. Configure Hardened `/etc/redis/redis.conf` & UFW Ports

```bash
export REDIS_PASS="ChangeMe_RedisSecret_2026!"

sudo tee /etc/redis/redis.conf >/dev/null <<EOF
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
maxmemory 512mb
maxmemory-policy allkeys-lru
appendonly yes
appendfsync everysec
EOF

sudo chown redis:redis /etc/redis/redis.conf
sudo chmod 0640 /etc/redis/redis.conf

sudo ufw allow 6379/tcp comment 'Redis Server'
sudo ufw allow 26379/tcp comment 'Redis Sentinel'
sudo ufw allow 9121/tcp comment 'Prometheus Redis Exporter'

sudo systemctl enable --now redis-server prometheus-redis-exporter
sudo systemctl restart redis-server
```

---

## 3. `redis-cli` Reference

```bash
export REDISCLI_AUTH="ChangeMe_RedisSecret_2026!"

# 1. Test connectivity (returns PONG)
redis-cli -h 127.0.0.1 -p 6379 ping

# 2. Inspect server memory, replication role, and persistence status
redis-cli info server
redis-cli info memory
redis-cli info replication
redis-cli info persistence

# 3. Trigger an immediate background RDB snapshot or AOF rewrite
redis-cli bgsave
redis-cli bgrewriteaof

# 4. Monitor live commands or check latency
redis-cli --latency
redis-cli client list

# 5. Query Redis Sentinel master/replica status (when Sentinel is enabled on :26379)
redis-cli -p 26379 sentinel masters
redis-cli -p 26379 sentinel replicas mymaster
```

