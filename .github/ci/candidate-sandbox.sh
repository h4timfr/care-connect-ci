#!/usr/bin/env bash
set -euo pipefail
umask 077

blocked() { printf 'Candidate filesystem isolation BLOCKED (%s).\n' "$1" >&2; exit 78; }

new_jail() {
  local jail=$1 candidate=$2
  install -d -m 0755 "$jail" "$jail"/{dev,etc,proc,run,var,var/tmp,home}
  install -d -m 0700 -o "$candidate" -g "$candidate" "$jail"/{work,artifacts,tmp,dev/shm,home/candidate}
  for path in bin sbin lib lib64; do
    ln -s "usr/$path" "$jail/$path"
  done
  printf 'root:x:0:0:root:/root:/bin/false\ncandidate:x:%s:%s:Candidate:/home/candidate:/bin/false\n' \
    "$candidate" "$candidate" >"$jail/etc/passwd"
  printf 'root:x:0:\ncandidate:x:%s:\n' "$candidate" >"$jail/etc/group"
  printf '127.0.0.1 localhost\n::1 localhost\n' >"$jail/etc/hosts"
  printf 'passwd: files\ngroup: files\nhosts: files\n' >"$jail/etc/nsswitch.conf"
  chmod 0644 "$jail"/etc/*
}

read_only_bind() {
  local source=$1 target=$2
  if [[ -d "$source" ]]; then
    install -d -m 0755 "$target"
  else
    touch "$target"
  fi
  mount --bind "$source" "$target"
  mount -o remount,bind,ro,nosuid,nodev "$target"
}

snapshot_service_inputs() {
  local source=$1 output=$2
  install -d -m 0755 "$output" "$output/.temp"
  cp -a --reflink=auto "$source/migrations" "$source/tests" "$output/"
  install -m 0444 "$source/config.toml" "$output/config.toml"
  if [[ -f "$source/.temp/project-ref" && ! -L "$source/.temp/project-ref" ]]; then
    install -m 0444 "$source/.temp/project-ref" "$output/.temp/project-ref"
  fi
  chown -hR 0:0 "$output"
  chmod -R go+rX,go-w "$output"
}

enter() {
  local sealed=$1 jail=$2 root=$3 gid=$4 candidate=$5 run=$6 mode=$7 hidden=$8
  [[ "$(id -u)" == 0 && "$(stat -c %u:%a -- "$jail")" == 0:755 ]] || blocked jail-owner
  local directory
  install -d -m 0755 "$jail/usr"
  for directory in bin lib lib64 share; do
    if [[ -d "/usr/$directory" ]]; then
      read_only_bind "/usr/$directory" "$jail/usr/$directory"
    fi
  done
  if [[ -d /etc/fonts ]]; then read_only_bind /etc/fonts "$jail/etc/fonts"; fi
  read_only_bind "$sealed/control" "$jail/control"
  read_only_bind "$sealed/$mode-supabase" "$jail/work/supabase"
  mount -t proc -o nosuid,nodev,noexec proc "$jail/proc"
  for device in null zero full random urandom; do
    touch "$jail/dev/$device"
    mount --bind "/dev/$device" "$jail/dev/$device"
  done
  local -a command=(/bin/bash /control/.github/ci/sandbox-probe.sh "$hidden")
  local engine= config=
  if [[ "$mode" == run ]]; then
    read_only_bind "$sealed/toolchain" "$jail/toolchain"
    read_only_bind "$sealed/browser" "$jail/browsers"
    read_only_bind "$sealed/candidate-scripts" "$jail/work/scripts"
    install -d -m 0711 "$jail$root"
    read_only_bind "$root/verified.json" "$jail$root/verified.json"
    read_only_bind "$root/docker-cli" "$jail$root/docker-cli"
    read_only_bind "$root/engine.sock" "$jail$root/engine.sock"
    install -d -m 0700 "$jail/work/test-artifacts"
    mount --bind "$jail/artifacts" "$jail/work/test-artifacts"
    engine="unix://$root/engine.sock"
    config="$root/docker-cli"
    command=(/bin/bash -ec 'cd /work; exec timeout --signal=TERM --kill-after=15s 35m node scripts/real-service-integration.mjs run')
    printf '{"status":"filesystem_prepared","candidate_uid":%s,"runner_uid_distinct":true}\n' "$candidate" \
      >"$sealed/workspace/test-artifacts/messaging-activation.json"
  fi
  # No caller directory or credentials cross this exec. The PID namespace
  # kills remaining descendants when its initial process exits.
  exec env -i PATH=/toolchain/bin:/usr/bin:/bin HOME=/home/candidate TMPDIR=/tmp RUNNER_TEMP=/tmp \
    PLAYWRIGHT_BROWSERS_PATH=/browsers DO_NOT_TRACK=1 CI=true GITHUB_ACTIONS=true \
    "GITHUB_RUN_ID=${run%-*}" "GITHUB_RUN_ATTEMPT=${run##*-}" "CARECONNECT_ISOLATION_ROOT=$root" \
    "DOCKER_HOST=$engine" "DOCKER_CONFIG=$config" "CARECONNECT_DOCKER_NETWORK=careconnect-ci-$run" \
    "CARECONNECT_DOCKER_RUN_LABEL=$run" \
    /usr/bin/setpriv --no-new-privs /usr/sbin/chroot \
    --userspec="+$candidate:+$candidate" --groups="$gid" "$jail" "${command[@]}"
}

jail_exec() {
  local sealed=$1
  shift
  # Do not inherit a directory descriptor or the supervisor's working directory.
  cd /
  unshare --mount --propagation private --pid --fork --kill-child=SIGKILL \
    /bin/bash "$sealed/control/.github/ci/candidate-sandbox.sh" enter "$sealed" "$@"
}

run_candidate() {
  local sealed=$1 root=$2 runner_uid=$3 gid=$4 candidate=$5 run=$6
  local jail="$sealed/jail" source="$sealed/candidate-source" work="$sealed/workspace" status=0 file
  [[ "$(id -u)" == 0 && "$root" =~ ^/var/tmp/careconnect-ci[.][A-Za-z0-9]{8}$ &&
     -f "$root/verified.json" && -S "$root/engine.sock" ]] || blocked receipt
  new_jail "$jail" "$candidate"
  install -d -m 0700 "$source"
  /bin/bash "$sealed/control/.github/ci/messaging-dispatch.sh" extract \
    "$work/scripts/.messaging-dispatch/candidate.bundle" "$source" "$sealed/candidate.git"

  # Preserve a sealed source snapshot. Only the build copy, its build tools,
  # the browser profile, temporary state and candidate artifacts are writable.
  cp -a --reflink=auto "$source/." "$jail/work/"
  cp -a --reflink=auto "$work/node_modules" "$jail/work/node_modules"
  mv "$jail/work/scripts" "$sealed/candidate-scripts"
  install -m 0444 "$work/scripts/service-execution-boundary.mjs" \
    "$work/scripts/staging-reconciliation-rehearsal.mjs" "$work/scripts/migration-integrity.json" \
    "$work/scripts/local-sql-test-target.mjs" "$work/scripts/run-sql-ci-step.mjs" \
    "$work/scripts/startup-evidence.mjs" "$sealed/candidate-scripts/"
  chmod -R go-w "$sealed/candidate-scripts"
  chown -hR "$candidate:$candidate" "$jail/work"
  snapshot_service_inputs "$work/supabase" "$sealed/run-supabase"
  jail_exec "$sealed" "$jail" "$root" "$gid" "$candidate" "$run" run '' \
    </dev/null >"$sealed/candidate.raw" 2>&1 || status=$?
  # The PID namespace has terminated. Export only bounded regular artifacts
  # from the dedicated candidate output directory.
  for file in real-service-summary.json browser-workflow-summary.json browser-failure-trace.json; do
    local input="$jail/artifacts/$file"
    if [[ -e "$input" || -L "$input" ]]; then
      [[ -f "$input" && ! -L "$input" && "$(stat -c %h "$input")" == 1 &&
         "$(stat -c %s "$input")" -le 1048576 ]] || blocked candidate-artifact
      install -m 0600 -o "$runner_uid" -g "$gid" "$input" "$work/test-artifacts/$file"
    fi
  done
  printf 'Isolated candidate exit status %s.\n' "$status"
  return "$status"
}

case "${1:-}" in
  run) shift; [[ $# == 6 ]] || blocked arguments; run_candidate "$@" ;;
  enter) shift; [[ $# == 8 ]] || blocked arguments; enter "$@" ;;
  probe)
    shift
    [[ $# == 3 && "$(id -u)" == 0 ]] || blocked arguments
    sealed=$1 candidate=$2 hidden=$3
    new_jail "$sealed/probe-jail" "$candidate"
    install -d -m 0700 "$sealed/probe-inputs"/{migrations,tests,.temp}
    printf 'project_id = "synthetic-probe"\n' >"$sealed/probe-inputs/config.toml"
    printf 'synthetic-probe\n' >"$sealed/probe-inputs/.temp/project-ref"
    snapshot_service_inputs "$sealed/probe-inputs" "$sealed/probe-supabase"
    jail_exec "$sealed" "$sealed/probe-jail" '' "$candidate" "$candidate" 0-1 probe "$hidden"
    ;;
  *) blocked phase ;;
esac
