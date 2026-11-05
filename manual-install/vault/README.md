# HashiCorp Vault Server Manual Installation & CLI Guide (`vault`)

- **Target Host:** `devops-monitor` (`192.168.252.25`) in local mode, or `prod-secops-01` (`10.20.10.16`) in production
- **Version:** HashiCorp Vault `1.18.3`
- **Installed CLI:** `vault`
- **Automated Script:** [`manual-install/vault/install.sh`](file:///Users/ratanakieng/labs/onprem-devops-platform/manual-install/vault/install.sh)

---

## 1. Automated Install (`install.sh`)

The script installs Vault with **TLS**, **integrated Raft storage** and a firewall limited to your client network. The release zip is verified against HashiCorp's `SHA256SUMS`.

```bash
sudo ./install.sh                                   # single node, self-generated CA (lab / first node)

# 3-node production cluster (run on each node, listing the OTHER nodes):
sudo VAULT_PEERS="10.20.10.17,10.20.10.18" ./install.sh

# Auto-unseal through a Transit seal on another Vault:
sudo VAULT_TRANSIT_ADDR=https://vault-seal.internal:8200 VAULT_TRANSIT_TOKEN=... ./install.sh

# Bring your own certificate instead of the generated CA:
sudo VAULT_TLS_CERT=/path/vault.crt VAULT_TLS_KEY=/path/vault.key VAULT_TLS_CA=/path/ca.crt ./install.sh
```

| Variable | Purpose | Default |
|---|---|---|
| `VAULT_PEERS` | Other Raft nodes (`retry_join`); enables clustering | none (single node) |
| `VAULT_CLIENT_CIDR` | Networks allowed to reach `:8200` | node's `/16` |
| `VAULT_TRANSIT_ADDR`, `VAULT_TRANSIT_TOKEN`, `VAULT_TRANSIT_KEY` | Auto-unseal via Transit | disabled |

Files: `/etc/vault.d/vault.hcl`, TLS in `/etc/vault.d/tls/` (`ca.crt` must be given to every client), data in `/var/lib/vault/raft`. Raft storage needs swap disabled (done by `common/install.sh`), because `disable_mlock = true` is used.

> **Production notes**
> - Without Transit auto-unseal, every restart leaves Vault sealed until 3 key holders unseal it. The script warns about this.
> - Keep the 5 unseal keys with **different people**, and revoke the root token after creating admin policies.
> - A 3-node Raft cluster tolerates one node failure. A single node is a single point of failure for every secret.
> - Take regular `vault operator raft snapshot save` backups, and **test a restore**.

---

## 2. After the First Start (once)

```bash
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/etc/vault.d/tls/ca.crt
vault operator init -key-shares=5 -key-threshold=3
vault operator unseal            # x3 with distinct keys (not needed with auto-unseal)
vault login <ROOT_TOKEN>
vault audit enable file file_path=/var/log/vault/audit.log     # enable BEFORE storing secrets
```

---

## 3. HashiCorp `vault` CLI Reference

```bash
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/etc/vault.d/tls/ca.crt"

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

