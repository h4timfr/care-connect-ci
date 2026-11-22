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

verify_control() {
  local manifest="$sealed/control/.github/ci/trusted-control.sha256"
  owned_seal "$sealed" && [[ "$(stat -c %u:%a -- "$sealed")" == 0:711 &&
    "$(realpath -- "${BASH_SOURCE[0]}")" == "$sealed/control/.github/ci/launch-protected.sh" &&
    "$(stat -c %u:%a -- "$sealed/control")" == 0:555 &&
    -f "$manifest" && ! -L "$manifest" && "$(stat -c %u:%a -- "$manifest")" == 0:444 &&
    "$manifest_digest" =~ ^[a-f0-9]{64}$ ]] || blocked sealed-entry
  printf '%s  %s\n' "$manifest_digest" "$manifest" | sha256sum --check --strict --quiet - ||
    blocked sealed-manifest
  (cd "$sealed/control" && sha256sum --check --strict --quiet .github/ci/trusted-control.sha256) ||
    blocked sealed-control-digest
}

verify_workspace() {
  local work="$sealed/workspace" file digest
  for file in scripts supabase test-artifacts; do
    [[ -d "$work/$file" && "$(realpath -- "$work/$file")" == "$work/$file" ]] ||
      blocked workspace-alias
  done
  while read -r digest file; do
    [[ -f "$work/$file" && "$(realpath -- "$work/$file")" == "$work/$file" &&
       "$(stat -c %u:%h -- "$work/$file")" == 0:1 ]] || blocked workspace-alias
  done <"$sealed/control/.github/ci/messaging-integrity.sha256"
  (cd "$work" && sha256sum --check --strict "$sealed/control/.github/ci/messaging-integrity.sha256") ||
    blocked workspace-digest
  # Trusted phase code is installed from the sealed Git tree. The staged data
  # must agree with it even though its copies are never used for execution.
  for file in ci-isolated-docker.sh ci-docker-admission.mjs ci-real-service-phase.sh \
      service-execution-boundary.mjs verify-disposable-docker-bindings.mjs; do
    install -m 0444 "$sealed/control/scripts/$file" "$work/scripts/$file"
  done
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
  sealed=$1 run=$2 checkout=$3 manifest_digest=$7
  local node=$4 cli=$5 browser=$6 candidate_uid
  verify_control
  [[ "$run" =~ ^[0-9]{1,20}-[0-9]{1,6}$ && "$checkout" == "$(realpath -- "$checkout")" &&
     "$(stat -c %u "$checkout")" == "$runner_uid" && ! -L "$checkout/workspace" &&
     -d "$checkout/workspace/node_modules" ]] ||
    blocked checkout
  [[ -f "$node" && -x "$node" && -f "$cli" && -x "$cli" && -d "$browser" ]] || blocked tools
  trap 'status=$?; remove_seal || exit 1; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  install -d -m 0755 "$sealed/workspace"
  cp -a --reflink=auto "$checkout/workspace/." "$sealed/workspace/"
  chown -hR 0:0 "$sealed/workspace"
  chmod -R go-w "$sealed/workspace"
  chmod 0755 "$sealed/workspace"
  verify_workspace
  # The trusted startup identity needs generated Supabase state and evidence.
  # These paths are outside the candidate PID and mount namespaces.
  chown -hR "$runner_uid:$runner_gid" "$sealed/workspace/supabase" "$sealed/workspace/test-artifacts"
  install -d -m 0755 "$sealed/toolchain/bin" "$sealed/toolchain/lib/node_modules"
  install -m 0555 "$node" "$sealed/toolchain/bin/node"
  install -m 0555 "$cli" "$sealed/toolchain/bin/supabase"
  # The supervisor invokes these two executables as root.
  (
    cd "$sealed/toolchain/bin"
    sha256sum --check --strict --quiet <<'TOOLCHAIN'
af8d5d1e234beb26b3095e6bebf80edc781f79c9435553a383037eccec2716f8  node
40efbaffd04e4cbf501b4f29a52c88ca23f81c636ef211e3b255c4e7b81eeb01  supabase
TOOLCHAIN
  ) || blocked toolchain-digest
  cp -a --reflink=auto "$(dirname "$(realpath "$node")")/../lib/node_modules/npm" "$sealed/toolchain/lib/node_modules/npm"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "$sealed/toolchain/bin/npm"
  ln -s ../lib/node_modules/npm/bin/npx-cli.js "$sealed/toolchain/bin/npx"
  cp -a --reflink=auto "$browser" "$sealed/browser"
  chown -hR 0:0 "$sealed/toolchain" "$sealed/browser"
  chmod -R go-w "$sealed/toolchain" "$sealed/browser"
  candidate_uid=$(reserve_identity) || blocked candidate-identity
  [[ "$candidate_uid" != "$runner_uid" ]] || blocked candidate-identity
  verify_control
  trap finish EXIT
  /bin/bash "$sealed/control/.github/ci/candidate-sandbox.sh" probe \
    "$sealed" "$candidate_uid" "$checkout/.github/ci/trusted-control.sha256" || blocked filesystem-probe
  if candidate_process_exists "$candidate_uid"; then blocked descendant-cleanup; fi
  printf '{"status":"PASS","candidate_uid":%s,"filesystem_probe":true}\n' "$candidate_uid" \
    >"$sealed/workspace/test-artifacts/messaging-filesystem-proof.json"
  /bin/bash "$sealed/control/scripts/ci-isolated-docker.sh" \
    "$run" "$runner_uid" "$runner_gid" "$sealed/workspace" \
    "$sealed/toolchain/bin/node" "$sealed/toolchain/bin/supabase" "$sealed/browser" "$sealed" "$candidate_uid"
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
      browser-failure-trace.json docker-network-summary.json docker-network-cleanup-summary.json docker-stop-summary.json \
      docker-teardown-summary.json; do
      input="$sealed/workspace/test-artifacts/$file"
      [[ -e "$input" || -L "$input" ]] || continue
      if [[ -f "$input" && ! -L "$input" && ! -L "$output/$file" &&
          "$(stat -c %s "$input")" -le 1048576 ]]; then
        # Resolve and open the mutable destination with only runner permissions.
        setpriv --reuid="$runner_uid" --regid="$runner_gid" --clear-groups --no-new-privs \
          /bin/bash -ec 'umask 077; cat >"$1"' careconnect "$output/$file" <"$input" || status=1
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
  start) [[ $# == 8 ]] || blocked arguments; shift; start "$@" ;;
  verify) [[ $# == 3 ]] || blocked arguments; sealed=$2 manifest_digest=$3; verify_control ;;
  *) blocked arguments ;;
esac
