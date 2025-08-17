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

**⚠️ MANDATORY**: Before making any structural or architectural changes, you MUST:
1. **Read** `docs/project-structure.md` to understand current architecture
2. **Update** `docs/project-structure.md` after implementing changes
3. **Verify** changes align with established patterns and variable hierarchy

**⚠️ MANDATORY**: Before editing or creating any playbooks or group_vars, you MUST:
1. **Read** `docs/playbook-guidelines.md` to understand documentation standards
2. **Follow** the established documentation patterns from `upgrade.yml`
3. **Document** WHY decisions were made, not just WHAT was implemented

**Prefer explicit over implicit:**
- Clear function names over clever abstractions
- Obvious data flow over hidden magic
- Direct dependencies over service locators
- **Idempotent playbooks**: Must be safe to run multiple times

## Git Commit Guidelines

**⚠️ MANDATORY**: Read `docs/git-commit-guidelines.md` before each commit.

**Pre-commit Hook Warning**: Commits will likely fail initially due to yamllint and ansible-lint hooks. Follow this workflow:

1. **Stage files**: `git add .`
2. **Run pre-commit**: `make precommit`
3. **Fix any issues** reported by linters
4. **Stage fixes**: `git add .`
5. **Commit**: Use proper message format from guidelines

## Maximize Efficiency

**Parallel operations:** Run multiple searches, reads, and greps in single messages
**Multiple agents:** Split complex tasks - one for tests, one for implementation
**Batch similar work:** Group related file edits together

## Problem Solving

**When stuck:** Stop. The simple solution is usually correct.

**When uncertain:** "Let me ultrathink about this architecture."

**When choosing:** "I see approach A (simple) vs B (flexible). Which do you prefer?"

Your redirects prevent over-engineering. When uncertain about implementation, stop and ask for guidance.

## Development Workflow

- **Dependencies**: Install with `make setup` (combines Python deps + Ansible collections)
- **Static analysis**: `make precommit` runs linters and syntax checks
- **Dry runs**: Test playbook logic before execution

## Core Files

To understand the project structure read

- `docs/project-structure.md`: **MANDATORY READ** - Complete project architecture and variable system

## Progress Tracking

- **TodoWrite** for task management
- **Clear naming** in all code

Focus on maintainable solutions over clever abstractions.
