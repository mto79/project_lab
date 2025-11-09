#!/usr/bin/env bash
# bootstrap_submodules_snakecase.sh
# Usage: ./bootstrap_submodules_snakecase.sh <github-username-or-org>
# Make sure GITHUB_TOKEN is set in your environment with repo creation permissions
#
#

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <github-username-or-org>"
  exit 1
fi

GITHUB_USER="$1"
MAIN_PROJECT_NAME=$(basename "$(pwd)")
echo "Main project: $MAIN_PROJECT_NAME"

if [ ! -f .gitmodules ]; then
  echo "No .gitmodules found. Nothing to do."
  exit 0
fi

# Convert string to snake_case
to_snake_case() {
  echo "$1" | sed -E 's/([A-Z])/_\L\1/g' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_+|_+$//g'
}

# Create GitHub repository and handle errors
create_github_repo() {
  local repo_name="$1"
  echo "Creating GitHub repo: $repo_name"

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

# Read submodule paths from .gitmodules
mapfile -t submodules < <(git config -f .gitmodules --get-regexp path | awk '{print $2}')

for path in "${submodules[@]}"; do
  template_url=$(git config -f .gitmodules --get submodule."$path".url)
  new_repo_name=$(to_snake_case "${MAIN_PROJECT_NAME}_${path}")

  echo "Processing submodule $path -> new repo $new_repo_name"

  # Clean up old submodule if it exists
  if [ -d "$path" ] || git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    echo "Cleaning existing submodule/folder $path"
    git submodule deinit -f "$path" 2>/dev/null || true
    git rm -f "$path" 2>/dev/null || true
    rm -rf ".git/modules/$path" "$path"
  fi

  # Clone template submodule fully
  git clone "$template_url" "$path-temp"

  # Create new GitHub repo
  create_github_repo "$new_repo_name"

  # Push template content to new repo via HTTPS
  cd "$path-temp"
  git remote remove origin
  git remote add origin "https://github.com/$GITHUB_USER/$new_repo_name.git"
  git push -u origin main || {
    echo "❌ Push failed"
    exit 1
  }
  cd ..

  # Add the new repo as a submodule
  git submodule add "https://github.com/$GITHUB_USER/$new_repo_name.git" "$path"

  # Clean up temp clone
  rm -rf "$path-temp"
done

# Initialize and update all submodules
git submodule update --init --recursive

git add .gitmodules
git commit -m "Initialize submodules as new repositories for $MAIN_PROJECT_NAME"

echo "✅ All submodules are now new independent repositories (HTTPS, snake_case, safely replaced)."
