#!/bin/bash
# bootstrap_submodules_sync_full.sh
# Usage: ./bootstrap_submodules_sync_full.sh <github-username-or-org>
# Ensure GITHUB_TOKEN is set with repo creation permissions

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <github-username-or-org>"
  exit 1
fi

GITHUB_USER="$1"
MAIN_PROJECT_NAME=$(basename "$(pwd)")
PARENT_DIR=$(pwd)/..
echo "Main project: $MAIN_PROJECT_NAME"
echo "Submodules will be cloned alongside main project into: $PARENT_DIR"

if [ ! -f .gitmodules ]; then
  echo "No .gitmodules found. Nothing to do."
  exit 0
fi

# Convert string to snake_case
to_snake_case() {
  echo "$1" | sed -E 's/([A-Z])/_\L\1/g' |
    sed -E 's/[^a-z0-9]+/_/g' |
    sed -E 's/^_+|_+$//g'
}

# Create GitHub repo if not exists
create_github_repo() {
  local repo_name="$1"
  response=$(curl -s -w "%{http_code}" -o /tmp/git_response.json \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d "{\"name\":\"$repo_name\",\"private\":false}" \
    https://api.github.com/user/repos)
  http_code="${response: -3}"
  if [ "$http_code" -eq 401 ]; then
    echo "❌ Authentication failed. Check GITHUB_TOKEN"
    cat /tmp/git_response.json
    exit 1
  elif [ "$http_code" -ne 201 ] && [ "$http_code" -ne 422 ]; then
    echo "❌ Failed to create repository $repo_name. HTTP code $http_code"
    cat /tmp/git_response.json
    exit 1
  fi
}

# Get submodule paths from .gitmodules
mapfile -t submodules < <(git config -f .gitmodules --get-regexp path | awk '{print $2}')

for path in "${submodules[@]}"; do
  TEMPLATE_URL=$(git config -f .gitmodules --get submodule."$path".url)
  NEW_REPO_NAME=$(to_snake_case "${MAIN_PROJECT_NAME}_${path}")
  echo "Processing submodule $path -> $NEW_REPO_NAME"

  # Remove old submodule folder if orphaned
  if [ -d "$path" ] && ! git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    rm -rf "$path"
  fi

  # Clone template repo temporarily
  TEMP_DIR="$path-temp"
  if [ ! -d "$TEMP_DIR" ]; then
    git clone "$TEMPLATE_URL" "$TEMP_DIR"
  fi

  # Create new GitHub repo
  create_github_repo "$NEW_REPO_NAME"

  # Push template content to new repo
  cd "$TEMP_DIR"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git"
  git push -u origin main || {
    echo "❌ Push failed"
    exit 1
  }
  cd ..

  # Add submodule to main project if missing
  if ! git config -f .gitmodules --get-regexp path | grep -q "^submodule\.$path\.path"; then
    git submodule add "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git" "$path"
  fi
  rm -rf "$TEMP_DIR"

  # Clone the new repo alongside main project if missing
  CLONE_DIR="$PARENT_DIR/$NEW_REPO_NAME"
  if [ ! -d "$CLONE_DIR" ]; then
    git clone "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git" "$CLONE_DIR"
  fi

  # Sync template updates into new repo
  cd "$CLONE_DIR"
  if ! git remote | grep -q template; then
    git remote add template "$TEMPLATE_URL"
  fi
  git fetch template
  git checkout main
  git merge template/main -m "Merge updates from template" || echo "⚠ Merge conflicts in $NEW_REPO_NAME! Resolve manually"
  git push origin main
  cd -

  # Update submodule folder in main project
  rsync -a --exclude '.git/' "$CLONE_DIR"/ "$path"/
  cd "$path"
  git add .
  git commit -m "Sync content from $NEW_REPO_NAME" || echo "No changes to commit"
  git push
  cd -

done

# Update all submodules in main project
git submodule update --init --recursive
git add .gitmodules
git commit -m "Initialize/sync submodules for $MAIN_PROJECT_NAME" || echo "No changes to commit"

echo "✅ All submodules are now fully synced with template repos and ready for development."
