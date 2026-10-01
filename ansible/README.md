# gitops-ansible

## Install Ansible

Install Ansible and Git on Debian:

```bash
sudo apt update
sudo apt install -y ansible git && git clone https://github.com/ToXiCCuss/gitops.git
```

Then switch to the repository and install the required collections:

```bash
cd gitops-ansible
ansible-galaxy collection install -r requirements.yml
```

## Dry Run

Before the actual execution, check the playbook in check mode. This does not make any changes:

```bash
ansible-playbook -i inventory.ini site.yml --check --diff
```

## Apply Changes

If the dry run completes without unexpected errors, run the playbook:

```bash
ansible-playbook -i inventory.ini site.yml
```

## Secrets (ansible-vault)

Secrets do **not** live in `group_vars/all/main.yml` but in
`group_vars/all/secrets.yml`. That file is encrypted with `ansible-vault`
(AES256) and **is committed to Git** in encrypted form. Ansible loads it
automatically, so no playbook or role needs changing.

Managed secrets:

| Variable | Used by | Source |
| --- | --- | --- |
| `netbird_setup_key` | `roles/netbird` | NetBird dashboard → Setup Keys |
| `k3s_registries_harbor_password` | `roles/k3s_registries` | Harbor account / robot account |
| `arcane_encryption_key` | `roles/arcane` | existing `override.env` — see the Arcane section |
| `arcane_jwt_secret` | `roles/arcane` | existing `override.env` — see the Arcane section |

### Per-host values

Values are stored per scope in the nested dict `vault_secrets`:

```yaml
vault_secrets:
  all:                                        # fallback for every host
    k3s_registries_harbor_password: ...
  docker01:                                   # overrides "all" on that host
    netbird_setup_key: ...
  k8sdev01:
    netbird_setup_key: ...
```

The very same layering exists in plain text for **non-secret** per-host
settings, in `host_config` in `group_vars/all/main.yml`:

```yaml
host_config:
  all: {}
  docker01:
    arcane_app_url: "https://arcane01.proxy.rjst.de"
```

`group_vars/all/main.yml` merges the `all` layer with the current host's layer
once (`_secrets` / `_config`) and resolves each variable in this order:

1. `vault_secrets[<ansible_hostname>][<name>]` — host specific
2. `vault_secrets["all"][<name>]` — shared by every host
3. `""` — the role's `assert` task reports the missing value

> **Why not `host_vars/`?** `inventory.ini` only knows `localhost`, and Ansible
> resolves `host_vars/` by *inventory* name — `host_vars/docker01.yml` would
> never be loaded. `ansible_hostname` is a fact and holds the real hostname,
> which is also what the `*_hosts` gates compare against.

Note that this is organisation, not isolation: the encrypted file is in Git and
every host with `.vault_pass` can decrypt **all** scopes. Real per-host
separation would need several vault IDs (`vault_identity_list`).

### First setup on a host

```bash
../scripts/ansible/setup-secrets.sh
```

Without arguments the script uses **this machine's own short hostname** as the
scope (`hostname -s`, falling back to `uname -n`) — that is exactly the key
`ansible_hostname` resolves to later, since the playbook runs locally on each
host. It then asks for each secret; input is not echoed. It writes the
encrypted `group_vars/all/secrets.yml` and creates the vault password file
`ansible/.vault_pass` (`chmod 600`, gitignored). On a fresh setup it can
generate a random vault password — **store it in your password manager**,
otherwise the committed `secrets.yml` is unreadable everywhere else.

Afterwards commit the encrypted file:

```bash
git add ansible/group_vars/all/secrets.yml && git commit -m "Update Ansible vault secrets"
```

### Additional host (secrets.yml already in Git)

Only the password file is missing there:

```bash
../scripts/ansible/setup-secrets.sh --password
```

The script asks for the vault password and verifies it against the checked-out
`secrets.yml` before writing `.vault_pass`.

### Day-to-day

```bash
../scripts/ansible/setup-secrets.sh                    # THIS host (auto-detected)
../scripts/ansible/setup-secrets.sh --scope all        # shared by every host
../scripts/ansible/setup-secrets.sh --scope docker01   # another host
../scripts/ansible/setup-secrets.sh --view             # show the decrypted content
../scripts/ansible/setup-secrets.sh --edit             # raw edit in $EDITOR
../scripts/ansible/setup-secrets.sh --rekey            # rotate the vault password
```

At each prompt: Enter keeps the current value, `-` removes the entry. A removed
host entry falls back to the value from scope `all`. Scopes that run empty are
dropped from the file.

The script prints the scope it is about to write to, and warns when the detected
hostname appears in none of the `*_hosts` lists in `main.yml` — usually a sign
that the host has not been wired into the playbook yet.

### Adding a new secret

1. Add the variable with an empty default to the role's `defaults/main.yml`.
2. Append its name to `SECRET_NAMES` and a description to `SECRET_HINTS` in
   `scripts/ansible/setup-secrets.sh`.
3. Add the host → all → `""` look-up to the *Secrets* block in
   `group_vars/all/main.yml` (copy an existing one).
4. Run the script — existing values are preserved.

> **Note:** `ansible.cfg` sets `vault_password_file = .vault_pass`. If that file
> is missing, *every* `ansible-playbook` run aborts with
> `The vault password file .vault_pass was not found` — run the script first.
> Tasks that use secrets already have `no_log: true`, so the values do not show
> up in the output or in `--check --diff`.

## Arcane

`roles/arcane` deploys the Arcane Docker UI from `docker/arcane/`. It runs only
on the hosts listed in `arcane_hosts` (`group_vars/all/main.yml`), which is
empty by default.

The role copies `docker-compose.yml` and `default.env` to `/root/docker/arcane`
**verbatim** — the compose file is deliberately not a Jinja template, so
Renovate keeps updating the pinned image digest. Only `override.env` is
rendered, from `arcane_app_url` plus the two vault secrets, with `mode 0600`
and `no_log: true`. Because `docker-compose.yml` loads `override.env` after
`default.env`, those values win.

### Enabling it

```yaml
# group_vars/all/main.yml
arcane_hosts:
   - docker01

host_config:
   docker01:
     arcane_app_url: "https://arcane01.proxy.rjst.de"
```

```bash
# on docker01 itself - the scope is detected automatically
../scripts/ansible/setup-secrets.sh
```

> **⚠️ On a host where Arcane already runs, copy the existing keys — do not
> generate new ones.** `ENCRYPTION_KEY` decrypts Arcane's stored data; a new key
> makes it unreadable. Read them off the host first:
>
> ```bash
> cat <repo checkout>/docker/arcane/override.env
> ```
>
> Note the path: `start.sh` generates `override.env` next to itself, so the file
> sits in the **repository checkout** (e.g. `/root/gitops/docker/arcane/`), not
> below `/root/docker/arcane/`.
>
> Putting them in the vault is an improvement over `start.sh`: so far the key
> existed only on that host, now it survives a rebuild.

`docker/arcane/start.sh` still works as a manual fallback. Its `override.env` is
gitignored, since it holds both secrets in plain text.

### Taking over a stack that start.sh already deployed

`start.sh` runs `docker compose up` from the repository checkout, so an existing
Arcane uses that directory as its compose project while the role uses
`arcane_dir` (`/root/docker/arcane`). Both compose files set
`container_name: arcane`, so the role would hit `container name /arcane is
already in use`. It therefore checks for this and aborts with an explanatory
message instead.

Stop the old stack once, then let the role take over:

```bash
cd <repo checkout>/docker/arcane && docker compose down
```

The data is not affected — `docker-compose.yml` mounts
`/root/docker/arcane/data` and `/root/docker/arcane/backups` by absolute path,
so it already lives where the role deploys to.
