import { spawnSync } from "node:child_process";
import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { isIP } from "node:net";
import { pathToFileURL } from "node:url";
import {
  privateDockerIdentity,
  reportServiceExecutionBlock,
} from "./service-execution-boundary.mjs";

const projectLabel = "com.supabase.cli.project";
const workflowLabel = "com.careconnect.disposable-real-service-run";
const hostBindingOption = "com.docker.network.bridge.host_binding_ipv4";
const expectedHostBinding = "127.0.0.1";
const allowedHostAddresses = new Set(["127.0.0.1", "::1"]);

function classifyAddress(address) {
  if (address === "127.0.0.1") return "loopback-v4";
  if (address === "::1") return "loopback-v6";
  if (address === "0.0.0.0" || address === "*") return "wildcard-v4";
  if (address === "::") return "wildcard-v6";
  if (!address) return "unspecified";
  const family = isIP(address);
  if (family === 4 && address.startsWith("127.")) return "unexpected-loopback-v4";
  if (family === 4) return "non-loopback-v4";
  if (family === 6) return "non-loopback-v6";
  return "unrecognized";
}

function validName(value) {
  return typeof value === "string" && /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$/.test(value);
}

function writeEvidence(filename, evidence) {
  const outputPath = path.resolve(filename);
  mkdirSync(path.dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, {
    mode: 0o600,
  });
}

function run(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    timeout: 20_000,
    windowsHide: true,
  });
  if (result.error || (result.status !== 0 && !allowFailure)) {
    throw new Error("inspection-command-failed");
  }
  return { status: result.status, stdout: result.stdout ?? "" };
}

function parseJsonOutput(result) {
  try {
    return JSON.parse(result.stdout);
  } catch {
    throw new Error("inspection-output-invalid");
  }
}

export function parseSsListeners(output) {
  const listeners = [];
  let malformedLines = 0;
  for (const line of output.split(/\r?\n/).filter(Boolean)) {
    const fields = line.trim().split(/\s+/);
    const protocol = fields[0];
    if (!["tcp", "tcp6", "udp", "udp6"].includes(protocol) || fields.length < 5) {
      malformedLines += 1;
      continue;
    }
    const endpoint = fields[4];
    const separator = endpoint.lastIndexOf(":");
    const port = Number(endpoint.slice(separator + 1));
    let address = endpoint.slice(0, separator);
    if (address.startsWith("[") && address.endsWith("]")) {
      address = address.slice(1, -1);
    }
    if (separator < 1 || !Number.isInteger(port) || port < 1 || port > 65_535) {
      malformedLines += 1;
      continue;
    }
    listeners.push({
      protocol: protocol.startsWith("udp") ? "udp" : "tcp",
      address,
      port,
    });
  }
  return { listeners, malformedLines };
}

function validateNetwork(network, expectedName, expectedRunLabel, requireInternal = true) {
  const failures = [];
  if (!network || network.Name !== expectedName) failures.push("network-name-mismatch");
  if (network?.Driver !== "bridge") failures.push("network-driver-not-bridge");
  if (network?.Internal !== requireInternal)
    failures.push(requireInternal ? "network-not-internal" : "private-bridge-policy-mismatch");
  if (
    !requireInternal &&
    (network?.IPAM?.Config?.length !== 1 ||
      network.IPAM.Config[0]?.Subnet !== "172.30.0.0/24" ||
      network.IPAM.Config[0]?.Gateway !== "172.30.0.1")
  )
    failures.push("private-bridge-gateway-mismatch");
  if (network?.EnableIPv6 !== false) failures.push("network-ipv6-direct-routing-enabled");
  if (network?.Options?.[hostBindingOption] !== expectedHostBinding) {
    failures.push("network-loopback-default-missing");
  }
  if (network?.Labels?.[workflowLabel] !== expectedRunLabel) {
    failures.push("network-run-ownership-mismatch");
  }
  return failures;
}

function validPortBinding(containerPort, mapping, failures) {
  const hostIp = typeof mapping?.HostIp === "string" ? mapping.HostIp : "";
  const hostPort = Number(mapping?.HostPort);
  if (!allowedHostAddresses.has(hostIp) || isIP(hostIp) === 0) {
    failures.push("published-port-not-loopback-bound");
  }
  if (!Number.isInteger(hostPort) || hostPort < 1 || hostPort > 65_535) {
    failures.push("published-port-mapping-invalid");
  }
  const protocol = containerPort.endsWith("/udp") ? "udp" : "tcp";
  return {
    container_port: containerPort,
    protocol,
    host_address_scope: classifyAddress(hostIp),
    host_port: Number.isFinite(hostPort) ? hostPort : null,
  };
}

export function assessDockerRuntime({
  network,
  expectedNetworkName,
  expectedRunLabel,
  projectId,
  containers,
  listeners,
  malformedListenerLines = 0,
  requireInternal = true,
}) {
  const failures = validateNetwork(network, expectedNetworkName, expectedRunLabel, requireInternal);
  if (malformedListenerLines > 0) failures.push("host-listener-output-unparseable");
  const projectContainers = containers.filter(
    (container) => container.Config?.Labels?.[projectLabel] === projectId,
  );
  if (projectContainers.length === 0) failures.push("supabase-project-containers-not-found");

  const networkContainerIds = Object.keys(network?.Containers ?? {}).sort();
  const projectContainerIds = projectContainers.map((container) => container.Id).sort();
  if (
    networkContainerIds.length !== projectContainerIds.length ||
    networkContainerIds.some((id, index) => id !== projectContainerIds[index])
  ) {
    failures.push("network-contains-unexpected-containers");
  }

  const publishedPorts = [];
  for (const container of projectContainers) {
    const networks = container.NetworkSettings?.Networks ?? {};
    const attachedNetworkNames = Object.keys(networks);
    if (
      attachedNetworkNames.length !== 1 ||
      attachedNetworkNames[0] !== expectedNetworkName ||
      networks[expectedNetworkName]?.NetworkID !== network?.Id
    ) {
      failures.push("supabase-container-network-mismatch");
    }
    const mode = container.HostConfig?.NetworkMode;
    if (![expectedNetworkName, network?.Id].includes(mode)) {
      failures.push("supabase-container-network-mode-mismatch");
    }
    if (container.State?.Running !== true) failures.push("supabase-container-not-running");

    const configuredPorts = container.HostConfig?.PortBindings ?? {};
    const actualPorts = container.NetworkSettings?.Ports ?? {};
    for (const [containerPort, configured] of Object.entries(configuredPorts)) {
      if (!Array.isArray(configured) || configured.length === 0) continue;
      const actual = actualPorts[containerPort];
      if (!Array.isArray(actual) || actual.length === 0) {
        failures.push("published-port-runtime-binding-missing");
        continue;
      }
    }
    for (const [containerPort, mappings] of Object.entries(actualPorts)) {
      if (mappings === null || mappings === undefined) continue;
      if (!Array.isArray(mappings) || mappings.length === 0) {
        failures.push("published-port-runtime-binding-invalid");
        continue;
      }
      for (const mapping of mappings)
        publishedPorts.push(validPortBinding(containerPort, mapping, failures));
    }
  }
  if (publishedPorts.length === 0) failures.push("no-published-service-ports");

  const publishedHostPorts = new Set(
    publishedPorts
      .filter((binding) => binding.host_port !== null)
      .map((binding) => `${binding.protocol}:${binding.host_port}`),
  );
  const matchingListeners = listeners.filter((listener) =>
    publishedHostPorts.has(`${listener.protocol}:${listener.port}`),
  );
  for (const listener of matchingListeners) {
    if (!allowedHostAddresses.has(listener.address) || isIP(listener.address) === 0) {
      failures.push("published-port-host-listener-not-loopback");
    }
  }

  return {
    status: failures.length === 0 ? "PASS" : "FAIL",
    failure_codes: [...new Set(failures)].sort(),
    network: {
      driver: network?.Driver ?? "unknown",
      internal: network?.Internal === true,
      ipv6_enabled: network?.EnableIPv6 === true,
      host_binding_address_scope: classifyAddress(network?.Options?.[hostBindingOption] ?? ""),
      ownership_label_matches: network?.Labels?.[workflowLabel] === expectedRunLabel,
    },
    container_count: projectContainers.length,
    attached_container_count: networkContainerIds.length,
    published_ports: publishedPorts.sort((left, right) =>
      `${left.protocol}:${left.host_port}:${left.container_port}`.localeCompare(
        `${right.protocol}:${right.host_port}:${right.container_port}`,
      ),
    ),
    host_listener_check: {
      inspected: true,
      published_port_count: publishedHostPorts.size,
      matching_listener_count: matchingListeners.length,
      listeners: matchingListeners.map(({ protocol, address, port }) => ({
        protocol,
        address_scope: classifyAddress(address),
        port,
      })),
      no_socket_listener_is_compatible_with_docker_nat: true,
    },
  };
}

function loadConfigProjectId(configPath) {
  const source = readFileSync(configPath, "utf8");
  const match = source.match(/^\s*project_id\s*=\s*"([A-Za-z0-9_.-]+)"\s*$/m);
  if (!match) throw new Error("project-id-not-found");
  return match[1];
}

function inspectNetwork(nameOrId) {
  return parseJsonOutput(run("docker", ["network", "inspect", nameOrId]))[0];
}

function saveFailure(filename, code) {
  writeEvidence(filename, { status: "FAIL", failure_codes: [code] });
}

async function createNetwork(name, runLabel, evidencePath, markerPath) {
  if (!validName(name) || !validName(runLabel)) throw new Error("network-name-invalid");
  try {
    const existing = run("docker", ["network", "ls", "--format", "{{.Name}}"])
      .stdout.split(/\r?\n/)
      .filter(Boolean);
    if (existing.includes(name)) throw new Error("network-name-already-exists");
    const created = run("docker", [
      "network",
      "create",
      "--driver",
      "bridge",
      "--subnet",
      "172.30.0.0/24",
      "--gateway",
      "172.30.0.1",
      "--label",
      `${workflowLabel}=${runLabel}`,
      "--opt",
      `${hostBindingOption}=${expectedHostBinding}`,
      name,
    ]);
    const networkId = created.stdout.trim();
    if (!/^[a-f0-9]{64}$/i.test(networkId)) throw new Error("network-id-invalid");
    writeEvidence(markerPath, { id: networkId, name, run_label: runLabel });
    const network = inspectNetwork(networkId);
    const failures = validateNetwork(network, name, runLabel, false);
    const evidence = {
      status: failures.length === 0 ? "PASS" : "FAIL",
      failure_codes: failures,
      stage: "network-policy-before-supabase-start",
      network: {
        driver: network?.Driver ?? "unknown",
        internal: network?.Internal === true,
        ipv6_enabled: network?.EnableIPv6 === true,
        host_binding_address_scope: classifyAddress(network?.Options?.[hostBindingOption] ?? ""),
        ownership_label_matches: network?.Labels?.[workflowLabel] === runLabel,
      },
      container_count: 0,
      published_ports: [],
    };
    writeEvidence(evidencePath, evidence);
    if (failures.length) throw new Error("network-policy-verification-failed");
    console.log(
      "Disposable Docker network policy PASS (private namespace bridge; default published-port binding 127.0.0.1).",
    );
  } catch (error) {
    saveFailure(
      evidencePath,
      error.message === "network-name-already-exists"
        ? error.message
        : "network-policy-setup-failed",
    );
    throw error;
  }
}

export function applyStartupOutcome(assessment, outcome) {
  if (outcome === "success") return assessment;
  if (["failure", "cancelled"].includes(outcome)) {
    return {
      ...assessment,
      status: "NOT_EVALUATED",
      reason: "stack-unavailable",
    };
  }
  return { ...assessment, status: "FAIL", reason: "startup-outcome-unknown" };
}

function verifyRuntime(name, configPath, evidencePath, runLabel, startupOutcome) {
  try {
    const network = inspectNetwork(name);
    const projectId = loadConfigProjectId(configPath);
    const ids = run("docker", ["ps", "--quiet", "--filter", `label=${projectLabel}=${projectId}`])
      .stdout.split(/\r?\n/)
      .filter(Boolean);
    const containers = ids.length ? parseJsonOutput(run("docker", ["inspect", ...ids])) : [];
    const listenerResult = run("ss", ["-H", "-lnut"]);
    const { listeners, malformedLines } = parseSsListeners(listenerResult.stdout);
    const assessment = assessDockerRuntime({
      network,
      expectedNetworkName: name,
      expectedRunLabel: runLabel,
      projectId,
      containers,
      listeners,
      malformedListenerLines: malformedLines,
      requireInternal: false,
    });
    const result = applyStartupOutcome(assessment, startupOutcome);
    writeEvidence(evidencePath, {
      stage: "docker-port-bindings-before-integration",
      ...result,
    });
    console.log(
      `Disposable Docker port-binding gate ${result.status}${result.reason ? `: ${result.reason}` : ""}.`,
    );
    if (result.status !== "PASS") process.exitCode = 1;
  } catch {
    const result = applyStartupOutcome(
      { status: "FAIL", failure_codes: ["docker-runtime-inspection-failed"] },
      startupOutcome,
    );
    writeEvidence(evidencePath, {
      stage: "docker-port-bindings-before-integration",
      ...result,
    });
    console.error(
      `Disposable Docker port-binding gate ${result.status} (sanitized inspection failure).`,
    );
    process.exitCode = 1;
  }
}

export function cleanupOwnedNetwork(
  name,
  runLabel,
  markerPath,
  { docker = (args) => run("docker", args).stdout, stat = lstatSync } = {},
) {
  const fail = (code) => ({
    status: "FAIL",
    network_removed: false,
    failure_codes: [code],
  });
  let marker;
  try {
    const file = stat(markerPath);
    if (
      !file.isFile() ||
      file.uid !== 0 ||
      file.nlink !== 1 ||
      file.size > 1024 ||
      (file.mode & 0o222) !== 0
    ) {
      return fail("network-ownership-marker-invalid");
    }
    marker = JSON.parse(readFileSync(markerPath, "utf8"));
  } catch (error) {
    return fail(
      error.code === "ENOENT"
        ? "network-ownership-marker-missing"
        : "network-ownership-marker-invalid",
    );
  }
  if (
    !validName(name) ||
    !validName(runLabel) ||
    marker?.name !== name ||
    marker.run_label !== runLabel ||
    !/^[a-f0-9]{64}$/.test(marker.id ?? "")
  ) {
    return fail("network-ownership-marker-invalid");
  }

  const inventory = () =>
    docker(["network", "ls", "--format", "{{.Name}}"]).trim().split(/\r?\n/).filter(Boolean).sort();
  try {
    if (docker(["ps", "--all", "--quiet"]).trim()) return fail("private-daemon-containers-remain");
    const before = inventory();
    const ownedPresent = before.includes(name);
    if (
      before.join(",") !== (ownedPresent ? [name, "host", "none"].sort().join(",") : "host,none")
    ) {
      return fail("unexpected-private-network-inventory");
    }
    if (ownedPresent) {
      const [network] = JSON.parse(docker(["network", "inspect", name]));
      if (
        network?.Name !== name ||
        network.Id !== marker.id ||
        network.Labels?.[workflowLabel] !== runLabel
      ) {
        return fail("network-ownership-mismatch");
      }
      if (Object.keys(network.Containers ?? {}).length)
        return fail("owned-network-still-has-containers");
      docker(["network", "rm", marker.id]);
    }
    if (inventory().join(",") !== "host,none") return fail("network-removal-unverified");
    if (docker(["ps", "--all", "--quiet"]).trim()) return fail("private-daemon-containers-remain");
    return {
      status: "PASS",
      network_removed: true,
      removed_by: ownedPresent ? "workflow" : "supabase-stop-or-prior-cleanup",
      remaining_attached_containers: 0,
    };
  } catch {
    return fail("owned-network-cleanup-failed");
  }
}

function cleanupNetwork(name, markerPath, evidencePath, runLabel) {
  const result = cleanupOwnedNetwork(name, runLabel, markerPath);
  writeEvidence(evidencePath, result);
  if (result.status !== "PASS") {
    console.error(
      "Disposable Docker network cleanup FAIL (sanitized ownership or engine failure).",
    );
    process.exitCode = 1;
    return;
  }
  console.log("Disposable Docker network cleanup PASS (independent engine inventory).");
}

const [mode, networkName, third, fourth, fifth, sixth] = process.argv.slice(2);
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const owned = privateDockerIdentity(mode === "create" ? "provisioned" : "verified");
    const ownedMarker = process.env.CARECONNECT_ISOLATION_ROOT + "/ownership/network.json";
    if (
      networkName !== owned.project ||
      (mode === "create" && (third !== owned.run || fifth !== ownedMarker)) ||
      (mode === "verify" && fifth !== owned.run) ||
      (mode === "cleanup" && (fifth !== owned.run || third !== ownedMarker))
    )
      throw new Error("network ownership mismatch");
  } catch (error) {
    if (!reportServiceExecutionBlock(error)) {
      console.error("Disposable Docker network command refused (invalid ownership).");
      process.exitCode = 78;
    }
  }
  if (process.exitCode) {
    // Do not inspect or remove resources when the runtime identity is unknown.
  } else if (mode === "create") {
    await createNetwork(networkName, third, fourth, fifth);
  } else if (mode === "verify") {
    verifyRuntime(networkName, third, fourth, fifth, sixth);
  } else if (mode === "cleanup") {
    cleanupNetwork(networkName, third, fourth, fifth);
  } else {
    console.error(
      "Usage: create <network> <run-label> <evidence> <marker> | verify <network> <config> <evidence> <run-label> <startup-outcome> | cleanup <network> <marker> <evidence> <run-label>",
    );
    process.exitCode = 2;
  }
}
