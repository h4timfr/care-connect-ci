#!/usr/bin/env bash
set -euo pipefail

readonly app_repository=https://github.com/h4timfr/care-connect-chennai.git
readonly supervisor=366ef27d728b623233cc414adeb4d558085fd8a4
readonly bootstrap=1cfc9ea4d696de3d8c1a633e8e537f9bdd219aa7
readonly messaging=112c254accdc3d34250f86561787d560f18bc9db
readonly tests=df34e2004ada66e4d3f2283d3f8351eff43a3ab8
readonly old_driver=b88dc37e33d744887ca3f4eb5daa0eeb76ed242a
readonly candidate=2269446689318a13639ca45471224ace96503d23
readonly vault=scripts/.messaging-dispatch
readonly -a vendored=(
  scripts/ci-isolated-docker.sh scripts/ci-docker-admission.mjs
  scripts/ci-real-service-phase.sh scripts/service-execution-boundary.mjs
  scripts/verify-disposable-docker-bindings.mjs
)
readonly -a support=(
  package.json package-lock.json scripts/real-service-integration.mjs
  scripts/startup-evidence.mjs scripts/startup-observer.mjs
  scripts/local-sql-test-target.mjs scripts/run-sql-ci-step.mjs
  scripts/test-booking-concurrency.mjs scripts/ci-docker-admission.test.mjs
  scripts/verify-disposable-docker-bindings.test.mjs
)
readonly -a fixture_paths=(
  tests/real-service/seed-owned-fixtures.sql
  tests/real-service/assert-realtime-readiness.sql
  tests/real-service/cleanup-owned-fixtures.sql
)
readonly -a app_paths=(
  src public package.json vite.config.ts nitro.config.ts tsconfig.json
  playwright.real-service.config.ts tests/real-service/workflows.spec.ts
  scripts/real-service-integration.mjs scripts/real-service-integration.test.mjs
  "${fixture_paths[@]}"
)

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

blocked() {
  printf 'Messaging dispatcher BLOCKED (%s).\n' "$1" >&2
  exit 78
}

fetch_source() {
  local store="${RUNNER_TEMP:?}/careconnect-source.git"
  umask 077
  [[ ! -e "$store" && ! -L "$store" ]] || blocked source-store
  git init --bare --quiet --template= "$store"
  export GIT_CONFIG_COUNT=0
  if [[ -n "${CARECONNECT_APP_CONTENTS_READ:-}" ]]; then
    # Git reads the optional cross-repo credential from process environment only.
    GIT_CONFIG_VALUE_0=$(printf 'x-access-token:%s' "$CARECONNECT_APP_CONTENTS_READ" | base64 -w0)
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $GIT_CONFIG_VALUE_0"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.$app_repository.extraHeader" GIT_CONFIG_VALUE_0
  fi
  unset CARECONNECT_APP_CONTENTS_READ
  timeout --signal=TERM --kill-after=5s 3m \
    git -C "$store" -c protocol.allow=never -c protocol.https.allow=always \
    -c http.followRedirects=false fetch --quiet --no-tags --no-recurse-submodules \
    "$app_repository" "$candidate:refs/heads/reviewed-candidate" >/dev/null 2>&1 ||
    blocked source-fetch
  [[ "$(git -C "$store" rev-parse FETCH_HEAD)" == "$candidate" ]] || blocked fetched-object
}

verify_candidate() {
  local repo=$1 delta path
  [[ "$(git -C "$repo" rev-parse --verify "$candidate^{commit}")" == "$candidate" ]] || blocked candidate
  [[ "$(git -C "$repo" rev-list --parents -n 1 "$candidate")" == "$candidate $old_driver" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$old_driver")" == "$old_driver $tests" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$tests")" == "$tests $messaging" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$messaging")" == "$messaging $bootstrap" ]] || blocked parent-chain
  git -C "$repo" merge-base --is-ancestor "$supervisor" "$messaging" || blocked approved-ancestry
  [[ "$(git -C "$repo" rev-list --count "$supervisor..$messaging")" == 18 &&
     "$(git -C "$repo" rev-list --count "$supervisor..$candidate")" == 21 &&
     "$(git -C "$repo" rev-list --count --merges "$supervisor..$candidate")" == 0 ]] || blocked unexpected-history

  delta=$(git -C "$repo" diff --no-renames --name-status "$old_driver" "$candidate")
  [[ "$delta" == $'D\t.github/workflows/messaging-disposable-verification.yml' ]] || blocked driver-removal
  git -C "$repo" diff --quiet "$tests" "$candidate" -- "${app_paths[@]}" || blocked application-or-test-tree
  git -C "$repo" diff --quiet "$supervisor" "$candidate" -- "${fixture_paths[@]}" ||
    blocked fixture-tree
  git -C "$repo" diff --quiet "$bootstrap" "$candidate" -- \
    supabase scripts/migration-integrity.json scripts/staging-reconciliation-rehearsal.mjs \
    package-lock.json || blocked sql-or-lockfile-tree
  for path in "${app_paths[@]}"; do
    git -C "$repo" cat-file -e "$candidate:$path" || blocked application-path
  done
  git -C "$repo" ls-tree -r "$candidate" -- "${app_paths[@]}" supabase |
    awk '$1 != "100644" && $1 != "100755" { invalid=1 } END { exit invalid }' || blocked file-mode
}

prepare() {
  local control manifest file store="${RUNNER_TEMP:?}/careconnect-source.git"
  control=$(pwd -P)
  manifest="$control/.github/ci/messaging-integrity.sha256"
  [[ "$(git rev-parse HEAD)" == "$GITHUB_WORKFLOW_SHA" ]] || blocked control-checkout
  [[ "$(git -C "$store" rev-parse refs/heads/reviewed-candidate)" == "$candidate" ]] || blocked candidate-store
  verify_candidate "$store"

  umask 022
  mkdir workspace
  git -C "$store" archive "$supervisor" -- "${support[@]}" | tar -xf - -C workspace
  git -C "$store" archive "$bootstrap" -- supabase \
    scripts/migration-integrity.json scripts/staging-reconciliation-rehearsal.mjs |
    tar -xf - -C workspace
  for file in "${vendored[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || blocked supervisor-file
    git -C "$store" cat-file blob "$supervisor:$file" | cmp -s - "$file" ||
      blocked supervisor-baseline
    install -m 0644 "$file" "workspace/$file"
  done
  (
    cd workspace
    sha256sum --check --strict "$manifest" &&
    awk -F '[()]' 'tolower($0) ~ /^[[:space:]]*select[[:space:]]+extensions[.]plan[(][0-9]+[)][[:space:]]*;/ {
      count++; total += $2
    } END { exit !(count == 25 && total == 609) }' supabase/tests/*.test.sql
  ) || blocked bootstrap-integrity

  umask 077
  mkdir "workspace/$vault" workspace/test-artifacts
  git -C "$store" bundle create "$control/workspace/$vault/candidate.bundle" refs/heads/reviewed-candidate
  [[ "$(git bundle list-heads "workspace/$vault/candidate.bundle")" == "$candidate refs/heads/reviewed-candidate" ]] ||
    blocked bundle-head
  mv workspace/scripts/ci-real-service-phase.sh "workspace/$vault/phase.sh"
  install -m 0600 .github/ci/messaging-dispatch.sh "workspace/$vault/dispatch.sh"
  cat > workspace/scripts/ci-real-service-phase.sh <<'BASH'
#!/bin/bash
set -euo pipefail
vault=scripts/.messaging-dispatch
if [[ "$1" == test ]]; then
  /bin/bash "$vault/dispatch.sh" activate
fi
exec /bin/bash "$vault/phase.sh" "$@"
BASH
  bash -n workspace/scripts/ci-real-service-phase.sh
  printf '{"workflow_sha":"%s","candidate_sha":"%s","test_patch_sha":"%s","supervisor_sha":"%s"}\n' \
    "$GITHUB_WORKFLOW_SHA" "$candidate" "$tests" "$supervisor" > workspace/test-artifacts/messaging-source.json
}

activate() {
  # The unchanged supervisor enters test only after live canaries, binding
  # checks and egress removal. Check its receipt again before local Git import.
  node scripts/service-execution-boundary.mjs check
  local objects="${RUNNER_TEMP:?}/messaging-candidate.git" bundle
  bundle="$(pwd -P)/$vault/candidate.bundle"
  umask 077
  [[ -f "$bundle" && ! -L "$bundle" && ! -e "$objects" && ! -L "$objects" ]] || blocked object-store
  git init --bare --quiet --template= "$objects"
  git -C "$objects" -c protocol.allow=never -c protocol.file.allow=always \
    fetch --quiet --no-tags --no-recurse-submodules "$bundle" "$candidate"
  [[ "$(git -C "$objects" rev-parse FETCH_HEAD)" == "$candidate" ]] || blocked fetched-object
  verify_candidate "$objects"
  umask 022
  git -C "$objects" archive "$candidate" -- "${app_paths[@]}" | tar -xf - -C .
  printf '{"status":"activated_after_isolation","candidate_sha":"%s"}\n' "$candidate" \
    > test-artifacts/messaging-activation.json
}

case "${1:-}" in
  fetch) fetch_source ;;
  prepare) prepare ;;
  activate) activate ;;
  *) blocked phase ;;
esac
