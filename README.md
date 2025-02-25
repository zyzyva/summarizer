# Git Commit Message Generator

This tool automatically generates meaningful commit messages by analyzing your staged changes using Ollama and a local LLM.

## Features

- Analyzes git diffs to understand code changes
- Generates concise, descriptive commit messages
- Follows Git commit message best practices (50/72 rule)
- Verifies changes against the actual diff
- Works with any Ollama-compatible model

## Prerequisites

- [Ollama](https://ollama.ai) installed on your system
- A code-focused LLM model (recommended: `codellama:34b`)

## Installation

1. **Start Ollama**

   ```bash
   ollama serve
   ```

2. **Pull a recommended model**

   ```bash
   ollama pull codellama:34b
   ```

3. **Set up the git hook**

   ```bash
   # Navigate to your git repository
   cd your-repository

   # Create the hooks directory if it doesn't exist
   mkdir -p .git/hooks

   # Create the prepare-commit-msg file
   curl -o .git/hooks/prepare-commit-msg https://raw.githubusercontent.com/zyzyva/summarizer/main/summarizer.rb
   # or copy the summarizer.rb file manually

   # Make it executable
   chmod +x .git/hooks/prepare-commit-msg
   ```

## Usage

After installation, the tool works automatically when you commit:

```bash
git add .
git commit
```

The hook will:
1. Analyze your staged changes
2. Generate a descriptive commit message
3. Load it into your editor
4. Allow you to review and modify before finalizing

## Configuration

You can specify a different model by setting the `OLLAMA_MODEL` environment variable:

```bash
OLLAMA_MODEL=codellama:34b git commit
```

## Troubleshooting

- **"Could not connect to Ollama"**: Ensure Ollama is running with `ollama serve`
- **Slow responses**: Larger models give better results but take longer
- **Inaccurate messages**: Try a different model or check your diff

## License

MIT