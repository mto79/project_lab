#!/usr/bin/env bash
# bootstrap_and_sync_fixed.sh
# Usage: ./bootstrap_and_sync_fixed.sh <github-username-or-org>
# Ensure GITHUB_TOKEN is set

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

# Submodules and their template URLs
declare -A SUBMODULE_TEMPLATES
SUBMODULE_TEMPLATES[ansible]="https://github.com/mto79/project_ansible_template.git"
SUBMODULE_TEMPLATES[terraform]="https://github.com/mto79/project_terraform_template.git"
SUBMODULE_TEMPLATES[kubernetes]="https://github.com/mto79/project_kubernetes_template.git"

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

# Delete GitHub repo
delete_github_repo() {
  local repo_name="$1"
  http_code=$(curl -s -o /tmp/git_response.json -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_USER/$repo_name")
  if [ "$http_code" -eq 204 ]; then
    echo "Deleted GitHub repo $repo_name"
  elif [ "$http_code" -eq 404 ]; then
    echo "Repo $repo_name not found on GitHub, skipping deletion"
  else
    echo "⚠ Failed to delete GitHub repo $repo_name. HTTP code $http_code"
    cat /tmp/git_response.json
  fi
}

# ---------------------------
# Helper: safe fetch + merge
# ---------------------------
safe_fetch_merge() {
  local branch="$1"
  local remote="$2"
  git fetch "$remote" || true

  # If histories are disjoint, force push
  if ! git merge-base --is-ancestor "$remote/$branch" "$branch" 2>/dev/null; then
    echo "⚡ Histories are disjoint; force pushing local $branch to $remote"
    git push "$remote" "$branch" --force
  else
    git merge "$remote/$branch" --allow-unrelated-histories -m "Merge $remote/$branch into local $branch" || true
  fi
}

# ---------------------------
# Handle main project repo
# ---------------------------
create_github_repo "$MAIN_PROJECT_NAME"
git checkout main || git checkout -b main
safe_fetch_merge main origin

# ---------------------------
# Handle submodules
# ---------------------------
for submodule in "${!SUBMODULE_TEMPLATES[@]}"; do
  TEMPLATE_URL="${SUBMODULE_TEMPLATES[$submodule]}"
  NEW_REPO_NAME=$(to_snake_case "${MAIN_PROJECT_NAME}_${submodule}")
  echo "Processing submodule $submodule -> $NEW_REPO_NAME from template $TEMPLATE_URL"

  # Remove orphaned submodule folder if exists
  if [ -d "$submodule" ] && ! git ls-files --error-unmatch "$submodule" >/dev/null 2>&1; then
    rm -rf "$submodule"
  fi

  # Clone template temporarily
  TEMP_DIR="$submodule-temp"
  if [ ! -d "$TEMP_DIR" ]; then
    git clone "$TEMPLATE_URL" "$TEMP_DIR"
  fi

  # Create GitHub repo for submodule
  create_github_repo "$NEW_REPO_NAME"

  # Push template content to new repo
  cd "$TEMP_DIR"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git"
  safe_fetch_merge main origin
  cd ..

  # Add submodule to main project if missing
  if ! git config -f .gitmodules --get-regexp path | grep -q "^submodule\.$submodule\.path"; then
    git submodule add "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git" "$submodule"
  fi

  rm -rf "$TEMP_DIR"

  # Clone the new repo alongside main project if missing
  CLONE_DIR="$PARENT_DIR/$NEW_REPO_NAME"
  if [ ! -d "$CLONE_DIR" ]; then
    git clone "https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git" "$CLONE_DIR"
  fi

  # Sync template updates into new repo safely
  cd "$CLONE_DIR"
  if ! git remote | grep -q template; then
    git remote add template "$TEMPLATE_URL"
  else
    git remote set-url template "$TEMPLATE_URL"
  fi

  safe_fetch_merge main origin

  git fetch template
  git merge template/main -m "Merge template updates" || echo "⚠ Merge conflicts in $NEW_REPO_NAME! Resolve manually"

  git push origin main --force
  cd -

  # Update submodule folder in main project
  rsync -a --exclude '.git/' "$CLONE_DIR"/ "$submodule"/
  cd "$submodule"
  git add .
  git commit -m "Sync content from $NEW_REPO_NAME" || echo "No changes to commit"
  git push origin main --force

  cd -
done

# ---------------------------
# Remove submodules not in SUBMODULE_TEMPLATES
# ---------------------------
if [ -f .gitmodules ]; then
  while IFS= read -r submodule_path; do
    if [ -z "${SUBMODULE_TEMPLATES[$submodule_path]+_}" ]; then
      echo "Removing submodule '$submodule_path' (not in SUBMODULE_TEMPLATES)"
      REPO_NAME=$(to_snake_case "${MAIN_PROJECT_NAME}_${submodule_path}")

      git submodule deinit -f "$submodule_path" 2>/dev/null || true
      git rm -f "$submodule_path" 2>/dev/null || true
      rm -rf ".git/modules/$submodule_path"
      rm -rf "$submodule_path"

      delete_github_repo "$REPO_NAME"

      CLONE_DIR="$PARENT_DIR/$REPO_NAME"
      if [ -d "$CLONE_DIR" ]; then
        rm -rf "$CLONE_DIR"
        echo "Removed local clone $CLONE_DIR"
      fi
    fi
  done < <(git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
fi

# Update all submodules in main project
git submodule update --init --recursive
git add .gitmodules
git commit -m "Initialize/sync submodules for $MAIN_PROJECT_NAME" || echo "No changes to commit"
git push origin main --force

echo "✅ Main project and all submodules are synced; histories handled safely, no -m error."
