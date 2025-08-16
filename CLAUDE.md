# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important
- ALL instructions within this document MUST BE FOLLOWED, these are not optional unless explicitly stated.
- DO NOT edit more code than you have to.
- DO NOT WASTE TOKENS, be succinct and concise.

## Development Partnership

We build production code together. I handle implementation details while you guide architecture and catch complexity early.

## Core Workflow: Research → Plan → Implement → Validate

**Start every feature with:** "Let me research the codebase and create a plan before implementing."

1. **Research** - Understand existing patterns and architecture
2. **Plan** - Propose approach and verify with you
3. **Implement** - Build with tests and error handling
4. **Validate** - ALWAYS run formatters, linters, and tests after implementation

## Repository Overview

This is a home lab automation repository using Ansible to provision and manage a cluster of Raspberry Pi CM5 (Compute Module 5) devices. The infrastructure consists of:

- **Cluster nodes**: pi-cm5-1, pi-cm5-2, pi-cm5-3 (defined in hosts.ini under [cluster])
- **NAS node**: pi-cm5-4 (defined in hosts.ini under [nas])

## Code Organization

**Keep functions small and focused:**
- If you need comments to explain sections, split into functions
- Group related functionality into clear packages
- Prefer many small files over few large ones

## Architecture Principles

**This is always a feature branch:**
- Delete old code completely - no deprecation needed
- No versioned names (processV2, handleNew, ClientOld)
- No migration code unless explicitly requested
- No "removed code" comments - just delete it

**Prefer explicit over implicit:**
- Clear function names over clever abstractions
- Obvious data flow over hidden magic
- Direct dependencies over service locators

## Maximize Efficiency

**Parallel operations:** Run multiple searches, reads, and greps in single messages
**Multiple agents:** Split complex tasks - one for tests, one for implementation
**Batch similar work:** Group related file edits together

## Problem Solving

**When stuck:** Stop. The simple solution is usually correct.

**When uncertain:** "Let me ultrathink about this architecture."

**When choosing:** "I see approach A (simple) vs B (flexible). Which do you prefer?"

Your redirects prevent over-engineering. When uncertain about implementation, stop and ask for guidance.

## Testing Levels (Simple → Complex)

1. **YAML Syntax Validation** - Basic YAML format checking
2. **Ansible Syntax Check** - Ansible-specific syntax validation
3. **Static Analysis** - Code quality and best practices (ansible-lint)
4. **Dry Run Testing** - Simulate playbook execution without changes
5. **Molecule Testing** - Comprehensive role testing in isolated environments

## Development Workflow

- **Dependencies**: Install with `make install` (uses UV package manager)
- **Pre-commit validation**: YAML + Ansible syntax checking via pre-commit hooks
- **Static analysis**: `make lint` runs yamllint + ansible-lint for best practices
- **Isolated testing**: Molecule for role development and validation
- **Dry runs**: Test playbook logic before execution
- **Production deployment**: Only after validation pipeline passes

## Quality Gates

**YAML Linting (yamllint):**
- Configuration: `.yamllint` extends default rules

**Ansible Linting (ansible-lint):**
- Runs on all playbooks and roles

**Pre-commit Hooks:**
- Automatic validation on git commits

## Safety Practices

- **Idempotent playbooks**: Must be safe to run multiple times
- **Molecule**: Use Molecule for isolated testing instead of staging environment
- **Vagrant fallback**: Consider Vagrant if Molecule testing proves insufficient
- **Rollback documentation**: Recovery procedures for each service

## Git Commit Guidelines

**⚠️ MANDATORY**: Read `docs/git-commit-guidelines.md` before each commit.

**Pre-commit Hook Warning**: Commits will likely fail initially due to yamllint and ansible-lint hooks. Follow this workflow:

1. **Stage files**: `git add .`
2. **Run pre-commit**: `make precommit`
3. **Fix any issues** reported by linters
4. **Stage fixes**: `git add .`
5. **Commit**: Use proper message format from guidelines

**Key Requirements**:
- Imperative mood in subject line ("Add feature" not "Added feature")
- 50-character subject limit, 72-character body wrap
- Separate subject from body with blank line
- Use commit type prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `ci:`, `config:`

See `docs/git-commit-guidelines.md` for complete standards based on https://cbea.ms/git-commit/

## Core Files

- `upgrade.yml`: Main Ansible playbook that runs system upgrades across all hosts
- `hosts.ini`: Ansible inventory defining cluster and NAS node groups
- `ansible.cfg`: Ansible configuration pointing to hosts.ini and setting default user (alexanderp)
- `pyproject.toml`: UV/Python dependency management with ansible, ansible-lint, yamllint
- `.yamllint`: YAML linting configuration based on geerlingguy/pi-cluster standards
- `Makefile`: Development commands (install, lint, help)
- `.pre-commit-config.yaml`: Git hooks for automated quality checks

## Progress Tracking

- **TodoWrite** for task management
- **Clear naming** in all code

Focus on maintainable solutions over clever abstractions.
