#!/bin/bash
# Hosted Chromium chain for the Yab fork: prepare, build slices, export/import.
#
# Ports the ungoogled-chromium-android chained-build technique to this repo's
# pinned baseline (scripts/chromium-hosted/baseline.json): stock ubuntu-latest
# runners are too small for one Chromium build, so jobs hand a packed build
# tree to each other until ninja finishes. The tree reproduces the Docker
# sandbox baseline exactly: same revisions, same GN args, same target.
#
# Subcommands: prepare, import, slice, export, finish. See
# .github/workflows/chromium-hosted-build.yml for the job graph.
set -euo pipefail

ROOT=/mnt/yab-chromium
CONFIG="$(dirname "$0")/baseline.json"
OUT_REL=out/YabDesktopArm64
# Both markers live inside the packed tree (the stamp at tree root is added to
# the tar explicitly; the done marker sits in the out dir), so they survive
# the handoff between jobs.
STAMP_NAME=.chain-stamp
DONE_MARKER="$ROOT/checkout/src/$OUT_REL/.chain-done"
# One slice's build budget. 15000s is 4h10m; the 350 min job timeout then
# leaves about 1h40m for import, export and upload of the packed tree.
BUILD_SECONDS=15000

die() { echo "chain: $*" >&2; exit 1; }

config_value() { python3 -c "import json,sys;print(json.load(open('$CONFIG'))[sys.argv[1]])" "$1"; }

stamp_content() {
  sha256sum "$CONFIG" | cut -d' ' -f1
}

write_stamp() {
  stamp_content > "$ROOT/$STAMP_NAME"
}

check_stamp() {
  [ -f "$ROOT/$STAMP_NAME" ] || die "no chain stamp; tree did not come from prepare"
  [ "$(cat "$ROOT/$STAMP_NAME")" = "$(stamp_content)" ] \
    || die "chain stamp mismatch: tree was prepared from a different baseline"
}

# Mirror the sandbox bootstrap's cache env: everything a tool would write to
# $HOME lands inside ROOT instead, so nothing leaks between jobs.
export_cache_env() {
  mkdir -p "$ROOT/cache/cipd" "$ROOT/cache/vpython" "$ROOT/tmp"
  export CIPD_CACHE_DIR="$ROOT/cache/cipd" VPYTHON_VIRTUALENV_ROOT="$ROOT/cache/vpython"
  export XDG_CACHE_HOME="$ROOT/cache" TMPDIR="$ROOT/tmp"
}

# The link of libchrome.so peaks above runner RAM; the sandbox used swap too.
ensure_swap() {
  swapon --show | grep -q chain.swap && return 0
  sudo fallocate -l 6G /mnt/chain.swap
  sudo chmod 600 /mnt/chain.swap
  sudo mkswap /mnt/chain.swap
  sudo swapon /mnt/chain.swap || true
}

# The verified build compiled against the packages install-build-deps.py
# installs. Runner images are ephemeral, so every job that runs ninja recreates
# them; same flags as the sandbox run.
ensure_system_deps() {
  sudo apt-get update -qq
  sudo apt-get install -y -qq lsb-release > /dev/null
  (cd "$ROOT/checkout/src" && sudo python3 build/install-build-deps.py --android \
    --no-arm --no-chromeos-fonts --no-nacl --no-prompt) > "$ROOT/deps.log" 2>&1 \
    || die "install-build-deps failed"
}

# Free runner disk exactly like ungoogled-chromium-android's hosted-prepare.sh:
# drop preinstalled toolchains we never use, then add swap for the libchrome.so
# link (16 GB RAM peak; our sandbox peaked at 16.8 GB).
prepare_disk() {
  sudo rm -rf /usr/local/lib/android /usr/local/.ghcup /usr/lib/jvm \
    /usr/lib/google-cloud-sdk /usr/lib/dotnet /usr/share/swift /opt/hostedtoolcache
  sudo apt-get remove -y --purge azure-cli google-chrome-stable firefox powershell \
    mono-complete 2>/dev/null || true
  sudo fallocate -l 6G /mnt/chain.swap
  sudo chmod 600 /mnt/chain.swap
  sudo mkswap /mnt/chain.swap
  sudo swapon /mnt/chain.swap || true
  sudo apt-get update -qq
  sudo apt-get install -y -qq zstd lsb-release > /dev/null
  df -h / /mnt | tail -2
}

prepare() {
  prepare_disk
  export_cache_env
  mkdir -p "$ROOT"/{checkout,tools}
  cd "$ROOT"

  local chromium_revision depot_revision chromium_url depot_url
  chromium_url="$(config_value chromiumRepository)"
  chromium_revision="$(config_value chromiumRevision)"
  depot_url="$(config_value depotToolsRepository)"
  depot_revision="$(config_value depotToolsRevision)"

  for pair in "tools/depot_tools $depot_url $depot_revision" \
              "checkout/src $chromium_url $chromium_revision"; do
    set -- $pair
    local dir="$1" url="$2" rev="$3"
    mkdir -p "$dir"
    if [ ! -d "$dir/.git" ]; then
      git -C "$dir" init -q
      git -C "$dir" remote add origin "$url"
      git -C "$dir" fetch --depth=1 -q origin "$rev"
      git -C "$dir" checkout --detach -q FETCH_HEAD
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$rev" ] || die "$dir is not at the pinned revision"
  done

  cat > checkout/.gclient <<EOF
solutions = [{'name': 'src', 'url': '$chromium_url', 'deps_file': 'DEPS', 'managed': False, 'custom_deps': {}, 'custom_vars': {}}]
target_os = ['android']
EOF

  export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
  export PATH="$PATH:$ROOT/tools/depot_tools"
  tools/depot_tools/ensure_bootstrap > prep-bootstrap.log 2>&1 || die "depot_tools bootstrap failed"
  cd checkout
  tools/depot_tools/gclient sync --nohooks --noprehooks --no-history --jobs 8 \
    --revision "src@$chromium_revision" || die "gclient sync failed"
  sudo python3 src/build/install-build-deps.py --android --no-arm \
    --no-chromeos-fonts --no-nacl --no-prompt > ../prep-deps.log 2>&1 \
    || die "install-build-deps failed"
  tools/depot_tools/gclient runhooks > ../prep-hooks.log 2>&1 || die "runhooks failed"

  mkdir -p "src/$OUT_REL"
  python3 - <<PYEOF
import json
args = json.load(open("$CONFIG"))["gnArgs"]
open("src/$OUT_REL/args.gn", "w").write(
    "\n".join(f"{k} = {json.dumps(v)}" for k, v in args.items()) + "\n")
PYEOF
  (cd src && ../tools/depot_tools/gn gen "$OUT_REL" --fail-on-unused-args) \
    || die "gn gen failed"

  # The chain never runs gclient again; drop dep metadata to save disk and
  # keep the packed tree small. LASTCHANGE and friends were written by hooks.
  # depot_tools keeps its .git (tiny, and its scripts may look for it).
  find "$ROOT/checkout" -name .git -type d -prune -exec rm -rf {} +
  write_stamp
  echo "prepare: tree ready at $ROOT"
}

export_tree() {
  cd "$ROOT"
  rm -f chain-part.* chain-manifest.txt
  local stamp
  stamp="$(cat $STAMP_NAME)"
  if [ -f "$DONE_MARKER" ]; then
    # Build is complete: hand off only the stamped APK directory, not the
    # ~100 GB tree. Later parts import it, no-op, and re-export cheaply.
    tar --format=posix -cf - "$STAMP_NAME" "checkout/src/$OUT_REL" \
      | zstd -T0 -1 \
      | split -b 9500M - chain-part.
  else
    tar --format=posix -cf - "$STAMP_NAME" --exclude="*/.git" checkout tools \
      | zstd -T0 -1 \
      | split -b 9500M - chain-part.
  fi || die "tree pack failed"
  : > chain-manifest.txt
  local count=0
  for part in chain-part.*; do
    sha256sum "$part" >> chain-manifest.txt
    count=$((count + 1))
  done
  echo "$stamp $count" >> chain-manifest.txt
  echo "export: $count part(s), $(du -ch chain-part.* | tail -1 | cut -f1) packed"
}

import_tree() {
  local src_dir="${1:-chain}"
  cd "$ROOT"
  local stamp count
  read -r stamp count < <(tail -1 "$src_dir/chain-manifest.txt")
  local expected
  expected="$(stamp_content)"
  [ "$stamp" = "$expected" ] || die "import: stamp mismatch ($stamp != $expected)"
  ls "$src_dir"/chain-part.* > /dev/null 2>&1 || die "import: no parts"
  local actual
  actual="$(ls "$src_dir"/chain-part.* | wc -l)"
  [ "$actual" = "$count" ] || die "import: expected $count parts, found $actual"
  head -n -1 "$src_dir/chain-manifest.txt" | (cd "$src_dir" && sha256sum -c --quiet -) \
    || die "import: part checksum mismatch"
  cat "$src_dir"/chain-part.* | zstd -dc -T0 | tar -x -C "$ROOT" \
    || die "import: unpack failed"
  # The packed parts are dead weight now; reclaim the disk before ninja runs.
  rm -f "$src_dir"/chain-part.* "$src_dir/chain-manifest.txt"
  check_stamp
  echo "import: tree restored at $ROOT"
}

# One build slice: run ninja until the job's time budget ends, then hand off.
# SIGINT lets siso/ninja stop cleanly (same signal our Docker stop used); the
# exit 124 from timeout means "not finished yet", which the workflow treats as
# success so the next part job continues.
slice() {
  ensure_swap
  ensure_system_deps
  export_cache_env
  cd "$ROOT/checkout/src"
  export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
  export PATH="$PATH:$ROOT/tools/depot_tools"
  if [ -f "$DONE_MARKER" ]; then
    echo "slice: build already complete, skipping"
    return 0
  fi
  local target
  target="$(config_value target)"
  set +e
  timeout -k 5m -s INT "${BUILD_SECONDS}s" \
    "$ROOT/tools/depot_tools/autoninja" -C "$OUT_REL" "$target"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    touch "$DONE_MARKER"
    echo "slice: BUILD COMPLETE"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "slice: budget reached, tree handed to the next part"
  else
    die "slice: ninja failed with exit $rc"
  fi
}

finish() {
  ensure_swap
  ensure_system_deps
  export_cache_env
  cd "$ROOT/checkout/src"
  export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
  export PATH="$PATH:$ROOT/tools/depot_tools"
  local target
  target="$(config_value target)"
  if [ -f "$DONE_MARKER" ]; then
    echo "finish: build already complete, packaging"
  else
    # Ninth builder: complete whatever the eight timed-out parts left. A
    # failure here is loud; never a silently truncated build.
    "$ROOT/tools/depot_tools/autoninja" -C "$OUT_REL" "$target" \
      || die "finish: final ninja failed"
  fi
  local apks_dir="$ROOT/checkout/src/$OUT_REL/apks"
  ls "$apks_dir"/*.apk > /dev/null 2>&1 || die "finish: no APK under $apks_dir"
  mkdir -p "$ROOT/apk-out"
  for apk in "$apks_dir"/*.apk; do
    cp "$apk" "$ROOT/apk-out/"
    sha256sum "$apk" | tee -a "$ROOT/apk-out/APK-SHA256SUMS"
    ls -la "$apk"
  done
  echo "finish: APK ready in $ROOT/apk-out"
}

case "${1:-}" in
  prepare) prepare ;;
  export) export_tree ;;
  import) import_tree "${2:-chain}" ;;
  slice) slice ;;
  finish) finish ;;
  *) die "usage: chain.sh {prepare|export|import [dir]|slice|finish}" ;;
esac