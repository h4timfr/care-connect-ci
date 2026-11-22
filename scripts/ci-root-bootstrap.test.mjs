import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

const repository = fileURLToPath(new URL("../", import.meta.url));
const workflow = ".github/workflows/messaging-disposable-dispatch.yml";
const manifest = ".github/ci/trusted-control.sha256";
const launcher = ".github/ci/launch-protected.sh";
const admission = "scripts/ci-docker-admission.mjs";
const approved = "8270499e883af9bc503c3b54289fcc6eba4bafb6";
const approvedDigest = "48d9517f90645fe2281e546c5589f6a595575f78848661901beb75492c849f69";
const source = readFileSync(path.join(repository, workflow), "utf8").replaceAll("\r\n", "\n");
const bootstrap = source
  .split("          bootstrap=$(/usr/bin/cat <<'ROOT_BOOTSTRAP'\n")[1]
  .split("\n          ROOT_BOOTSTRAP")[0]
  .split("\n")
  .map((line) => line.slice(10))
  .join("\n");
const handoff = '/bin/bash "$sealed/control/$launcher" start "$sealed" "$@" "$active_digest"';
const recheck = "# Recheck the root-owned handoff immediately before invoking a shell file.";
const runner = "65534";
let fixture, checkout, commit, bundle, identity;
const env = {
  PATH: "/usr/sbin:/usr/bin:/sbin:/bin",
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_TERMINAL_PROMPT: "0",
};

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    env,
    timeout: 20000,
    maxBuffer: 10 * 1024 * 1024,
    ...options,
  });
  assert.ifError(result.error);
  return result;
}

function checked(command, args, options) {
  const result = run(command, args, options);
  assert.equal(result.status, 0, result.stderr.toString());
  return result.stdout;
}

function git(...args) {
  return checked("git", ["-c", `safe.directory=${checkout}`, "-C", checkout, ...args]);
}

function asRunner(script, ...args) {
  return checked("setpriv", [
    `--reuid=${runner}`,
    `--regid=${runner}`,
    "--clear-groups",
    "--no-new-privs",
    "/bin/bash",
    "-ec",
    script,
    "runner",
    checkout,
    ...args,
  ]);
}

function restoreControl(file, mutate) {
  const destination = path.join(checkout, file);
  const original = readFileSync(destination);
  // Model a modification after an initial successful checkout verification.
  asRunner('cd "$1"; sha256sum --check --strict --quiet .github/ci/trusted-control.sha256');
  try {
    mutate(destination);
    assertBlocked(runBootstrap(), "checkout-control-changed");
  } finally {
    writeFileSync(destination, original);
  }
}

function runBootstrap(script = bootstrap, overrides = {}, { tools } = {}) {
  assert.ok(script.includes(handoff));
  // Execute the actual sealed launcher and its verifier, stopping at the
  // point where production would prepare tools and start disposable services.
  const scriptToRun = tools
    ? script
    : script.replace(
        handoff,
        '/bin/bash "$sealed/control/$launcher" verify "$sealed" "$active_digest"\nprintf "verified-launcher-handoff\\n"',
      );
  const result = run(
    "/bin/bash",
    [
      "--noprofile",
      "--norc",
      "-c",
      scriptToRun,
      "careconnect",
      "991-1",
      checkout,
      ...(tools ?? ["/unused-node", "/unused-cli", "/unused-browser"]),
    ],
    {
      input: bundle,
      env: { ...env, ...identity, ...overrides },
    },
  );
  return {
    status: result.status,
    output: Buffer.concat([result.stdout, result.stderr]).toString(),
  };
}

function assertBlocked(result, reason) {
  assert.equal(result.status, 78, result.output);
  assert.match(result.output, new RegExp(`Root bootstrap BLOCKED \\(${reason}\\)`));
  assert.doesNotMatch(result.output, /verified-launcher-handoff/);
}

before(() => {
  assert.equal(
    process.getuid?.(),
    0,
    "Run these synthetic fixture tests in a dedicated Linux root session.",
  );
  assert.ok(bootstrap.includes(handoff) && bootstrap.includes(recheck));
  fixture = mkdtempSync("/var/tmp/careconnect-bootstrap-fixture.");
  chmodSync(fixture, 0o755);
  checkout = path.join(fixture, "checkout");
  mkdirSync(checkout);
  git("init", "--quiet", "--template=");
  git(
    "-c",
    "protocol.allow=never",
    "-c",
    "protocol.file.allow=always",
    "fetch",
    "--quiet",
    "--no-tags",
    repository,
    approved,
  );
  git("checkout", "--quiet", "--detach", "FETCH_HEAD");
  for (const file of [launcher, manifest, workflow]) {
    copyFileSync(path.join(repository, file), path.join(checkout, file));
    chmodSync(path.join(checkout, file), 0o644);
  }
  git("add", "--", launcher, manifest, workflow);
  git(
    "-c",
    "user.name=CI Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "commit",
    "--quiet",
    "-m",
    "Synthetic workflow revision",
  );
  commit = git("rev-parse", "HEAD").toString().trim();
  bundle = git("bundle", "create", "-", "HEAD");
  checked("chown", ["-hR", `${runner}:${runner}`, checkout]);
  identity = {
    SUDO_UID: runner,
    SUDO_GID: runner,
    CI_REPOSITORY: "h4timfr/care-connect-ci",
    CI_WORKFLOW_REF: `h4timfr/care-connect-ci/${workflow}@refs/heads/main`,
    CI_PROTECTED: "true",
    CI_EVENT: "workflow_dispatch",
    CI_OWNER: "h4timfr",
    CI_TRIGGER: "h4timfr",
    CI_REVISION: commit,
    CI_DISPATCH: commit,
    CI_CHECKED_OUT: commit,
  };
});

after(() => {
  if (fixture) rmSync(fixture, { recursive: true });
});

test("the two pinned revisions reach the actual launcher in the sealed tree", () => {
  const result = runBootstrap();
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /verified-launcher-handoff/);
});

for (const file of [launcher, manifest, admission]) {
  test(`a changed checkout copy of ${file} cannot reach the launcher`, () => {
    restoreControl(file, (destination) =>
      appendFileSync(destination, "\n# synthetic changed file\n"),
    );
  });
}

test("a surviving runner process cannot change the seal, and a dirty checkout blocks handoff", () => {
  const original = readFileSync(path.join(checkout, launcher));
  const audit = "# A dirty checkout blocks the run";
  assert.ok(bootstrap.includes(audit));
  const background = String.raw`setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --clear-groups \
    --no-new-privs /bin/bash -ec \
    'if (printf denied >>"$1") 2>/dev/null; then exit 1; fi; printf changed >>"$2"' \
    runner "$sealed/control/$launcher" "$2/$launcher" &
wait $!`;
  try {
    assertBlocked(
      runBootstrap(bootstrap.replace(audit, background + "\n" + audit)),
      "checkout-control-changed",
    );
  } finally {
    writeFileSync(path.join(checkout, launcher), original);
  }
});

test("an altered root-owned control is rejected at the handoff recheck", () => {
  const altered = bootstrap.replace(
    recheck,
    'printf changed >>"$sealed/control/$launcher"\n' + recheck,
  );
  assertBlocked(runBootstrap(altered), "sealed-control-changed");
});

test("unexpected sealed files are rejected", () => {
  const altered = bootstrap.replace(
    recheck,
    'install -m 0444 /dev/null "$sealed/control/unexpected"\n' + recheck,
  );
  assertBlocked(runBootstrap(altered), "sealed-control-metadata");
});

test("an incorrect independent manifest pin rejects intact Git objects", () => {
  assert.ok(bootstrap.includes(approvedDigest));
  assertBlocked(runBootstrap(bootstrap.replace(approvedDigest, "0".repeat(64))), "manifest-digest");
  assertBlocked(
    runBootstrap(
      bootstrap.replace(/active_digest=[a-f0-9]{64}/, "active_digest=" + "0".repeat(64)),
    ),
    "manifest-digest",
  );
});

test("unprotected main or a different Git object fails closed", () => {
  assertBlocked(runBootstrap(bootstrap, { CI_PROTECTED: "false" }), "workflow-identity");
  const wrong = "0".repeat(40);
  assertBlocked(
    runBootstrap(bootstrap, { CI_REVISION: wrong, CI_DISPATCH: wrong, CI_CHECKED_OUT: wrong }),
    "bundle-tip",
  );
});

test("the real launcher refuses an aliased workspace scripts directory before executing tools", () => {
  const work = path.join(checkout, "workspace");
  mkdirSync(path.join(work, "node_modules"), { recursive: true });
  symlinkSync(path.join(checkout, "scripts"), path.join(work, "scripts"), "dir");
  const executable = path.join(fixture, "unused-executable");
  writeFileSync(executable, "synthetic fixture", { mode: 0o555 });
  try {
    const result = runBootstrap(bootstrap, {}, { tools: [executable, executable, fixture] });
    assert.equal(result.status, 78, result.output);
    assert.match(result.output, /Trusted control BLOCKED \(workspace-alias\)/);
  } finally {
    rmSync(work, { recursive: true });
  }
});
