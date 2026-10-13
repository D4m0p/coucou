#!/usr/bin/env bash
# Updates a Coucou built from this checkout on Linux: brings in upstream's main,
# replays the local commits on top, rebuilds, and swaps the installed binaries.
# The Tauri app has no updater of its own, and a release AppImage would drop the
# local commits; this keeps both.
#
#   ./scripts/update-linux.sh                  update if upstream moved
#   ./scripts/update-linux.sh --check          only say whether there is an update
#   ./scripts/update-linux.sh --force          rebuild and reinstall even if nothing moved
#   ./scripts/update-linux.sh --push           also push the rebased branch to its remote
#   ./scripts/update-linux.sh --install-timer  check once a day (systemd user timer);
#                                              with --push, the timer pushes too
#   ./scripts/update-linux.sh --remove-timer
#
# Nothing is touched when the working tree is dirty or the rebase conflicts. The
# branch as it was is kept under backup/<branch>-<date>, the binaries as *.bak.
#
#   COUCOU_PREFIX     where Coucou is installed (bin/coucou, lib/Coucou/coucou-hook).
#                     Default: read from the desktop entry, else ~/.local/opt/coucou
#   COUCOU_UPSTREAM   remote and branch to follow. Default: origin/main
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/windows"
UPSTREAM="${COUCOU_UPSTREAM:-origin/main}"
REMOTE="${UPSTREAM%%/*}"
REMOTE_BRANCH="${UPSTREAM#*/}"
DESKTOP_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/fr.louisraille.coucou.desktop"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="coucou-update"

# rustup installs cargo here, and a systemd unit does not read the shell profile.
export PATH="$HOME/.cargo/bin:$PATH"

die() { echo "error: $*" >&2; exit 1; }

# A desktop notification when there is no terminal to read (the timer).
say() {
  echo "$*"
  if [ ! -t 1 ] && command -v notify-send >/dev/null; then
    notify-send -a Coucou "Coucou" "$*" || true
  fi
}

prefix() {
  if [ -n "${COUCOU_PREFIX:-}" ]; then echo "$COUCOU_PREFIX"; return; fi
  local exe=""
  if [ -f "$DESKTOP_ENTRY" ]; then
    exe=$(sed -nE 's/^Exec=("?)([^" ]+)\1.*/\2/p' "$DESKTOP_ENTRY" | head -1)
  fi
  case "$exe" in
    */bin/coucou) echo "${exe%/bin/coucou}" ;;
    *) echo "$HOME/.local/opt/coucou" ;;
  esac
}

install_timer() {
  command -v systemctl >/dev/null || die "systemd is not available"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=Update Coucou from source

[Service]
Type=oneshot
ExecStart=$REPO_ROOT/scripts/update-linux.sh$([ "$PUSH" -eq 1 ] && echo ' --push')
Environment=COUCOU_PREFIX=$(prefix)
Environment=COUCOU_UPSTREAM=$UPSTREAM
Nice=10
EOF
  cat > "$UNIT_DIR/$UNIT.timer" <<EOF
[Unit]
Description=Check for Coucou updates once a day

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer"
  echo "Coucou checks for updates once a day$([ "$PUSH" -eq 1 ] && echo ', and pushes the rebased branch'). Its output: journalctl --user -u $UNIT"
}

remove_timer() {
  systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer"
  systemctl --user daemon-reload
  echo "Coucou no longer checks for updates."
}

CHECK=0 FORCE=0 PUSH=0 TIMER=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --push) PUSH=1 ;;
    --install-timer) TIMER=install ;;
    --remove-timer) TIMER=remove ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$arg' (see --help)" ;;
  esac
done
case "$TIMER" in
  install) install_timer; exit 0 ;;
  remove) remove_timer; exit 0 ;;
esac

PREFIX="$(prefix)"
STAMP="$PREFIX/.coucou-commit"
cd "$REPO_ROOT"

BRANCH=$(git symbolic-ref --quiet --short HEAD) || die "the checkout is on no branch"

# A rebase leaves the branch's own remote (a fork) behind. The mark outlives a
# push that failed, or a run without --push, so a later run catches up; commits
# made by hand since are not what it is for, and nothing is pushed without it.
PENDING="$(git rev-parse --git-dir)/coucou-push-pending"
push_branch() {
  [ "$PUSH" -eq 1 ] && [ -f "$PENDING" ] || return 0
  local to
  to=$(git config "branch.$BRANCH.remote" || true)
  if [ -z "$to" ] || [ "$to" = "$REMOTE" ]; then
    echo "warning: $BRANCH tracks no remote of its own; not pushed" >&2
  elif git push --quiet --force-with-lease "$to" "$BRANCH"; then
    rm -f "$PENDING"
    echo "Pushed $BRANCH to $to."
  else
    say "Coucou could not push $BRANCH to $to; the next update tries again."
  fi
}

# ── 1. What upstream has ──────────────────────────────────────────────────────
# The refspec is spelled out: a clone narrowed to one tag would otherwise fetch
# nothing and report that all is up to date.
git fetch --quiet "$REMOTE" "+refs/heads/$REMOTE_BRANCH:refs/remotes/$REMOTE/$REMOTE_BRANCH" \
  || die "could not reach $REMOTE"

BEHIND=$(git rev-list --count "HEAD..$UPSTREAM")
INSTALLED=$(cat "$STAMP" 2>/dev/null || true)

if [ "$BEHIND" -eq 0 ] && [ "$INSTALLED" = "$(git rev-parse HEAD)" ] && [ "$FORCE" -eq 0 ]; then
  echo "Coucou is up to date ($(git rev-parse --short HEAD))."
  push_branch
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$BEHIND" -gt 0 ]; then
    echo "$BEHIND new commit(s) on $UPSTREAM:"
    git log --oneline --no-merges "HEAD..$UPSTREAM" | head -20
  else
    echo "The checkout is current, but the installed build is not the one it holds."
  fi
  exit 0
fi

# ── 2. The local commits, on top of upstream ──────────────────────────────────
if [ "$BEHIND" -gt 0 ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || die "the working tree has uncommitted changes; commit or stash them first"

  BACKUP="backup/${BRANCH//\//-}-$(date +%Y%m%d-%H%M%S)"
  git branch "$BACKUP"
  if ! git rebase --quiet "$UPSTREAM"; then
    git rebase --abort
    say "Update stopped: the local commits conflict with $UPSTREAM. Nothing was changed; rebase $BRANCH by hand."
    git branch -D "$BACKUP" >/dev/null
    exit 1
  fi
  touch "$PENDING"
  echo "Rebased $BRANCH onto $UPSTREAM ($BEHIND new commits). Previous state: $BACKUP"
fi

# ── 3. Build ──────────────────────────────────────────────────────────────────
command -v cargo >/dev/null || die "cargo not found (https://rustup.rs)"
command -v npm >/dev/null || die "npm not found"

# A failed build leaves the installed Coucou alone, and the next run tries again:
# the checkout no longer matches the commit recorded at the last install.
failed() { say "Update failed while building; Coucou was left as it was. Run $0 in a terminal to see why."; }
trap failed EXIT

cd "$APP_DIR"
npm ci --no-audit --no-fund --silent

# The island's tests run its TypeScript as it is, which needs Node 24.
if [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 24 ]; then
  npm test --silent >/dev/null || die "the tests fail on the rebased branch"
else
  echo "Skipping the tests: they need Node 24, this is $(node --version)."
fi

npx tauri build --no-bundle

# ── 4. Install ────────────────────────────────────────────────────────────────
# Written next to the target and renamed over it: a running Coucou keeps its old
# file open, and the hook Claude Code spawns is never seen half-written.
swap() {
  local from="$1" to="$2"
  mkdir -p "$(dirname "$to")"
  if [ -f "$to" ]; then cp -p "$to" "$to.bak"; fi
  install -m 755 "$from" "$to.new"
  mv "$to.new" "$to"
}
swap "$APP_DIR/target/release/coucou" "$PREFIX/bin/coucou"
swap "$APP_DIR/target/release/coucou-hook" "$PREFIX/lib/Coucou/coucou-hook"
git -C "$REPO_ROOT" rev-parse HEAD > "$STAMP"
trap - EXIT

VERSION=$(node -p "require('./package.json').version")

push_branch

# ── 5. Restart ────────────────────────────────────────────────────────────────
# In its own systemd scope when there is one, so that Coucou outlives the timer's
# service instead of being stopped with it.
# Only the Coucou installed here: another copy (the AppImage, a dev build) is not
# ours to stop.
RUNNING=""
for pid in $(pgrep -x coucou || true); do
  if [ "$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -1)" = "$PREFIX/bin/coucou" ]; then
    RUNNING="$RUNNING $pid"
  fi
done
if [ -n "$RUNNING" ]; then
  # shellcheck disable=SC2086
  kill $RUNNING 2>/dev/null || true
  for _ in $(seq 20); do
    # shellcheck disable=SC2086
    kill -0 $RUNNING 2>/dev/null || break
    sleep 0.25
  done
  if command -v systemd-run >/dev/null && systemctl --user is-system-running >/dev/null 2>&1; then
    systemd-run --user --quiet --collect "$PREFIX/bin/coucou"
  else
    setsid "$PREFIX/bin/coucou" >/dev/null 2>&1 &
  fi
  say "Coucou $VERSION is installed and restarted."
else
  say "Coucou $VERSION is installed."
fi
