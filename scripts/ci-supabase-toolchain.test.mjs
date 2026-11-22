import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

const release =
  "https://github.com/supabase/cli/releases/download/v2.117.0/supabase_2.117.0_linux_amd64.tar.gz";
const standaloneDigest = "40efbaffd04e4cbf501b4f29a52c88ca23f81c636ef211e3b255c4e7b81eeb01";

test("the workflow installs the official standalone CLI and rejects a different download", (t) => {
  const archive = process.env.CARECONNECT_SUPABASE_RELEASE_ARCHIVE;
  assert.ok(
    archive && path.isAbsolute(archive),
    "Set CARECONNECT_SUPABASE_RELEASE_ARCHIVE to the official Linux AMD64 tarball.",
  );

  const workflow = readFileSync(
    new URL("../.github/workflows/messaging-disposable-dispatch.yml", import.meta.url),
    "utf8",
  ).replaceAll("\r\n", "\n");
  const block = workflow.split("      - name: Install pinned Supabase CLI\n")[1];
  assert.ok(block);
  const shell = block
    .split("        run: |\n")[1]
    .split("\n      - name:")[0]
    .split("\n")
    .map((line) => line.slice(10))
    .join("\n");
  assert.match(workflow, /SUPABASE_CLI_BINARY: \$\{\{ steps\.supabase_cli\.outputs\.binary \}\}/);
  assert.match(workflow, /"\$\(command -v node\)" "\$SUPABASE_CLI_BINARY"/);

  const root = mkdtempSync(path.join(tmpdir(), "careconnect-supabase-toolchain-"));
  t.after(() => rmSync(root, { recursive: true }));
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  const curl = path.join(bin, "curl");
  // Supply the actual release asset offline and require the exact release URL.
  writeFileSync(
    curl,
    `#!/bin/bash
set -euo pipefail
while [[ "$1" != --output ]]; do shift; done
[[ $# == 3 && "$3" == '${release}' ]]
cp -- "$RELEASE_ARCHIVE_FIXTURE" "$2"
`,
  );
  chmodSync(curl, 0o700);

  function install(name, fixture) {
    const runnerTemp = path.join(root, name);
    mkdirSync(runnerTemp);
    const output = path.join(runnerTemp, "output");
    const result = spawnSync("/bin/bash", ["-c", shell], {
      encoding: "utf8",
      cwd: root,
      timeout: 30000,
      env: {
        PATH: `${bin}:/usr/bin:/bin`,
        RUNNER_TEMP: runnerTemp,
        GITHUB_OUTPUT: output,
        RELEASE_ARCHIVE_FIXTURE: fixture,
      },
    });
    assert.ifError(result.error);
    return { result, output, runnerTemp };
  }

  const good = install("official", archive);
  assert.equal(good.result.status, 0, good.result.stderr);
  const match = /^binary=(.+)\n$/.exec(readFileSync(good.output, "utf8"));
  assert.ok(match);
  const binary = match[1];
  const executable = readFileSync(binary);
  assert.equal(createHash("sha256").update(executable).digest("hex"), standaloneDigest);
  assert.equal(executable.subarray(0, 4).toString("hex"), "7f454c46");
  assert.deepEqual(readdirSync(path.dirname(binary)), ["supabase"]);
  const version = spawnSync(binary, ["--version"], {
    cwd: root,
    encoding: "utf8",
    timeout: 10000,
    env: { HOME: root, PATH: "/usr/bin:/bin", SUPABASE_TELEMETRY_DISABLED: "1" },
  });
  assert.ifError(version.error);
  assert.equal(version.status, 0, version.stderr);
  assert.equal(version.stdout.trim(), "2.117.0");

  const wrong = path.join(root, "unexpected-download");
  writeFileSync(wrong, "synthetic wrong archive");
  const bad = install("rejected", wrong);
  assert.notEqual(bad.result.status, 0);
  assert.match(bad.result.stdout, /FAILED/);
  assert.equal(existsSync(bad.output), false);
  assert.ok(
    readdirSync(bad.runnerTemp).every(
      (entry) => readdirSync(path.join(bad.runnerTemp, entry)).length === 0,
    ),
  );
});
