#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

blocked() { printf 'Trusted control BLOCKED (%s).\n' "$1" >&2; exit 78; }
[[ "$(id -u)" == 0 && "${SUDO_UID:-}" =~ ^[1-9][0-9]*$ &&
   "${SUDO_GID:-}" =~ ^[0-9]+$ ]] || blocked identity
runner_uid=$SUDO_UID
runner_gid=$SUDO_GID

owned_seal() {
  [[ "$1" =~ ^/var/tmp/careconnect-control[.][A-Za-z0-9]{8}$ &&
     ! -L "$1" && "$(realpath -- "$1")" == "$1" && "$(stat -c %u -- "$1")" == 0 ]]
}

remove_seal() {
  owned_seal "$sealed" && rm -rf --one-file-system -- "$sealed" && [[ ! -e "$sealed" ]]
}

reviewed_copy() {
  local manifest="$checkout/.github/ci/trusted-control.sha256" digest path
  install -d -m 0755 "$sealed/control/.github/ci"
  [[ -f "$manifest" && ! -L "$manifest" ]] || blocked control-manifest
  install -m 0444 "$manifest" "$sealed/control/.github/ci/trusted-control.sha256"
  while read -r digest path; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ &&
      "$path" =~ ^(scripts|[.]github/ci)/[a-zA-Z0-9._-]+$ &&
      -f "$checkout/$path" && ! -L "$checkout/$path" ]] || blocked control-entry
    install -D -m 0444 "$checkout/$path" "$sealed/control/$path"
  done <"$sealed/control/.github/ci/trusted-control.sha256"
  (cd "$sealed/control" && sha256sum --check --strict .github/ci/trusted-control.sha256) ||
    blocked control-digest
}

candidate_process_exists() {
  ps -eo uid=,ruid= | awk -v uid="$1" '$1==uid || $2==uid {found=1} END {exit !found}'
}

reserve_identity() {
  local uid
  for (( uid=61000; uid<=61999; uid++ )); do
    if ! getent passwd "$uid" >/dev/null && ! getent group "$uid" >/dev/null &&
      ! candidate_process_exists "$uid"; then
      printf '%s\n' "$uid"
      return
    fi
  done
  return 1
}

start() {
  local run=$1 node=$3 cli=$4 browser=$5 uid
  checkout=$2
  [[ "$run" =~ ^[0-9]{1,20}-[0-9]{1,6}$ && "$checkout" == "$(realpath -- "$checkout")" &&
     "$(stat -c %u "$checkout")" == "$runner_uid" && -d "$checkout/workspace/node_modules" ]] ||
    blocked checkout
  [[ -f "$node" && -x "$node" && -f "$cli" && -x "$cli" && -d "$browser" ]] || blocked tools
  sealed=$(mktemp -d /var/tmp/careconnect-control.XXXXXXXX)
  chmod 0711 "$sealed"
  trap 'status=$?; remove_seal || exit 1; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  reviewed_copy
  install -d -m 0755 "$sealed/workspace"
  cp -a --reflink=auto "$checkout/workspace/." "$sealed/workspace/"
  chown -hR 0:0 "$sealed/workspace"
  chmod -R go-w "$sealed/workspace"
  chmod 0755 "$sealed/workspace"
  (cd "$sealed/workspace" && sha256sum --check --strict "$sealed/control/.github/ci/messaging-integrity.sha256") ||
    blocked workspace-digest
  # The trusted startup identity needs generated Supabase state and evidence.
  # These paths are outside the candidate PID and mount namespaces.
  chown -hR "$runner_uid:$runner_gid" "$sealed/workspace/supabase" "$sealed/workspace/test-artifacts"
  install -d -m 0755 "$sealed/toolchain/bin" "$sealed/toolchain/lib/node_modules"
  install -m 0555 "$node" "$sealed/toolchain/bin/node"
  install -m 0555 "$cli" "$sealed/toolchain/bin/supabase"
  cp -a --reflink=auto "$(dirname "$(realpath "$node")")/../lib/node_modules/npm" "$sealed/toolchain/lib/node_modules/npm"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "$sealed/toolchain/bin/npm"
  ln -s ../lib/node_modules/npm/bin/npx-cli.js "$sealed/toolchain/bin/npx"
  cp -a --reflink=auto "$browser" "$sealed/browser"
  chown -hR 0:0 "$sealed/toolchain" "$sealed/browser"
  chmod -R go-w "$sealed/toolchain" "$sealed/browser"
  uid=$(reserve_identity) || blocked candidate-identity
  exec /bin/bash "$sealed/control/.github/ci/launch-protected.sh" sealed "$sealed" "$checkout" "$run" "$uid"
}

finish() {
  local status=$? file input output="$checkout/workspace/test-artifacts"
  trap - EXIT
  set +e
  if [[ -d "$output" && ! -L "$output" && "$output" == "$(realpath "$output")" &&
    "$(stat -c %u "$output")" == "$runner_uid" ]]; then
    for file in messaging-source.json messaging-activation.json messaging-filesystem-proof.json \
      service-execution-boundary.json docker-pre-start-proof.json startup.log startup-process.json \
      startup-images-before.json startup-evidence.json startup-observer.json startup-observer-cleanup.json \
      ledger.log pgtap.log concurrency.log real-service-summary.json browser-workflow-summary.json \
      browser-failure-trace.json docker-network-summary.json docker-network-cleanup-summary.json docker-stop-summary.json; do
      input="$sealed/workspace/test-artifacts/$file"
      [[ -e "$input" || -L "$input" ]] || continue
      if [[ -f "$input" && ! -L "$input" && ! -L "$output/$file" &&
          "$(stat -c %s "$input")" -le 1048576 ]]; then
        install -m 0600 -o "$runner_uid" -g "$runner_gid" "$input" "$output/$file" || status=1
      else
        status=1
      fi
    done
  else
    status=1
  fi
  remove_seal || status=1
  exit "$status"
}

case "${1:-}" in
  start)
    shift
    [[ $# == 5 ]] || blocked arguments
    start "$@"
    ;;
  sealed)
    shift
    [[ $# == 4 ]] || blocked arguments
    sealed=$1 checkout=$2 run=$3 candidate_uid=$4
    owned_seal "$sealed" && [[ "$(realpath "${BASH_SOURCE[0]}")" == "$sealed/control/.github/ci/launch-protected.sh" &&
       "$run" =~ ^[0-9]{1,20}-[0-9]{1,6}$ && "$candidate_uid" =~ ^61[0-9]{3}$ &&
       "$candidate_uid" != "$runner_uid" ]] || blocked sealed-entry
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    /bin/bash "$sealed/control/.github/ci/candidate-sandbox.sh" probe \
      "$sealed" "$candidate_uid" "$checkout/.github/ci/trusted-control.sha256" || blocked filesystem-probe
    if candidate_process_exists "$candidate_uid"; then blocked descendant-cleanup; fi
    printf '{"status":"PASS","candidate_uid":%s,"filesystem_probe":true}\n' "$candidate_uid" \
      >"$sealed/workspace/test-artifacts/messaging-filesystem-proof.json"
    /bin/bash "$sealed/control/scripts/ci-isolated-docker.sh" \
      "$run" "$runner_uid" "$runner_gid" "$sealed/workspace" \
      "$sealed/toolchain/bin/node" "$sealed/toolchain/bin/supabase" "$sealed/browser" "$sealed" "$candidate_uid"
    ;;
  *) blocked arguments ;;
esac
