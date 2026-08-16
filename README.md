# applied-ai-innovation

> Building real-world AI agents, GenAI tools, and automation workflows that simplify everyday work — open-source, community-driven, and built for practical impact.

---

## About

**applied-ai-innovation** is an open-source collection of AI-powered tools, scripts, agents, and experiments focused on making everyday work smarter and faster. The projects here span GenAI applications, LLM tooling, intelligent automation, and workflow utilities — all built with practical impact in mind.

Whether you're an AI practitioner, developer, or curious builder, this repository is a living resource for applied AI innovation.

---

## Repository Structure

```
applied-ai-innovation/
├── scripts/               # Utility scripts for AI workflows and repo tooling
│   └── chunk_repo.sh      # Chunk a code repository into LLM-ready markdown files
├── plugins/               # Claude Code plugins (this repo is a plugin marketplace)
│   ├── gh-track/          # GitHub issue + project tracking for superpowers workflows
│   └── ssm-ssh-access/    # SSH/SCP into private EC2 instances over AWS SSM
└── README.md
```

---

## Contents

### Scripts

| File | Description |
|------|-------------|
| [`scripts/chunk_repo.sh`](./scripts/chunk_repo.sh) | Splits a local code repository into word-limited markdown chunks, ready for feeding into LLMs or AI pipelines. Handles binary assets, syntax highlighting hints, and safe fenced code blocks. |

### Plugins

This repository is a [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins).
Add it once, then install whichever plugins you want:

```
/plugin marketplace add mr-ashishpanda/applied-ai-innovation
/plugin install gh-track@applied-ai-innovation
/plugin install ssm-ssh-access@applied-ai-innovation
```

| Plugin | Description |
|--------|-------------|
| [`plugins/gh-track`](./plugins/gh-track/README.md) | GitHub issue and project tracking for superpowers development workflows. Every work item becomes one issue carrying its stage, artifact links, task checklist, and a timeline of decisions — without duplicating spec or plan prose into GitHub. See its README's [Install](./plugins/gh-track/README.md#install) section for the per-project setup step. |
| [`plugins/ssm-ssh-access`](./plugins/ssm-ssh-access/README.md) | SSH/SCP into any private AWS EC2 instance by instance ID over AWS Systems Manager (SSM) Session Manager — no bastion, no open port 22, no VPN. Pushes a temporary key, makes `ssh <instance-id>` work, and revokes it afterward. Cross-platform (macOS, Linux, Windows). |

---

## Getting Started

Clone the repository:

```bash
git clone https://github.com/mr-ashishpanda/applied-ai-innovation.git
cd applied-ai-innovation
```

### Using `chunk_repo.sh`

```bash
# Make executable
chmod +x scripts/chunk_repo.sh

# Chunk a repository (default: 100,000 words per chunk)
./scripts/chunk_repo.sh /path/to/your/repo

# Chunk with a custom word limit
./scripts/chunk_repo.sh /path/to/your/repo 50000
```

Output is written to `./output/`:
- `chunk_001.md`, `chunk_002.md`, ... — code files wrapped in fenced markdown blocks
- `assets/` — binary/media files preserved as-is

---

## Contributing

Contributions are welcome. If you have an AI tool, script, agent, or experiment that solves a real problem, open a PR or start a discussion.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-tool`)
3. Commit your changes
4. Push and open a pull request

---

## License

MIT — free to use, modify, and distribute.
