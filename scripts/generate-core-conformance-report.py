#!/usr/bin/env python3
"""Run the Dart Core corpus replay and emit its observed qualification report.

Every child process this generator starts is bounded and owned:

- The Dart SDK is resolved by probing `dart --version` under a short timeout
  before any replay starts. A `dart` on PATH that never exits (a wrapper that
  `exec`s itself, as the AUR flutter package's `/usr/sbin/dart` does when its
  unionfs mount fails) or that exits 0 without an SDK banner is rejected with
  a diagnostic instead of silently consuming the verifier's whole per-command
  budget (#lzcoreevidencedarttimeout). `DART=/path/to/dart` pins the SDK and is
  never second-guessed by a PATH fallback.
- Each runner invocation runs in its own session and gets a timeout no larger
  than the budget the verifier still has left (`LAZILY_CORE_COMMAND_TIMEOUT_MS`).
  On timeout the WHOLE process group is killed, so a hung `dart test` cannot
  outlive the generator.
- SIGTERM (what the verifier sends when its own timeout fires) is turned into
  an orderly abort: the active process group is killed and the scratch
  directory under build/ is removed.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
BINDING_ID = "dart"
WHOLE_FIXTURE_SKIP = "reactive-graph/feedback_drain_bound_reports_exhaustion.json"
MODELS = ("Context", "ThreadSafeContext", "AsyncContext")
DART_VERSION_BANNER = re.compile(r"Dart SDK version: (\S+)")
# A real `dart --version` answers in well under a second even on a loaded host.
DEFAULT_PROBE_TIMEOUT_S = 10.0
# One corpus replay takes ~1-2s warm; the first one also compiles the suite.
DEFAULT_RUN_TIMEOUT_S = 300.0
# Leave the generator time to report a precise diagnostic before the verifier's
# own (blind) timeout fires.
BUDGET_MARGIN_S = 5.0
# How long to keep draining pipes after the group has been SIGKILLed.
PIPE_DRAIN_TIMEOUT_S = 5.0


class CommandTimeout(Exception):
    def __init__(self, label: str, timeout_s: float, output: str) -> None:
        super().__init__(f"{label} did not exit within {timeout_s:.1f}s")
        self.label = label
        self.timeout_s = timeout_s
        self.output = output


class Terminated(BaseException):
    """Raised from the SIGTERM handler so `finally` blocks and context managers run."""


def _on_sigterm(signum: int, _frame: object) -> None:
    raise Terminated(signum)


def env_seconds(env: dict[str, str], name: str, default: float) -> float:
    raw = env.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"{name} must be a positive number of seconds, got {raw!r}") from None
    if not value > 0:
        raise SystemExit(f"{name} must be a positive number of seconds, got {raw!r}")
    return value


class Budget:
    """Wall-clock budget derived from the verifier's per-command timeout."""

    def __init__(self, total_ms: str | None, run_cap_s: float, clock=time.monotonic) -> None:
        self._clock = clock
        self.run_cap_s = run_cap_s
        self.deadline: float | None = None
        if total_ms:
            try:
                total = int(total_ms)
            except ValueError:
                raise SystemExit(f"LAZILY_CORE_COMMAND_TIMEOUT_MS must be an integer, got {total_ms!r}") from None
            if total <= 0:
                raise SystemExit(f"LAZILY_CORE_COMMAND_TIMEOUT_MS must be positive, got {total_ms!r}")
            self.deadline = clock() + total / 1000 - BUDGET_MARGIN_S

    def timeout_for(self, label: str, cap_s: float | None = None) -> float:
        cap = self.run_cap_s if cap_s is None else cap_s
        if self.deadline is None:
            return cap
        remaining = self.deadline - self._clock()
        if remaining <= 0:
            raise SystemExit(f"Core report budget exhausted before {label}")
        return min(cap, remaining)


def kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    # The leader too, in case it was never a group leader: a wait on it must
    # always terminate.
    if proc.poll() is None:
        proc.kill()


def run_bounded(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout_s: float,
    label: str,
) -> subprocess.CompletedProcess[str]:
    """Run `command` in its own session; kill the whole group on timeout or abort."""
    proc = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    finished = False
    try:
        try:
            stdout, stderr = proc.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            kill_group(proc)
            try:
                stdout, stderr = proc.communicate(timeout=PIPE_DRAIN_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                # A descendant left our process group (setsid/daemonized) and
                # still holds the pipes. The leader is dead; stop waiting on it.
                for pipe in (proc.stdout, proc.stderr):
                    if pipe is not None:
                        pipe.close()
                proc.wait()
                stdout, stderr = "", "<output pipes held open by an escaped descendant>"
            finished = True
            raise CommandTimeout(label, timeout_s, (stdout or "") + (stderr or "")) from None
        finished = True
        return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
    finally:
        if not finished:
            # Aborted mid-run (SIGTERM, KeyboardInterrupt): the leader is not yet
            # reaped, so its pid still names the group we started.
            kill_group(proc)
            proc.wait()


@dataclass(frozen=True)
class DartSdk:
    executable: str
    resolved: str
    version: str
    rejected: tuple[str, ...] = ()


def dart_candidates(env: dict[str, str]) -> list[str]:
    seen: set[str] = set()
    candidates: list[str] = []
    for entry in env.get("PATH", "").split(os.pathsep):
        if not entry:
            continue
        candidate = Path(entry) / "dart"
        if not (candidate.is_file() and os.access(candidate, os.X_OK)):
            continue
        resolved = str(candidate.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        candidates.append(str(candidate))
    return candidates


def resolve_dart(env: dict[str, str], budget: Budget) -> DartSdk:
    probe_cap = env_seconds(env, "LAZILY_DART_PROBE_TIMEOUT_S", DEFAULT_PROBE_TIMEOUT_S)
    explicit = env.get("DART")
    candidates = [explicit] if explicit else dart_candidates(env)
    if not candidates:
        raise SystemExit("no `dart` executable on PATH; set DART=/path/to/dart")
    rejected: list[str] = []
    for candidate in candidates:
        label = f"`{candidate} --version`"
        try:
            result = run_bounded(
                [candidate, "--version"],
                cwd=ROOT,
                env=env,
                timeout_s=budget.timeout_for(label, probe_cap),
                label=label,
            )
        except CommandTimeout as timeout:
            rejected.append(f"{candidate}: {timeout} (output tail {timeout.output[-120:]!r})")
            continue
        except OSError as error:
            rejected.append(f"{candidate}: {error}")
            continue
        output = result.stdout + result.stderr
        banner = DART_VERSION_BANNER.search(output)
        if result.returncode == 0 and banner:
            for reason in rejected:
                print(f"dart: skipped unusable candidate {reason}", file=sys.stderr, flush=True)
            return DartSdk(
                candidate, str(Path(candidate).resolve()), banner.group(0), tuple(rejected)
            )
        rejected.append(
            f"{candidate}: exit {result.returncode} without a Dart SDK banner "
            f"(output tail {output[-120:]!r})"
        )
    source = "DART" if explicit else "PATH"
    raise SystemExit(
        f"no usable Dart SDK from {source}; rejected: " + "; ".join(rejected)
        + ("" if explicit else ". Set DART=/path/to/dart to pin one.")
    )


def required_env(name: str) -> Path:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required")
    return Path(value).resolve()


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def pointer_token(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def assertion_routes(spec_root: Path, required: set[str]) -> dict[str, list[str]]:
    schema = load_json(spec_root / "schemas" / "assertion-blocks.json")
    routes = {fixture: [] for fixture in required}
    for route in schema["x-fixture-routes"]:
        fixture = route["fixture"]
        if fixture in routes:
            routes[fixture].append(route["pointer"])
    missing = sorted(fixture for fixture, pointers in routes.items() if not pointers)
    if missing:
        raise SystemExit(f"Core fixtures have no assertion routes: {', '.join(missing)}")
    return routes


def evidence_reference(route: str, fixture: str) -> str:
    return (
        f"{BINDING_ID}/core-conformance-evidence.json#/fixtures/"
        f"{pointer_token(fixture)}/assertion_blocks/{pointer_token(route)}"
    )


def route_targets(document: object, route: str) -> list[tuple[object, list[str]]]:
    """Resolve the assertion-route subset of JSON Pointer (`*` is an array wildcard)."""
    states: list[tuple[object, list[str]]] = [(document, [])]
    for token in route.removeprefix("/").split("/"):
        next_states: list[tuple[object, list[str]]] = []
        for value, pointer in states:
            if token == "*":
                if isinstance(value, list):
                    next_states.extend((item, pointer + [str(i)]) for i, item in enumerate(value))
                elif isinstance(value, dict):
                    next_states.extend((item, pointer + [key]) for key, item in value.items())
            elif isinstance(value, dict) and token in value:
                next_states.append((value[token], pointer + [token]))
        states = next_states
    return states


NON_ASSERTION_KEYS = {"note", "description", "prose", "op", "observationally_equal"}
MAX_MUTANTS_PER_ROUTE = 8
# A mutant only counts as killed when the runner rejected it through its library
# divergence report: test/reactive_graph_conformance_test.dart writes one
# `DIVERGENCE <model>/<fixture>...#<step>:<key> — got X, want Y` line per check
# whose observed library value disagreed with the (mutated) expectation, then
# fails the divergence ledger. Any other non-zero exit (a StateError on a renamed
# scenario label, an unknown node id, an unconsumed key) proves the runner READ
# the leaf, not that the assertion over the library discriminates, so it is
# recorded as non-discriminating and the next leaf is tried.
DIVERGENCE_LINE = re.compile(
    r"^\s*DIVERGENCE (?:Context|ThreadSafeContext|AsyncContext)/"
    r"(?P<fixture>[^\s#\[]+)(?:\[\d+\])?#\S+ \S+ got .*, want .*$",
    re.MULTILINE,
)


def assertion_leaves(value: object, pointer: list[str]) -> list[tuple[object, object, str]]:
    """Every comparable scalar assertion leaf, in document order, ignoring prose
    annotations, op inputs and scenario labels."""
    if isinstance(value, dict):
        children = [(key, child) for key, child in value.items() if key not in NON_ASSERTION_KEYS]
    elif isinstance(value, list):
        children = list(enumerate(value))
    else:
        return []
    leaves: list[tuple[object, object, str]] = []
    for key, child in children:
        if mutated_scalar(child) is not None:
            json_pointer = "/" + "/".join(pointer_token(token) for token in pointer + [str(key)])
            leaves.append((value, key, json_pointer))
        else:
            leaves.extend(assertion_leaves(child, pointer + [str(key)]))
    return leaves


def route_leaves(document: object, route: str) -> list[tuple[object, object, str]]:
    return [
        leaf
        for target, pointer in route_targets(document, route)
        for leaf in assertion_leaves(target, pointer)
    ]


def divergence_lines(output: str, fixture_name: str) -> list[str]:
    """The runner's library-divergence lines that name `fixture_name`."""
    return [
        match.group(0).strip()
        for match in DIVERGENCE_LINE.finditer(output)
        if match.group("fixture") == fixture_name
    ]


def failure_excerpt(output: str) -> list[str]:
    lines = [line.strip() for line in output.splitlines() if "Error" in line or "Bad state" in line]
    return lines[:3] if lines else output.strip().splitlines()[-3:]


def kill_route(
    command: list[str],
    mutation_root: Path,
    fixture: str,
    route: str,
    control_id: str,
    control_dir: Path,
    budget: "Budget",
) -> dict:
    """Mutate one assertion leaf at a time until a library divergence rejects it."""
    fixture_path = mutation_root / fixture
    canonical = fixture_path.read_text(encoding="utf-8")
    pristine = json.loads(canonical)
    if not route_targets(pristine, route):
        raise SystemExit(f"negative control route {route} did not resolve in {fixture}")
    leaf_count = len(route_leaves(pristine, route))
    if leaf_count == 0:
        raise SystemExit(f"negative control route {route} has no comparable leaf in {fixture}")
    not_discriminating: list[dict] = []
    for attempt in range(min(leaf_count, MAX_MUTANTS_PER_ROUTE)):
        # A fresh parse per attempt: exactly one leaf differs from the corpus.
        document = json.loads(canonical)
        container, key, pointer = route_leaves(document, route)[attempt]
        original = container[key]
        mutated = mutated_scalar(original)
        container[key] = mutated
        attempt_dir = control_dir / str(attempt)
        attempt_dir.mkdir(parents=True)
        fixture_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
        try:
            rejected, _, _, _ = run_runner(
                command,
                mutation_root,
                f"{control_id}-{attempt}",
                attempt_dir,
                budget,
                f"negative control {fixture} {route} {pointer}",
            )
        finally:
            fixture_path.write_text(canonical, encoding="utf-8")
        if rejected.returncode == 0:
            raise SystemExit(f"negative control survived for {fixture} {route} at {pointer}")
        output = rejected.stdout + rejected.stderr
        divergences = divergence_lines(output, Path(fixture).name)
        if divergences:
            return {
                "status": "mutation-killed",
                "route": route,
                "mutated_pointer": pointer,
                "original": original,
                "mutated": mutated,
                "runner_exit_code": rejected.returncode,
                "rejected_by": "divergence",
                "rejection_excerpt": divergences[:3],
                "non_discriminating_mutants": not_discriminating,
            }
        not_discriminating.append(
            {
                "mutated_pointer": pointer,
                "original": original,
                "mutated": mutated,
                "runner_exit_code": rejected.returncode,
                "rejected_by": "other_failure",
                "rejection_excerpt": failure_excerpt(output),
            }
        )
    raise SystemExit(
        f"no mutated assertion leaf of {fixture} {route} was rejected by a library divergence "
        f"({len(not_discriminating)} mutant(s) failed for another reason: "
        f"{[item['mutated_pointer'] for item in not_discriminating]})"
    )


def mutated_scalar(value: object) -> object | None:
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value + 1_000_003
    if isinstance(value, float):
        return value + 1_000_003.25
    if isinstance(value, str):
        return value + "__lazily_negative_control__"
    return None


def run_runner(
    command: list[str],
    spec_dir: Path,
    run_id: str,
    ledger_dir: Path,
    budget: Budget,
    label: str,
) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
    fixtures_path = ledger_dir / "fixtures.txt"
    scenarios_path = ledger_dir / "scenarios.txt"
    blocks_path = ledger_dir / "blocks.txt"
    for path in (fixtures_path, scenarios_path, blocks_path):
        path.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "LAZILY_SPEC_CONFORMANCE_DIR": str(spec_dir),
            "LAZILY_CONFORMANCE_RUN_ID": run_id,
            "LAZILY_CONFORMANCE_MANIFEST": str(fixtures_path),
            "LAZILY_CONFORMANCE_SCENARIOS": str(scenarios_path),
            "LAZILY_CONFORMANCE_BLOCKS": str(blocks_path),
        }
    )
    try:
        result = run_bounded(
            command, cwd=ROOT, env=env, timeout_s=budget.timeout_for(label), label=label
        )
    except CommandTimeout as timeout:
        raise SystemExit(f"{timeout}; output tail:\n{timeout.output[-2000:]}") from None
    return (
        result,
        fixtures_path.read_text(encoding="utf-8"),
        scenarios_path.read_text(encoding="utf-8"),
        blocks_path.read_text(encoding="utf-8"),
    )


def main() -> int:
    profile_path = required_env("LAZILY_CORE_PROFILE_PATH")
    spec_root = required_env("LAZILY_CORE_SPEC_ROOT")
    reports_root = required_env("LAZILY_CORE_REPORTS_ROOT")
    report_path = required_env("LAZILY_CORE_REPORT_PATH")
    binding_id = os.environ.get("LAZILY_CORE_BINDING_ID", BINDING_ID)
    if binding_id != BINDING_ID:
        raise SystemExit(f"expected binding id {BINDING_ID!r}, got {binding_id!r}")

    profile = load_json(profile_path)
    binding = next(item for item in profile["bindings"] if item["id"] == BINDING_ID)
    required = set(binding["required_fixtures"])
    routes = assertion_routes(spec_root, required)
    declaration = load_json(ROOT / "scripts" / "core-conformance.json")
    run_id = f"core-{time.time_ns()}-{os.getpid()}"
    started = time.monotonic()
    budget = Budget(
        os.environ.get("LAZILY_CORE_COMMAND_TIMEOUT_MS"),
        env_seconds(dict(os.environ), "LAZILY_DART_RUN_TIMEOUT_S", DEFAULT_RUN_TIMEOUT_S),
    )
    dart = resolve_dart(dict(os.environ), budget)
    print(f"dart: {dart.executable} -> {dart.resolved} ({dart.version})", flush=True)

    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lazily-dart-core-", dir=ROOT / "build") as raw_tmp:
        tmp = Path(raw_tmp)
        command = [
            dart.executable,
            "test",
            "test/reactive_graph_conformance_test.dart",
        ]
        result, fixture_ledger, scenario_ledger, block_ledger = run_runner(
            command, spec_root / "conformance", run_id, tmp, budget, "baseline Core replay"
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            return result.returncode

        mutation_root = tmp / "negative-control-corpus"
        shutil.copytree(spec_root / "conformance", mutation_root)
        negative_controls: dict[str, dict[str, dict]] = {}
        for fixture in sorted(required - {WHOLE_FIXTURE_SKIP}):
            negative_controls[fixture] = {}
            for index, route in enumerate(routes[fixture]):
                negative_controls[fixture][route] = kill_route(
                    command,
                    mutation_root,
                    fixture,
                    route,
                    f"{run_id}-negative-{len(negative_controls)}-{index}",
                    tmp / f"negative-{len(negative_controls)}-{index}",
                    budget,
                )

    absent = sorted(path for path in required if path not in fixture_ledger)
    if absent:
        raise SystemExit(f"Core runner did not open required fixtures: {', '.join(absent)}")
    combined_output = result.stdout + result.stderr
    for fixture in sorted(required - {WHOLE_FIXTURE_SKIP}):
        name = Path(fixture).name
        for model in MODELS:
            marker = f"reactive-graph[{model}] {name}:"
            if marker not in combined_output:
                raise SystemExit(f"Core runner did not prove {fixture} on {model}")
    skip_name = Path(WHOLE_FIXTURE_SKIP).name
    for model in MODELS:
        if f"reactive-graph[{model}] SKIP {skip_name}" not in combined_output:
            raise SystemExit(f"Core runner did not report the declared {model} skip for {WHOLE_FIXTURE_SKIP}")

    evidence_path = reports_root / BINDING_ID / "core-conformance-evidence.json"
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence = {
        "schema_version": 1,
        "binding_id": BINDING_ID,
        "run_id": run_id,
        "command": command,
        "toolchain": {
            "dart": dart.executable,
            "resolved": dart.resolved,
            "version": dart.version,
            "rejected_candidates": list(dart.rejected),
        },
        "elapsed_ms": round((time.monotonic() - started) * 1000),
        "exit_code": result.returncode,
        "fixtures": {},
        "runtime_ledgers": {
            "fixtures": fixture_ledger.splitlines(),
            "scenarios": scenario_ledger.splitlines(),
            "assertion_blocks": block_ledger.splitlines(),
        },
        "negative_controls": negative_controls,
    }

    fixtures = []
    definitions = {item["path"]: item for item in profile["required_fixtures"]}
    for fixture in binding["required_fixtures"]:
        definition = definitions[fixture]
        skipped = fixture == WHOLE_FIXTURE_SKIP
        evidence_blocks = (
            {}
            if skipped
            else {
                route: {
                    "status": "mutation-killed",
                    "mechanism": "runtime comparison to the canonical fixture expectation with unconsumed-key guards",
                    "negative_control": negative_controls[fixture][route],
                    "runner_exit_code": result.returncode,
                    "run_id": run_id,
                }
                for route in routes[fixture]
            }
        )
        evidence["fixtures"][fixture] = {
            "status": "skipped" if skipped else "passed",
            "models": list(MODELS),
            "assertion_blocks": {} if skipped else evidence_blocks,
        }
        fixtures.append(
            {
                "path": fixture,
                "scenario_ids": [] if skipped else definition["scenario_ids"],
                "proof_classes": definition["proof_classes"],
                "assertion_blocks": []
                if skipped
                else [
                    {
                        "id": route,
                        "consumed": True,
                        "discriminability_evidence": evidence_reference(route, fixture),
                    }
                    for route in routes[fixture]
                ],
                "status": "skipped" if skipped else "passed",
            }
        )

    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    report = {
        "schema_version": 1,
        "profile_id": profile["profile_id"],
        "binding_id": BINDING_ID,
        "fixture_corpus_digest": profile["fixture_corpus"]["digest"],
        "fixtures": fixtures,
        "runtime_skips": declaration["runtime_skips"],
        "fixtureless_claims": [],
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {report_path} ({len(fixtures) - 1} passed, 1 skipped)")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        raise SystemExit(main())
    except Terminated:
        print("Core report generation terminated; child process group killed", file=sys.stderr)
        raise SystemExit(128 + signal.SIGTERM) from None
