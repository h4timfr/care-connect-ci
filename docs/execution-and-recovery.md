# Disposable messaging execution and recovery

## Publication

1. Review the standalone CI commit and the exact application candidate `871007f3883b29e6767e1b93789132caae866833`. Confirm the candidate's root `vercel.json` excludes `codex/messaging-disposable-verification` from automatic Git deployments. Keep application PRs #3–#6 separate.
2. Obtain separate approval to create an empty `h4timfr/care-connect-ci` repository and bootstrap its default branch, `main`, with the reviewed standalone commit. Keep deployment integrations disconnected. Establish and verify the required branch rules before permitting dispatch. Apply the access policy in [Security](security.md).
3. Obtain separate approval to push the exact application candidate to `refs/heads/codex/messaging-disposable-verification` using a normal explicit refspec. The candidate's remaining push workflows target a different branch. Confirm the candidate ref and record the resulting CI main commit.
4. Verify anonymous read access to the pinned public application commit. Obtain separate approval to dispatch one run against the CI repository's protected main as `@h4timfr`.

   ```bash
   gh workflow run messaging-disposable-dispatch.yml --repo h4timfr/care-connect-ci --ref main
   ```

## Verify the run

Confirm the reported workflow, candidate, test patch, and supervisor identities. Require the filesystem proof, admission evidence, and loopback canary before startup. Check the verified service bindings, egress removal, and candidate activation. The expected inventory is 46 canonical migrations, 25 pgTAP files with 609 planned assertions, nine booking concurrency scenarios, and four browser workflows. The clinic case keeps its 120-second budget. Review direct socket delivery and reconnection alongside the browser tests. A healthy anonymous subscription may receive a row-free denial envelope, and must receive zero row events and have no access to the target rows. Require cleanup verification as part of accepting the run.

The standalone checkout needs full history so the root bootstrap can verify the exact workflow commit against the reviewed control baseline. A bootstrap identity, manifest, or handoff error blocks candidate activation. Review the named failure category before retrying. In a dedicated Linux verification environment, `node --test scripts/ci-root-bootstrap.test.mjs` exercises the embedded bootstrap with synthetic Git objects and UID 65534. Run that test from a root session in the disposable environment.

Require a passing network cleanup summary and teardown summary. A missing, malformed, or mismatched ownership record fails the run. The supervisor independently verifies zero containers and volumes and only the built-in Docker networks before stopping the private units. It then checks the unit states, namespace removal, and removal of run-owned filesystem state.

## Recover from a blocked or failed run

Use only the allowlisted diagnostics and startup, test, and cleanup summaries. Exit 78 identifies a failed prerequisite or isolation check. If retrieval failed, check that the exact commit is published and accessible anonymously. If the filesystem proof or network gates failed, investigate the named phase before authorizing another run. The supervisor uses run-owned resources and handles normal exit, test failure, and cancellation signals. Forced termination may interrupt validation. Use the disposable runner's teardown evidence and keep application and hosted database resources outside recovery operations.

Make corrections through reviewed CI pull requests. Repin changed candidate or supervisor identities only after reviewing the exact new commits and checking their inventories and digests. Authorize any new hosted attempt separately.
