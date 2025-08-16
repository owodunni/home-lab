# Home Lab Ansible Automation

## Requirements

- **UV Package Manager**: [Install UV](https://docs.astral.sh/uv/getting-started/installation/) for fast Python dependency management

## Quick Start

1. **Install dependencies:**
   ```bash
   make install
   ```

2. **Run linting:**
   ```bash
   make lint
   ```

3. **View all available commands:**
   ```bash
   make help
   ```

## Development Workflow

1. **Install dependencies** with `make install` (uses UV)
2. **Write/modify playbooks** following Ansible best practices
3. **Run linting** with `make lint` (yamllint + ansible-lint)
4. **Pre-commit hooks** automatically run on git commits

## Adding New Hosts

To provision a new host for the cluster:

1. Install OS
2. Copy your SSH public key to the host:
   ```bash
   ssh-copy-id -i ~/.ssh/your_key.pub alexanderp@hostname
   ```
   Or copy to all hosts at once:
   ```bash
   for host in pi-cm5-1 pi-cm5-2 pi-cm5-3 pi-cm5-4; do ssh-copy-id -i ~/.ssh/your_key.pub alexanderp@$host; done
   ```
3. Add hosts to the [hosts.ini](./hosts.ini) file
