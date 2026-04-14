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
├── scripts/           # Utility scripts for AI workflows and repo tooling
│   └── chunk_repo.sh  # Chunk a code repository into LLM-ready markdown files
└── README.md
```

---

## Contents

### Scripts

| File | Description |
|------|-------------|
| [`scripts/chunk_repo.sh`](./scripts/chunk_repo.sh) | Splits a local code repository into word-limited markdown chunks, ready for feeding into LLMs or AI pipelines. Handles binary assets, syntax highlighting hints, and safe fenced code blocks. |

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
