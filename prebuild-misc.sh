mkdir -p "$BUILD_ROOT/files/usr/bin"
cat > "$BUILD_ROOT/files/usr/bin/etcgit" <<'EOF'
#!/bin/sh
set -e

BRANCH_DEFAULT="${ETC_GIT_BRANCH:-main}"

# Add host key to known_hosts if remote is SSH and host is missing
add_known_host() {
  host="$1"
  [ -z "$host" ] && return 0
  case "$host" in
    *:* ) host="${host%%:*}";;  # strip port
  esac
  mkdir -p /root/.ssh
  touch /root/.ssh/known_hosts
  chmod 700 /root/.ssh
  chmod 644 /root/.ssh/known_hosts
  if ! grep -qE "^[^ ]* $host " /root/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 "$host" >> /root/.ssh/known_hosts 2>/dev/null || true
  fi
}

# Extract host from a remote URL (ssh or https)
host_from_url() {
  url="$1"
  case "$url" in
    ssh://*@* ) echo "$url" | awk -F/ '{print $3}' | awk -F@ '{print $2}' ;;
    *@*:* )     echo "$url" | awk -F@ '{print $2}' | awk -F: '{print $1}' ;;
    https://* ) echo "$url" | awk -F/ '{print $3}' ;;
    http://* )  echo "$url" | awk -F/ '{print $3}' ;;
    * )         echo "" ;;
  esac
}

cmd="$1"; shift 2>/dev/null || true

case "$cmd" in
  help|-h|--help|"")
    cat <<USAGE
etcgit — convenience wrapper for "git -C /etc"

Quick start:
  etcgit init [REMOTE_URL] [BRANCH]     initialize /etc repo (optional origin)
  etcgit import <REMOTE_URL> [BRANCH]   HARD-sync /etc from remote branch
  etcgit status | add | commit | push   proxied to: git -C /etc ...

Notes:
  • No automatic push. After init/import, run:  etcgit push -u origin <branch>
  • Default branch: ${BRANCH_DEFAULT}

Examples:
  etcgit init
  etcgit init git@github.com:you/openwrt-etc.git main
  etcgit import git@github.com:you/openwrt-etc.git main
USAGE
    ;;

  init)
    REMOTE="$1"; BR="${2:-$BRANCH_DEFAULT}"

    [ -d /etc/.git ] || git -C /etc init

    # Set identity if empty
    if ! git -C /etc config user.name >/dev/null; then
      git -C /etc config user.name "${ETC_GIT_NAME:-OpenWrt}"
    fi
    if ! git -C /etc config user.email >/dev/null; then
      git -C /etc config user.email "${ETC_GIT_EMAIL:-openwrt@router}"
    fi

    # Set origin if provided
    if [ -n "${REMOTE:-}" ]; then
      if git -C /etc remote | grep -q '^origin$'; then
        git -C /etc remote set-url origin "$REMOTE"
      else
        git -C /etc remote add origin "$REMOTE"
      fi
      host="$(host_from_url "$REMOTE")"
      add_known_host "$host"
    fi

    # First commit if repo is empty
    if ! git -C /etc rev-parse --verify HEAD >/dev/null 2>&1; then
      git -C /etc add -A
      git -C /etc commit -m "Initial /etc snapshot"
      git -C /etc branch -M "$BR"
    fi

    echo "Initialized /etc as a git repo on branch '$BR'."
    if [ -n "${REMOTE:-}" ]; then
      echo "Origin set to: $REMOTE"
      echo "Next steps: etcgit push -u origin $BR"
    fi
    ;;

  import)
    REMOTE="$1"; BR="${2:-$BRANCH_DEFAULT}"
    if [ -z "$REMOTE" ]; then
      echo "usage: etcgit import <REMOTE_URL> [BRANCH]" >&2
      exit 1
    fi

    [ -d /etc/.git ] || git -C /etc init

    # Identity if missing
    if ! git -C /etc config user.name >/dev/null; then
      git -C /etc config user.name "${ETC_GIT_NAME:-OpenWrt}"
    fi
    if ! git -C /etc config user.email >/dev/null; then
      git -C /etc config user.email "${ETC_GIT_EMAIL:-openwrt@router}"
    fi

    if git -C /etc remote | grep -q '^origin$'; then
      git -C /etc remote set-url origin "$REMOTE"
    else
      git -C /etc remote add origin "$REMOTE"
    fi

    host="$(host_from_url "$REMOTE")"
    add_known_host "$host"

    git -C /etc fetch --depth=1 origin "$BR"
    git -C /etc reset --hard "origin/$BR"
    git -C /etc branch -M "$BR"

    echo "/etc has been hard-synced to origin/$BR."
    echo "Next steps: review changes, then etcgit push (if you commit new local changes)."
    ;;

  *)
    # Proxy all other commands to git -C /etc
    exec git -C /etc "$cmd" "$@"
    ;;
esac
EOF
chmod +x "$BUILD_ROOT/files/usr/bin/etcgit"

mkdir -p "$BUILD_ROOT/files/etc/profile.d"
cat > "$BUILD_ROOT/files/etc/profile.d/99-etcgit-banner.sh" <<'EOF'
# Show etcgit tips and warnings on interactive shells
[ -t 1 ] || return 0

if [ ! -d /etc/.git ]; then
  cat <<'BANNER'

 ┌─────────────────────────────────────────────────────────────┐
 │  /etc is not under git yet                                  │
 │                                                             │
 │  Initialize new repo:   etcgit init [REMOTE_URL] [BRANCH]   │
 │  Import from remote:    etcgit import <REMOTE_URL> [BRANCH] │
 │                                                             │
 │  Examples:                                                  │
 │    etcgit init                                              │
 │    etcgit import git@github.com:you/openwrt-etc.git main    │
 │                                                             │
 │  Tip: put your SSH key at /root/.ssh/id_ed25519             │
 └─────────────────────────────────────────────────────────────┘

BANNER
  return 0
fi

# Repo exists: show useful warnings
branch="$(git -C /etc rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
status_porcelain="$(git -C /etc status --porcelain 2>/dev/null || true)"
status_short="$(git -C /etc status -sb 2>/dev/null || true)"

# Ahead/behind detection (only if upstream configured)
upstream="$(git -C /etc rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
ahead="0"
behind="0"
if [ -n "$upstream" ]; then
  set -- $(git -C /etc rev-list --left-right --count "$upstream"...HEAD 2>/dev/null || echo "0 0")
  behind="$1"
  ahead="$2"
fi

warned=0
if [ -n "$status_porcelain" ]; then
  warned=1
  echo
  echo "⚠ Uncommitted changes in /etc (branch: $branch)"
  echo "$status_short" | sed 's/^/   /'
  # Show a concise diff summary (avoid flooding the terminal)
  diffstat="$(git -C /etc --no-pager diff --stat 2>/dev/null || true)"
  [ -n "$diffstat" ] && { echo; echo "$diffstat" | sed 's/^/   /'; }
  echo "→ Commit/push:  etcgit add -A && etcgit commit -m \"...\" && etcgit push"
fi

if [ "$ahead" -gt 0 ]; then
  [ "$warned" -eq 0 ] && echo
  echo "⚠ Local branch '$branch' is ahead of '$upstream' by $ahead commit(s)."
  echo "→ Push:  etcgit push"
  warned=1
fi

if [ "$behind" -gt 0 ]; then
  [ "$warned" -eq 0 ] && echo
  echo "⚠ Local branch '$branch' is behind '$upstream' by $behind commit(s)."
  echo "→ Update:  etcgit pull --rebase"
  warned=1
fi

[ "$warned" -eq 1 ] && echo
unset branch status_porcelain status_short upstream ahead behind warned
EOF
chmod +x "$BUILD_ROOT/files/etc/profile.d/99-etcgit-banner.sh"
