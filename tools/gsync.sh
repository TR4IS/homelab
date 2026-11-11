#!/usr/bin/env bash
# gsync - one command that keeps every project identical on every device and on GitHub.
#
#   gsync            sync the project you are standing in (everything, if you are not in one)
#   gsync all        sync every project in your Code folder
#   gsync status     look only, change nothing
#   gsync new NAME   put a plain folder under Git and create its private GitHub repo
#   gsync clone      download every repo you own that is missing from this device
#
# Safe by design: never deletes anything, never force-pushes, refuses to commit secrets,
# and on a conflict it undoes its own attempt and tells you which files collide.
set -u

src="${BASH_SOURCE[0]//\\//}"
src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
TOOLS_DIR="$(cd "$(dirname "$src")" && pwd)"
CODE_DIR="${CODE_DIR:-$(dirname "$TOOLS_DIR")}"
GH_USER="${GH_USER:-TR4IS}"
HOST="$(hostname)"

if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else G=; Y=; R=; N=; fi
PROBLEMS=0
ok()   { printf '  %s[ok]%s %-28s %-10s %s\n' "$G" "$N" "$1" "$2" "$3"; }
warn() { printf '  %s[!!]%s %-28s %-10s %s\n' "$Y" "$N" "$1" "$2" "$3"; PROBLEMS=$((PROBLEMS+1)); }
bad()  { printf '  %s[XX]%s %-28s %-10s %s\n' "$R" "$N" "$1" "$2" "$3"; PROBLEMS=$((PROBLEMS+1)); }

SECRET_RE='gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhIjoi[A-Za-z0-9=]{20,}|[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}'

# Look at what is staged; return 1 (and set REASON) if it must not be committed.
REASON=""
scan_staged() {
  [ "${GSYNC_ALLOW:-0}" = 1 ] && return 0
  local f size nested
  nested="$(git diff --cached --raw --diff-filter=A | awk '$2=="160000"{print $NF}' | head -1)"
  if [ -n "$nested" ]; then REASON="another Git repo is inside this one: $nested (move it out of this project)"; return 1; fi
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "${f##*/}" in
      *.example|*.sample|*.template) ;;
      .env|.env.*|*.pem|*.key|*.p12|*.pfx|id_rsa|id_ed25519|*.kdbx)
        REASON="secret file would be uploaded: $f"; return 1;;
    esac
    if [ -f "$f" ]; then
      size=$(wc -c < "$f" | tr -d ' ')
      if [ "$size" -gt 50000000 ]; then REASON="file over 50 MB: $f (GitHub's limit is 100 MB)"; return 1; fi
    fi
  done < <(git -c core.quotepath=off diff --cached --name-only --diff-filter=AMR)
  if git diff --cached -U0 --no-color | grep -E '^\+' | grep -Eq "$SECRET_RE"; then
    REASON="something that looks like a token or private key is in the changes"; return 1
  fi
  return 0
}

# Sync one repo. $1 = folder, $2 = "sync" or "status"
one() {
  local dir="$1" mode="$2" name branch gd dirty behind=0 ahead=0 saved=0 msg=""
  name="${dir##*/}"
  cd "$dir" || { bad "$name" "-" "cannot open folder"; return; }
  branch="$(git symbolic-ref --short -q HEAD || true)"
  [ -n "$branch" ] || { warn "$name" "-" "detached HEAD - ask Claude"; return; }
  gd="$(git rev-parse --git-dir)"
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -f "$gd/MERGE_HEAD" ]; then
    bad "$name" "$branch" "a merge was left half-done - ask Claude to finish it"; return
  fi
  if [ -z "$(git remote)" ]; then
    warn "$name" "$branch" "NOT ON GITHUB - run: gsync new $name"; return
  fi
  if ! git fetch --quiet origin 2>/dev/null; then
    bad "$name" "$branch" "cannot reach GitHub (internet or SSH key?)"; return
  fi
  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  if git rev-parse -q --verify "origin/$branch" >/dev/null; then
    behind=$(git rev-list --count "HEAD..origin/$branch")
    ahead=$(git rev-list --count "origin/$branch..HEAD")
  elif git rev-parse -q --verify HEAD >/dev/null; then
    ahead=$(git rev-list --count HEAD)
  fi

  if [ "$mode" = status ]; then
    if [ "$dirty" = 0 ] && [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then ok "$name" "$branch" "clean, up to date"
    else warn "$name" "$branch" "unsaved files: $dirty | to download: $behind | to upload: $ahead"; fi
    return
  fi

  if [ "$dirty" != 0 ]; then
    git add -A
    if ! scan_staged; then
      git reset -q
      bad "$name" "$branch" "BLOCKED: $REASON (nothing was committed)"; return
    fi
    saved=$(git diff --cached --name-only | wc -l | tr -d ' ')
    if ! git commit -q -m "sync: $HOST $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1; then
      git reset -q; bad "$name" "$branch" "commit failed (is git user.name/email set? run setup)"; return
    fi
    msg="saved $saved file(s)"
  fi

  if git rev-parse -q --verify "origin/$branch" >/dev/null && [ "$behind" != 0 ]; then
    if ! git pull --rebase --quiet origin "$branch" >/dev/null 2>&1; then
      local files; files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git rebase --abort >/dev/null 2>&1
      bad "$name" "$branch" "CONFLICT in: ${files:-?}- nothing lost, ask Claude to merge"; return
    fi
    msg="${msg:+$msg, }downloaded $behind update(s)"
  fi

  if [ "$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 1)" != 0 ]; then
    if ! git push -u --quiet origin "$branch" >/dev/null 2>&1; then
      bad "$name" "$branch" "upload to GitHub failed - ask Claude"; return
    fi
    msg="${msg:+$msg, }uploaded"
  fi
  ok "$name" "$branch" "${msg:-already up to date}"
}

list_repos() {
  local d n
  for d in "$CODE_DIR"/*/; do
    d="${d%/}"; n="${d##*/}"
    case "$n" in _*|.*) continue;; esac
    [ -e "$d/.git" ] && echo "$d"
  done
}

cmd_all() {
  local mode="$1" d n
  echo "Code folder: $CODE_DIR   device: $HOST"
  while IFS= read -r d; do one "$d" "$mode"; done < <(list_repos)
  for d in "$CODE_DIR"/*/; do
    d="${d%/}"; n="${d##*/}"
    case "$n" in _*|.*) continue;; esac
    [ -e "$d/.git" ] || warn "$n" "-" "NOT IN GIT - run: gsync new $n  (or move it to _archive)"
  done
  summary
}

summary() {
  echo
  if [ "$PROBLEMS" = 0 ]; then echo "${G}All good. Everything matches GitHub.${N}"
  else echo "${Y}$PROBLEMS item(s) need attention - copy the lines above to Claude.${N}"; fi
}

write_gitignore() {
  cat > .gitignore <<'EOF'
# secrets - never commit these
.env
.env.*
!.env.example
*.pem
*.key
.claude/settings.local.json
# dependencies and build output
node_modules/
.venv/
venv/
__pycache__/
dist/
build/
# junk
*.log
logs/
*.rar
*.zip
*.tar
*.bak*
.DS_Store
Thumbs.db
EOF
}

cmd_new() {
  local name="${1:-}" dir repo
  [ -n "$name" ] || { echo "usage: gsync new <folder-name>"; return 1; }
  dir="$CODE_DIR/$name"
  [ -d "$dir" ] || { echo "no such folder: $dir"; return 1; }
  command -v gh >/dev/null 2>&1 || { echo "GitHub CLI missing. Install gh, then run: gh auth login"; return 1; }
  cd "$dir" || return 1
  [ -e .git ] || git init -q -b main
  [ -f .gitignore ] || write_gitignore
  [ -f .gitattributes ] || printf '* text=auto\n*.sh text eol=lf\n' > .gitattributes
  if [ -z "$(git remote)" ]; then
    repo="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._\n-' '-')"
    if gh repo view "$GH_USER/$repo" >/dev/null 2>&1; then
      git remote add origin "git@github.com:$GH_USER/$repo.git"
      if git ls-remote --heads origin 2>/dev/null | grep -q .; then
        git remote remove origin
        echo "GitHub already has a repo named $repo WITH code in it - not touching it. Ask Claude to compare them."; return 1
      fi
      echo "GitHub repo $repo already exists and is empty - using it."
    else
      gh repo create "$GH_USER/$repo" --private --source . --remote origin >/dev/null || { echo "could not create the GitHub repo"; return 1; }
      git remote set-url origin "git@github.com:$GH_USER/$repo.git"
    fi
  fi
  one "$dir" sync
  summary
}

cmd_clone() {
  command -v gh >/dev/null 2>&1 || { echo "GitHub CLI missing. Install gh, then run: gh auth login"; return 1; }
  gh repo list "$GH_USER" --limit 300 --json name,sshUrl --jq '.[] | "\(.name) \(.sshUrl)"' |
  while read -r n url; do
    [ -e "$CODE_DIR/$n" ] && continue
    git clone -q "$url" "$CODE_DIR/$n" && echo "downloaded $n"
  done
  echo "done."
}

usage() { sed -n '2,10p' "$src" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  all)    cmd_all sync;;
  status) cmd_all status;;
  new)    shift; cmd_new "${1:-}";;
  clone)  cmd_clone;;
  help|-h|--help) usage;;
  "")
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ]; then top="$(cd "$top" && pwd)"; one "$top" sync; summary; else cmd_all sync; fi;;
  *) usage; exit 1;;
esac
[ "$PROBLEMS" = 0 ]
