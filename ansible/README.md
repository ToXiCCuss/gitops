# gitops-ansible

## Install Ansible

Install Ansible and Git on Debian:

```bash
sudo apt update
sudo apt install -y ansible git
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
