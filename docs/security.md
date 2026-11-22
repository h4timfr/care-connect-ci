# CareConnect CI security

The dispatcher belongs to the separate `h4timfr/care-connect-ci` repository. Keep this repository disconnected from Vercel and all deployment integrations. The workflow runs manually on protected `main` with a read-only GitHub token. It accepts no inputs. Its application repository, candidate commit, test-patch commit, and supervisor baseline are fixed in reviewable CI files. Actions and the Supabase CLI use fixed pins.

## Required GitHub settings

1. Create the repository as **private** and make `main` its default branch. Verify the GitHub plan can enforce the following settings for a private repository.
2. Under **Settings → Rules → Rulesets**, create an active branch ruleset targeting `refs/heads/main`. Leave the bypass list empty, including for repository administrators and GitHub Apps. Block force pushes and restrict deletions.
3. Require a pull request before merging, at least one approval, review from Code Owners, and dismissal of stale pull request approvals when new commits are pushed. Review `CODEOWNERS` itself under the same rule. Use a PR author distinct from `@h4timfr` so the owner can approve each change.
4. Give only `@h4timfr` write or higher repository access to restrict dispatch. Review organization-level roles, teams, and installed Apps for inherited access. Use lower access for other reviewers. The PR rule blocks direct updates to `main`.
5. Under **Settings → Actions → General**, use restricted action access for the checked-in action pins and the read-only workflow token default. Keep Actions secrets, environment secrets, and deployment integrations disconnected. The job checks both the triggering and original actor, the exact workflow and protected main ref, and the GitHub-hosted Linux runner.
6. Review workflow, launcher, supervisor, phase, integrity manifest, candidate allowlist, and CODEOWNERS changes in every control-plane PR. Verify the effective rules and write access before dispatch.

These are required settings. Their remote enforcement awaits verification after repository creation.

## Execution boundary

The pinned public application repository is fetched anonymously over HTTPS into a bare, run-owned Git store. Git does not inherit credentials and redirects are disabled. The fetch accepts only the exact candidate identity. After isolation, root imports a sealed local Git bundle with network protocols disabled. It extracts only allowlisted application and test paths. Candidate workflows remain inert.

The protected CI revision supplies the trusted control manifest. The workflow checks it before elevation. The launcher copies and checks all control files again in a root-owned directory before executing the sealed supervisor. The workspace manifest separately covers the pinned startup and cleanup helpers, lockfile, and migration inventory. The receipt verifier remains byte-identical to its approved Git blob. The standalone supervisor, phase helper, admission plugin, and binding verifier carry the reviewed filesystem and cleanup changes.

The candidate runs under a dedicated unprivileged UID with private mount and PID namespaces inside the proven network namespace. It can write to its isolated build copy, browser profile, scratch directories, and dedicated artifact directory. It has read-only access to sealed controls and the run-owned receipt. The only Docker socket mounted is the run-owned socket subject to the admission plugin. The original checkout, runner temporary files, and shared sockets are outside the jail. A synthetic probe verifies access restrictions and process termination before disposable services start. Trusted cleanup runs separately and publishes only bounded allowlisted artifacts.

Docker admits one exact host bind, the trusted `supabase/tests` directory at `/tests:ro` for pg_prove. The pinned `supabase start` profile excludes Vector, Edge Runtime, Imgproxy, and Studio. It supplies bootstrap files through the Engine archive API and keeps PostgreSQL and Storage data in run-owned named volumes. Optional backup, template, and BigQuery mounts are outside this profile. No CLI temporary files need a host bind.

The supervisor stores the canonical ownership record in `ownership/network.json`, seals it to root with read access for the trusted runner group, and exposes a compatibility link in `evidence/` for the pinned startup observer. Trusted raw evidence lives under `evidence/`. CLI temporary files live under `cli-tmp/`. Docker rejects all three locations and the old broad `state/` location. The pre-start canary checks both access modes for each protected location and verifies that the approved read-only SQL bind can start.
