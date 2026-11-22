#!/usr/bin/env bash
set -euo pipefail

readonly app_repository=https://github.com/h4timfr/care-connect-chennai.git
readonly supervisor=366ef27d728b623233cc414adeb4d558085fd8a4
readonly bootstrap=1cfc9ea4d696de3d8c1a633e8e537f9bdd219aa7
readonly messaging=112c254accdc3d34250f86561787d560f18bc9db
readonly tests=df34e2004ada66e4d3f2283d3f8351eff43a3ab8
readonly old_driver=b88dc37e33d744887ca3f4eb5daa0eeb76ed242a
readonly original_candidate=2269446689318a13639ca45471224ace96503d23
readonly realtime_candidate=9a7f6ba7746312cd8f08f178f0fb23304eef04f4
readonly candidate=871007f3883b29e6767e1b93789132caae866833
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
  env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 timeout --signal=TERM --kill-after=5s 3m \
    git -C "$store" -c credential.helper= -c protocol.allow=never -c protocol.https.allow=always \
    -c http.followRedirects=false fetch --quiet --no-tags --no-recurse-submodules \
    "$app_repository" "$candidate:refs/heads/reviewed-candidate" >/dev/null 2>&1 ||
    blocked source-fetch
  [[ "$(git -C "$store" rev-parse FETCH_HEAD)" == "$candidate" ]] || blocked fetched-object
}

verify_candidate() {
  local repo=$1 delta path
  [[ "$(git -C "$repo" rev-parse --verify "$candidate^{commit}")" == "$candidate" ]] || blocked candidate
  [[ "$(git -C "$repo" rev-list --parents -n 1 "$candidate")" == "$candidate $realtime_candidate" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$realtime_candidate")" == "$realtime_candidate $original_candidate" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$original_candidate")" == "$original_candidate $old_driver" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$old_driver")" == "$old_driver $tests" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$tests")" == "$tests $messaging" &&
     "$(git -C "$repo" rev-list --parents -n 1 "$messaging")" == "$messaging $bootstrap" ]] || blocked parent-chain
  git -C "$repo" merge-base --is-ancestor "$supervisor" "$messaging" || blocked approved-ancestry
  [[ "$(git -C "$repo" rev-list --count "$supervisor..$messaging")" == 18 &&
     "$(git -C "$repo" rev-list --count "$supervisor..$candidate")" == 23 &&
     "$(git -C "$repo" rev-list --count --merges "$supervisor..$candidate")" == 0 ]] || blocked unexpected-history

  delta=$(git -C "$repo" diff --no-renames --name-status "$old_driver" "$original_candidate")
  [[ "$delta" == $'D\t.github/workflows/messaging-disposable-verification.yml' ]] || blocked driver-removal
  delta=$(git -C "$repo" diff --no-renames --name-status "$original_candidate" "$realtime_candidate")
  [[ "$delta" == $'M\tscripts/real-service-integration.mjs\nM\tscripts/real-service-integration.test.mjs' ]] ||
    blocked realtime-test-tree
  delta=$(git -C "$repo" diff --no-renames --name-status "$realtime_candidate" "$candidate")
  [[ "$delta" == $'M\tscripts/staging-reconciliation-rehearsal.test.mjs' ]] || blocked publication-test-tree
  git -C "$repo" diff --quiet "$tests" "$original_candidate" -- "${app_paths[@]}" || blocked application-or-test-tree
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
    case "$file" in
      scripts/ci-isolated-docker.sh|scripts/ci-real-service-phase.sh|scripts/ci-docker-admission.mjs|scripts/verify-disposable-docker-bindings.mjs) ;;
      *) git -C "$store" cat-file blob "$supervisor:$file" | cmp -s - "$file" ||
           blocked supervisor-baseline ;;
    esac
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
  printf '{"workflow_sha":"%s","candidate_sha":"%s","test_patch_sha":"%s","supervisor_sha":"%s"}\n' \
    "$GITHUB_WORKFLOW_SHA" "$candidate" "$tests" "$supervisor" > workspace/test-artifacts/messaging-source.json
}

extract_candidate() {
  # Invoked from the sealed root control only, after the supervisor verifies
  # the live receipt and removes egress. This phase reads Git data only.
  local bundle=$1 dest=$2 objects=$3
  [[ "$(id -u)" == 0 && -d "$dest" && ! -L "$dest" && "$(stat -c %u "$dest")" == 0 ]] ||
    blocked extraction-owner
  umask 077
  [[ -f "$bundle" && ! -L "$bundle" && ! -e "$objects" && ! -L "$objects" ]] || blocked object-store
  git init --bare --quiet --template= "$objects"
  git -C "$objects" -c protocol.allow=never -c protocol.file.allow=always \
    fetch --quiet --no-tags --no-recurse-submodules "$bundle" "$candidate"
  [[ "$(git -C "$objects" rev-parse FETCH_HEAD)" == "$candidate" ]] || blocked fetched-object
  verify_candidate "$objects"
  umask 022
  git -C "$objects" archive "$candidate" -- "${app_paths[@]}" | tar -xf - -C "$dest"
}

case "${1:-}" in
  fetch) fetch_source ;;
  prepare) prepare ;;
  extract) shift; [[ $# == 3 ]] || blocked arguments; extract_candidate "$@" ;;
  *) blocked phase ;;
esac
