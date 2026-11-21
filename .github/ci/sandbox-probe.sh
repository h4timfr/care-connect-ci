#!/usr/bin/env bash
set -euo pipefail
hidden=$1
candidate_uid=$(id -u)
[[ "$candidate_uid" =~ ^61[0-9]{3}$ ]]
pid_one_uid=
while read -r field value rest; do
  if [[ "$field" == Uid: ]]; then pid_one_uid=$value; break; fi
done </proc/1/status
[[ "$pid_one_uid" == "$candidate_uid" ]]
for path in \
  scripts/ci-isolated-docker.sh scripts/ci-docker-admission.mjs \
  scripts/ci-real-service-phase.sh scripts/service-execution-boundary.mjs \
  scripts/verify-disposable-docker-bindings.mjs .github/ci/messaging-dispatch.sh \
  .github/ci/launch-protected.sh .github/ci/candidate-sandbox.sh .github/ci/sandbox-probe.sh \
  .github/ci/messaging-integrity.sha256 .github/ci/trusted-control.sha256; do
  [[ -r "/control/$path" ]]
  if (printf 'probe\n' >>"/control/$path") 2>/dev/null; then exit 1; fi
  printf 'PASS immutable %s\n' "$path"
done
if (printf 'probe\n' >/unlisted-write) 2>/dev/null; then exit 1; fi
[[ ! -e /var/run/docker.sock && ! -e /run/containerd/containerd.sock && ! -e "$hidden" ]]
printf 'PASS host sockets, unrelated runner files, and writes outside designated paths denied\n'
[[ "$(< /work/supabase/config.toml)" == 'project_id = "synthetic-probe"' &&
   "$(< /work/supabase/.temp/project-ref)" == synthetic-probe ]]
if (printf 'probe\n' >>/work/supabase/config.toml) 2>/dev/null; then exit 1; fi
printf 'PASS disposable service configuration readable and immutable\n'
for dir in /work /artifacts /tmp /home/candidate /dev/shm; do
  printf 'probe\n' >"$dir/careconnect-probe"
  rm -- "$dir/careconnect-probe"
done
sleep 120 &
[[ -r "/proc/$!/status" ]]
printf 'PASS designated writes and a descendant left for namespace cleanup\n'
