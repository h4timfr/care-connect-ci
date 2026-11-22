import assert from "node:assert/strict";
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { authorizeDocker } from "./ci-docker-admission.mjs";
import { cleanupOwnedNetwork } from "./verify-disposable-docker-bindings.mjs";

const run = "123-2";
const project = "careconnect-ci-" + run;
const id = "a".repeat(64);
const marker = { id, name: project, run_label: run };

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), "careconnect-docker-state-"));
  t.after(() => rmSync(root, { recursive: true }));
  const workspace = path.join(root, "workspace");
  const tests = path.join(workspace, "supabase", "tests");
  for (const directory of [tests, "state", "ownership", "evidence", "cli-tmp"]) {
    mkdirSync(path.resolve(root, directory), { recursive: true });
  }
  const record = path.join(root, "ownership", "network.json");
  writeFileSync(record, JSON.stringify(marker));
  chmodSync(record, 0o440);
  return {
    root,
    workspace,
    tests,
    record,
    policy: { root, workspace, run, project },
  };
}

function authorizeCreate(policy, Binds) {
  return authorizeDocker(
    {
      RequestMethod: "POST",
      RequestUri: "/v1.49/containers/create",
      RequestBody: Buffer.from(
        JSON.stringify({ HostConfig: { NetworkMode: project, Binds } }),
      ).toString("base64"),
    },
    policy,
  );
}

test("trusted pg_prove gets only its exact read-only SQL test directory", (t) => {
  const { policy, tests, workspace } = fixture(t);
  assert.equal(authorizeCreate(policy, [`${tests}:/tests:ro`]), true);
  for (const bind of [
    `${tests}:/tests`,
    `${tests}:/tests:rw`,
    `${tests}:/somewhere:ro`,
    `${workspace}/supabase:/tests:ro`,
    `${tests}/.:/tests:ro`,
  ]) {
    assert.equal(authorizeCreate(policy, [bind]), false);
  }
});

test("pinned Supabase Postgres and Storage named volumes retain write access", (t) => {
  const { policy } = fixture(t);
  assert.equal(
    authorizeCreate(policy, [
      `supabase_db_${project}:/var/lib/postgresql/data`,
      `supabase_storage_${project}:/mnt`,
    ]),
    true,
  );
  assert.equal(authorizeCreate(policy, ["supabase_storage_careconnect-ci-123-1:/mnt"]), false);
});

test("a container cannot read or modify trusted ownership, evidence, or temporary state", (t) => {
  const { root, record, policy } = fixture(t);
  const runnerFile = path.join(root, "cli-tmp", "synthetic-runner-file");
  writeFileSync(runnerFile, "runner-only");
  for (const source of [
    record,
    runnerFile,
    path.join(root, "state"),
    path.join(root, "evidence"),
    path.join(root, "cli-tmp"),
  ]) {
    for (const mode of ["ro", "rw", undefined]) {
      const bind = [source, "/tests", mode].filter(Boolean).join(":");
      assert.equal(authorizeCreate(policy, [bind]), false, bind);
    }
  }
  assert.deepEqual(JSON.parse(readFileSync(record, "utf8")), marker);
});

test("symlink and path-alias binds cannot escape into runner files", (t) => {
  const { root, tests, policy } = fixture(t);
  const escaped = path.join(root, "evidence");
  const alias = path.join(root, "cli-tmp", "alias");
  symlinkSync(tests, alias, "dir");
  assert.equal(authorizeCreate(policy, [`${alias}:/tests:ro`]), false);
  rmdirSync(tests);
  symlinkSync(escaped, tests, "dir");
  assert.equal(authorizeCreate(policy, [`${tests}:/tests:ro`]), false);
});

function mockEngine({
  networks = [project, "host", "none"],
  containers = "",
  remove = true,
  inspected = {},
} = {}) {
  const calls = [];
  function docker(args) {
    calls.push(args);
    if (args[0] === "ps") {
      assert.deepEqual(args, ["ps", "--all", "--quiet"]);
      return containers;
    }
    if (args[1] === "ls") return networks.join("\n") + "\n";
    if (args[1] === "inspect") {
      return JSON.stringify([
        {
          Name: project,
          Id: id,
          Labels: { "com.careconnect.disposable-real-service-run": run },
          Containers: {},
          ...inspected,
        },
      ]);
    }
    assert.deepEqual(args, ["network", "rm", id]);
    if (remove) networks = networks.filter((name) => name !== project);
  }
  return { docker, calls };
}

function verifyCleanup(record, docker) {
  // The files and modes are real fixtures. Represent the root ownership
  // applied by the supervisor without elevating the hosted unit tests.
  const stat = (filename) => Object.assign(lstatSync(filename), { uid: 0 });
  return cleanupOwnedNetwork(project, run, record, { docker, stat });
}

for (const [description, alter, code] of [
  ["deleted", (file) => rmSync(file), "network-ownership-marker-missing"],
  [
    "corrupted",
    (file) => {
      chmodSync(file, 0o600);
      writeFileSync(file, "{broken");
      chmodSync(file, 0o440);
    },
    "network-ownership-marker-invalid",
  ],
  ["made writable", (file) => chmodSync(file, 0o660), "network-ownership-marker-invalid"],
  [
    "replaced by a symlink",
    (file) => {
      rmSync(file);
      const other = path.join(path.dirname(file), "other-record");
      writeFileSync(other, JSON.stringify(marker), { mode: 0o440 });
      symlinkSync(other, file);
    },
    "network-ownership-marker-invalid",
  ],
]) {
  test(`a ${description} marker fails closed even when the network is absent`, (t) => {
    const { record } = fixture(t);
    alter(record);
    const engine = mockEngine({ networks: ["host", "none"] });
    assert.deepEqual(verifyCleanup(record, engine.docker).failure_codes, [code]);
    assert.deepEqual(engine.calls, []);
  });
}

test("cleanup fails if a container remains even with the owned network absent", (t) => {
  const { record } = fixture(t);
  const { docker } = mockEngine({
    networks: ["host", "none"],
    containers: "b".repeat(64),
  });
  assert.deepEqual(verifyCleanup(record, docker).failure_codes, [
    "private-daemon-containers-remain",
  ]);
});

test("cleanup rejects another network and a supposedly removed network that remains", (t) => {
  const { record } = fixture(t);
  for (const [options, code] of [
    [{ networks: ["host", "none", "other-network"] }, "unexpected-private-network-inventory"],
    [{ remove: false }, "network-removal-unverified"],
    [{ inspected: { Id: "b".repeat(64) } }, "network-ownership-mismatch"],
    [{ inspected: { Containers: { remaining: {} } } }, "owned-network-still-has-containers"],
  ]) {
    const { docker } = mockEngine(options);
    assert.deepEqual(verifyCleanup(record, docker).failure_codes, [code]);
  }
});

test("cleanup passes only after confirming the owned network and all containers are absent", (t) => {
  const { record } = fixture(t);
  for (const networks of [
    [project, "none", "host"],
    ["none", "host"],
  ]) {
    const engine = mockEngine({ networks });
    assert.equal(verifyCleanup(record, engine.docker).status, "PASS");
    assert.deepEqual(engine.calls.at(-1), ["ps", "--all", "--quiet"]);
    assert.equal(engine.calls.filter((args) => args[1] === "ls").length, 2);
  }
});

test("inventory and teardown failures propagate to the supervisor result", () => {
  const supervisor = readFileSync(new URL("ci-isolated-docker.sh", import.meta.url), "utf8");
  const phase = readFileSync(new URL("ci-real-service-phase.sh", import.meta.url), "utf8");
  assert.match(supervisor, /if ! user_phase cleanup; then rc=1; fi/);
  assert.match(
    supervisor,
    /if empty_engine_resources; then inventory=PASS; else inventory=FAIL; fi/,
  );
  assert.match(supervisor, /teardown_rc=1[\s\S]*?if \(\( teardown_rc \)\); then[\s\S]*?exit 1/);
  assert.match(phase, /docker_bounded volume rm "\$volume"/);
  assert.match(phase, /docker-network-cleanup-summary[.]json "\$run_label" \|\| code=1/);
});
