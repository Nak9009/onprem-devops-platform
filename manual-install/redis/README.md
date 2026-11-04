# Redis Cache & Sentinel HA Manual Installation & `redis-cli` Guide (`redis`)

- **Target Host(s):** `pg-db1` (local Minimal) or `prod-redis-01..03` (`10.20.50.21..23`, `VLAN 50`)
- **Version:** Redis `7.x` + Redis Sentinel + Prometheus Redis Exporter (`:9121`)
- **Installed CLI:** `redis-cli`
- **Automated Script:** [`manual-install/redis/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/redis/install.sh)

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

