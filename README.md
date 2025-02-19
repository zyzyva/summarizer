# start Ollama
  ollama run codegemma

# Navigate to your git repository
cd your-repository

# Create the hooks directory if it doesn't exist
mkdir -p .git/hooks

# Create the prepare-commit-msg file
touch .git/hooks/prepare-commit-msg

# Make it executable
chmod +x .git/hooks/prepare-commit-msg