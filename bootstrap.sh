#!/usr/bin/env bash
# bootstrap.sh
# Usage: ./bootstrap.sh <github-username-or-org>
# Requires: gh CLI authenticated (gh auth login)

set -e

if ! gh auth status &>/dev/null; then
  echo "❌ gh CLI is not authenticated. Run: gh auth login"
  exit 1
fi

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
SUBMODULE_TEMPLATES[helm]="https://github.com/mto79/project_helm_template.git"
SUBMODULE_TEMPLATES[gitops]="https://github.com/mto79/project_gitops_template.git"

# Convert string to snake_case
to_snake_case() {
  echo "$1" | sed -E 's/([A-Z])/_\L\1/g' |
    sed -E 's/[^a-z0-9]+/_/g' |
    sed -E 's/^_+|_+$//g'
}

# Create GitHub repo if not exists
create_github_repo() {
  local repo_name="$1"
  if gh repo view "$GITHUB_USER/$repo_name" &>/dev/null; then
    echo "Repo $repo_name already exists, skipping creation"
  else
    gh repo create "$GITHUB_USER/$repo_name" --public 2>/dev/null || true
    echo "Created GitHub repo $repo_name"
  fi
}

# Delete GitHub repo
delete_github_repo() {
  local repo_name="$1"
  if gh repo view "$GITHUB_USER/$repo_name" &>/dev/null; then
    gh repo delete "$GITHUB_USER/$repo_name" --yes
    echo "Deleted GitHub repo $repo_name"
  else
    echo "Repo $repo_name not found on GitHub, skipping deletion"
  fi
}

# ---------------------------
# Handle main project repo
# ---------------------------
create_github_repo "$MAIN_PROJECT_NAME"
git checkout main 2>/dev/null || git checkout -b main
git push -u origin main 2>/dev/null || true

# ---------------------------
# Handle submodules
# ---------------------------
for submodule in "${!SUBMODULE_TEMPLATES[@]}"; do
  TEMPLATE_URL="${SUBMODULE_TEMPLATES[$submodule]}"
  NEW_REPO_NAME=$(to_snake_case "${MAIN_PROJECT_NAME}_${submodule}")
  CLONE_DIR="$PARENT_DIR/$NEW_REPO_NAME"
  ORIGIN_URL="https://github.com/$GITHUB_USER/$NEW_REPO_NAME.git"
  echo ""
  echo "==> $submodule → $NEW_REPO_NAME"

  create_github_repo "$NEW_REPO_NAME"

  if [ ! -d "$CLONE_DIR" ]; then
    # Clone from template so the project repo shares its history from day one.
    # Subsequent `git merge template/main` calls will always fast-forward or
    # produce a clean merge — no unrelated histories ever again.
    git clone "$TEMPLATE_URL" "$CLONE_DIR"
    cd "$CLONE_DIR"
    git remote rename origin template
    git remote add origin "$ORIGIN_URL"
    git push -u origin main
  else
    cd "$CLONE_DIR"
    # Ensure remotes are present and up to date
    git remote get-url origin   &>/dev/null || git remote add origin   "$ORIGIN_URL"
    git remote get-url template &>/dev/null || git remote add template "$TEMPLATE_URL"
    git remote set-url template "$TEMPLATE_URL"

    # Stash local changes so they don't block the merge
    git stash --include-untracked 2>/dev/null || true

    git fetch origin
    git fetch template

    # Merge template updates.
    # --allow-unrelated-histories is a one-time reconciliation for repos that
    # diverged before this script was fixed; once merged they share ancestry
    # and this flag becomes a no-op on all future runs.
    # -X theirs ensures template content always wins on conflict so the project
    # repo stays in sync without needing manual resolution.
    git merge template/main \
      --allow-unrelated-histories \
      -X theirs \
      -m "Merge template updates into $NEW_REPO_NAME" \
      || echo "⚠ Merge failed in $NEW_REPO_NAME — resolve manually"

    git push origin main --force
  fi
  cd -

  # Register as submodule in the parent project if missing
  if ! git config -f .gitmodules --get "submodule.$submodule.url" &>/dev/null; then
    git submodule add "$ORIGIN_URL" "$submodule"
  fi

  # Advance the submodule pointer to the latest commit just pushed to CLONE_DIR.
  # No rsync needed — the content is already on the remote via CLONE_DIR.
  git submodule update --remote "$submodule"
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

# ---------------------------
# Finalize main project
# ---------------------------
git add .gitmodules
git add $(git submodule foreach --quiet 'echo $displaypath') 2>/dev/null || git add -u
git commit -m "Sync submodules for $MAIN_PROJECT_NAME" || echo "No changes to commit"
git push origin main

echo ""
echo "✅ All submodules synced."
