#!/usr/bin/env python3
"""Run the Dart Core corpus replay and emit its observed qualification report."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
BINDING_ID = "dart"
WHOLE_FIXTURE_SKIP = "reactive-graph/feedback_drain_bound_reports_exhaustion.json"
MODELS = ("Context", "ThreadSafeContext", "AsyncContext")


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


def mutate_assertion(value: object, pointer: list[str]) -> tuple[str, object, object] | None:
    """Mutate the first comparable assertion leaf, ignoring prose annotations."""
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"note", "description", "prose", "op", "observationally_equal"}:
                continue
            mutated = mutated_scalar(child)
            if mutated is not None:
                value[key] = mutated
                json_pointer = "/" + "/".join(pointer_token(token) for token in pointer + [key])
                return json_pointer, child, mutated
            mutation = mutate_assertion(child, pointer + [key])
            if mutation is not None:
                return mutation
        return None
    if isinstance(value, list):
        for i, child in enumerate(value):
            mutated = mutated_scalar(child)
            if mutated is not None:
                value[i] = mutated
                json_pointer = "/" + "/".join(pointer_token(token) for token in pointer + [str(i)])
                return json_pointer, child, mutated
            mutation = mutate_assertion(child, pointer + [str(i)])
            if mutation is not None:
                return mutation
        return None


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


def run_runner(command: list[str], spec_dir: Path, run_id: str, ledger_dir: Path) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
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
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
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

    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lazily-dart-core-", dir=ROOT / "build") as raw_tmp:
        tmp = Path(raw_tmp)
        command = [
            os.environ.get("DART", "dart"),
            "test",
            "test/reactive_graph_conformance_test.dart",
        ]
        result, fixture_ledger, scenario_ledger, block_ledger = run_runner(
            command, spec_root / "conformance", run_id, tmp
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            return result.returncode

        mutation_root = tmp / "negative-control-corpus"
        shutil.copytree(spec_root / "conformance", mutation_root)
        negative_controls: dict[str, dict[str, dict]] = {}
        for fixture in sorted(required - {WHOLE_FIXTURE_SKIP}):
            fixture_path = mutation_root / fixture
            canonical = fixture_path.read_text(encoding="utf-8")
            negative_controls[fixture] = {}
            for index, route in enumerate(routes[fixture]):
                document = json.loads(canonical)
                targets = route_targets(document, route)
                if not targets:
                    raise SystemExit(f"negative control route {route} did not resolve in {fixture}")
                mutation = next(
                    (
                        found
                        for target, pointer in targets
                        if (found := mutate_assertion(target, pointer)) is not None
                    ),
                    None,
                )
                if mutation is None:
                    raise SystemExit(f"negative control route {route} has no comparable leaf in {fixture}")
                pointer, original, mutated = mutation
                fixture_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
                control_id = f"{run_id}-negative-{len(negative_controls)}-{index}"
                control_dir = tmp / f"negative-{len(negative_controls)}-{index}"
                control_dir.mkdir()
                rejected, _, _, _ = run_runner(command, mutation_root, control_id, control_dir)
                fixture_path.write_text(canonical, encoding="utf-8")
                output = rejected.stdout + rejected.stderr
                if rejected.returncode == 0:
                    raise SystemExit(f"negative control survived for {fixture} {route} at {pointer}")
                if Path(fixture).name not in output:
                    raise SystemExit(
                        f"negative control rejection did not identify {fixture} {route}:\n"
                        + output[-4000:]
                    )
                matching = [line.strip() for line in output.splitlines() if Path(fixture).name in line]
                negative_controls[fixture][route] = {
                    "status": "mutation-killed",
                    "route": route,
                    "mutated_pointer": pointer,
                    "original": original,
                    "mutated": mutated,
                    "runner_exit_code": rejected.returncode,
                    "rejection_excerpt": matching[-3:],
                }

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
    raise SystemExit(main())
