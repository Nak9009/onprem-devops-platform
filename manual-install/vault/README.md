# HashiCorp Vault Server Manual Installation & CLI Guide (`vault`)

- **Target Host:** `devops-monitor` (`192.168.252.25`) in local mode, or `prod-secops-01` (`10.20.10.16`) in production
- **Version:** HashiCorp Vault `1.18.3`
- **Installed CLI:** `vault`
- **Automated Script:** [`manual-install/vault/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/vault/install.sh)

---

## 1. Install HashiCorp Vault (`1.18.3`) Binary & System User

```bash
VAULT_VER="1.18.3"
ARCH=$(dpkg --print-architecture) # amd64 or arm64

sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl

sudo groupadd --system vault || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g vault vault || true
sudo mkdir -p /etc/vault.d /var/lib/vault/data

curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_${ARCH}.zip" \
  -o /tmp/vault.zip
sudo unzip -o /tmp/vault.zip -d /usr/local/bin
sudo chmod 0755 /usr/local/bin/vault
sudo chown -R vault:vault /etc/vault.d /var/lib/vault
```

---

## 2. Configure `/etc/vault.d/vault.hcl` & Systemd Service

```bash
sudo tee /etc/vault.d/vault.hcl >/dev/null <<'EOF'
ui = true
disable_mlock = true

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
EOF
sudo chmod 0640 /etc/vault.d/vault.hcl
sudo chown vault:vault /etc/vault.d/vault.hcl

sudo tee /etc/systemd/system/vault.service >/dev/null <<'EOF'
[Unit]
Description=HashiCorp Vault Secret Management Server
Wants=network-online.target
After=network-online.target

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo ufw allow 8200/tcp comment 'HashiCorp Vault API/UI'
sudo systemctl daemon-reload
sudo systemctl enable --now vault
```

---

## 3. HashiCorp `vault` CLI Reference

```bash
export VAULT_ADDR="http://127.0.0.1:8200"

# 1. Check Vault server seal & initialization status
vault status

# 2. Initialize Vault (run ONCE on first deployment; save the 5 unseal keys & root token!)
vault operator init -key-shares=5 -key-threshold=3

# 3. Unseal Vault (run 3 times with 3 distinct unseal keys)
vault operator unseal <UNSEAL_KEY_1>
vault operator unseal <UNSEAL_KEY_2>
vault operator unseal <UNSEAL_KEY_3>

# 4. Authenticate with Root Token or AppRole
vault login <ROOT_TOKEN>

# 5. Enable KV v2 Secrets Engine at path 'secret/'
vault secrets enable -path=secret kv-v2
vault secrets list

# 6. Write, read, and list platform secrets via CLI
vault kv put secret/devops/nexus username="admin" password="<STRONG_PASS>"
vault kv get secret/devops/nexus
vault kv get -field=password secret/devops/nexus
vault kv list secret/devops/

# 7. Create a read-only policy for CI/CD or Kubernetes External Secrets
vault policy write ci-readonly - <<'EOF'
path "secret/data/devops/*" {
  capabilities = ["read", "list"]
}
EOF
vault policy list
```

