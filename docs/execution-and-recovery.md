# Disposable messaging execution and recovery

## Publication

1. Review the standalone CI commit and the exact application candidate `2269446689318a13639ca45471224ace96503d23`. Confirm the candidate's root `vercel.json` excludes `codex/messaging-disposable-verification` from automatic Git deployments. Keep application PRs #3–#6 separate.
2. Obtain separate approval to create an empty `h4timfr/care-connect-ci` repository and bootstrap its default branch, `main`, with the reviewed standalone commit. Keep deployment integrations disconnected. Establish and verify the required branch rules before permitting dispatch. Apply the access policy in [Security](security.md).
3. Obtain separate approval to push the exact application candidate to `refs/heads/codex/messaging-disposable-verification` using a normal explicit refspec. The candidate's remaining push workflows target a different branch. Confirm the candidate ref and record the resulting CI main commit.
4. Verify read access to the application repository using the minimum access described in [Security](security.md). Obtain separate approval to dispatch one run against the CI repository's protected main.

   ```bash
   gh workflow run messaging-disposable-dispatch.yml --repo h4timfr/care-connect-ci --ref main
   ```

## Verify the run

Confirm the reported workflow, candidate, test patch, and supervisor identities, plus the admission and loopback evidence before startup. Check the verified service bindings, egress removal, and candidate activation. The expected inventory is 46 canonical migrations, 25 pgTAP files with 609 planned assertions, nine booking concurrency scenarios, and four browser workflows. The clinic case keeps its 120-second budget. Check the service assertions for direct socket delivery and reconnect separately from browser polling. Require the cleanup verification as part of accepting the run.

## Recover from a blocked or failed run

Use only the allowlisted diagnostics and startup, test, and cleanup summaries. An exit 78 means a prerequisite or isolation check blocked execution. If retrieval failed, check candidate publication and source read scope. If isolation or cleanup failed, treat the run as failed. Review runner isolation and cleanup evidence before authorizing another run. The supervisor uses run-owned resources and handles normal exit, test failure, and cancellation signals. Forced termination may interrupt validation. Use the disposable runner's teardown evidence and keep application and hosted database resources outside recovery operations.

Make corrections through reviewed CI pull requests. Repin changed candidate or supervisor identities only after reviewing the exact new commits and checking their inventories and digests. Authorize any new hosted attempt separately.
