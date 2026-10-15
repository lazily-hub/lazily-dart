#!/usr/bin/env python3
"""Deterministic timeout/ownership checks for generate-core-conformance-report.py.

The Core verifier gives a report command one blind per-command timeout and
SIGTERMs only the direct child when it fires. #lzcoreevidencedarttimeout was a
`dart` on PATH (the AUR flutter wrapper) that `exec`s itself forever when its
unionfs mount fails, so the generator never ran a single fixture and the
verifier waited out its whole 600000ms budget. These checks pin the generator's
own guarantees with fake `dart` executables, so no outcome depends on the host
toolchain, on scheduling, or on how fast the real suite is:

- a self-exec'ing or banner-less `dart` is rejected by a bounded probe and the
  next PATH candidate is used; an explicit DART is never second-guessed;
- a timed-out child takes its whole process group with it;
- the verifier's budget bounds every runner invocation, with a diagnostic that
  names the phase that ran out;
- SIGTERM from the verifier kills the running group and removes the scratch
  directory under build/.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

# Importing the generator must not leave scripts/__pycache__ in the checkout.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "generate-core-conformance-report.py"

spec = importlib.util.spec_from_file_location("dart_core_report", GENERATOR)
generator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = generator
spec.loader.exec_module(generator)

# Upper bound for kernel-side reaping after SIGKILL; outcomes never depend on it.
REAP_BOUND_S = 5.0


def write_executable(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def process_gone(pid: int) -> bool:
    """True once `pid` has exited (absent, or a zombie awaiting its reaper)."""
    deadline = time.monotonic() + REAP_BOUND_S
    while True:
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            return True
        if fields[0] == "Z":
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)


def wait_for_file(path: Path, bound_s: float = 30.0) -> str:
    deadline = time.monotonic() + bound_s
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return path.read_text().strip()
        time.sleep(0.02)
    raise AssertionError(f"{path} never appeared")


# The AUR flutter wrapper's failure mode: report, then exec `dart` from PATH,
# which resolves back to this same file.
SELF_EXEC_DART = '#!/bin/sh\necho "unionfs failed"\nexec dart "$@"\n'
BANNERLESS_DART = "#!/bin/sh\nexit 0\n"
REAL_DART = '#!/bin/sh\necho "Dart SDK version: 9.9.9 (stable) (fake) on \\"linux_x64\\""\n'


def hanging_dart(pid_file: Path, ledger_note: Path | None = None) -> str:
    note = (
        f'dirname "$LAZILY_CONFORMANCE_MANIFEST" > "{ledger_note}"\n' if ledger_note else ""
    )
    return (
        "#!/bin/sh\n"
        'if [ "$1" = "--version" ]; then\n'
        '  echo "Dart SDK version: 9.9.9 (stable) (fake)"\n'
        "  exit 0\n"
        "fi\n"
        f"{note}"
        "sleep 1000 &\n"
        f'echo $! > "{pid_file}"\n'
        "wait\n"
    )


class Budgeted:
    def __init__(self, cap_s: float = 30.0) -> None:
        self.budget = generator.Budget(None, cap_s)


class ResolveDartTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="dart-core-report-test-")
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def env(self, *dirs: Path, **extra: str) -> dict[str, str]:
        env = {
            # Only the fakes: the host's own `dart` (possibly the very wrapper
            # this guards against) must not decide any outcome here.
            "PATH": os.pathsep.join(str(d) for d in dirs),
            "LAZILY_DART_PROBE_TIMEOUT_S": "1",
        }
        env.update(extra)
        return env

    def test_self_exec_wrapper_and_bannerless_dart_are_skipped(self) -> None:
        looping = self.root / "looping"
        bannerless = self.root / "bannerless"
        real = self.root / "real"
        write_executable(looping / "dart", SELF_EXEC_DART)
        write_executable(bannerless / "dart", BANNERLESS_DART)
        write_executable(real / "dart", REAL_DART)
        started = time.monotonic()
        sdk = generator.resolve_dart(self.env(looping, bannerless, real), Budgeted().budget)
        self.assertEqual(sdk.executable, str(real / "dart"))
        self.assertEqual(sdk.version, "Dart SDK version: 9.9.9")
        self.assertEqual(len(sdk.rejected), 2)
        self.assertIn("did not exit within 1.0s", sdk.rejected[0])
        self.assertIn("without a Dart SDK banner", sdk.rejected[1])
        # One bounded probe, not the verifier's whole budget.
        self.assertLess(time.monotonic() - started, 10.0)

    def test_symlinked_duplicates_are_probed_once(self) -> None:
        looping = self.root / "looping"
        alias = self.root / "alias"
        write_executable(looping / "dart", SELF_EXEC_DART)
        alias.mkdir()
        (alias / "dart").symlink_to(looping / "dart")
        self.assertEqual(
            generator.dart_candidates(self.env(looping, alias)),
            [str(looping / "dart")],
        )

    def test_only_unusable_candidates_fail_closed_with_every_reason(self) -> None:
        looping = self.root / "looping"
        bannerless = self.root / "bannerless"
        write_executable(looping / "dart", SELF_EXEC_DART)
        write_executable(bannerless / "dart", BANNERLESS_DART)
        with self.assertRaises(SystemExit) as raised:
            generator.resolve_dart(self.env(looping, bannerless), Budgeted().budget)
        message = str(raised.exception)
        self.assertIn("no usable Dart SDK from PATH", message)
        self.assertIn("did not exit within 1.0s", message)
        self.assertIn("unionfs failed", message)
        self.assertIn("exit 0 without a Dart SDK banner", message)
        self.assertIn("DART=", message)

    def test_explicit_dart_is_not_second_guessed(self) -> None:
        looping = self.root / "looping"
        real = self.root / "real"
        write_executable(looping / "dart", SELF_EXEC_DART)
        write_executable(real / "dart", REAL_DART)
        env = self.env(looping, real, DART=str(looping / "dart"))
        with self.assertRaises(SystemExit) as raised:
            generator.resolve_dart(env, Budgeted().budget)
        self.assertIn("no usable Dart SDK from DART", str(raised.exception))
        self.assertNotIn(str(real / "dart"), str(raised.exception))


class RunBoundedTest(unittest.TestCase):
    def test_timeout_kills_the_whole_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dart-core-report-test-") as raw:
            pid_file = Path(raw) / "grandchild.pid"
            command = ["/bin/sh", "-c", f'sleep 1000 & echo $! > "{pid_file}"; wait']
            with self.assertRaises(generator.CommandTimeout) as raised:
                generator.run_bounded(
                    command, cwd=Path(raw), env=dict(os.environ), timeout_s=0.5, label="probe"
                )
            self.assertEqual(raised.exception.label, "probe")
            grandchild = int(pid_file.read_text())
            gone = process_gone(grandchild)
            if not gone:
                os.kill(grandchild, signal.SIGKILL)
            self.assertTrue(gone, "grandchild outlived timeout")


class BudgetTest(unittest.TestCase):
    def test_runs_are_capped_by_the_remaining_verifier_budget(self) -> None:
        now = [100.0]
        budget = generator.Budget("60000", 300.0, clock=lambda: now[0])
        # 60s budget minus the reporting margin.
        self.assertEqual(budget.timeout_for("baseline"), 60.0 - generator.BUDGET_MARGIN_S)
        self.assertEqual(budget.timeout_for("probe", 10.0), 10.0)
        now[0] += 50.0
        self.assertEqual(budget.timeout_for("control"), 5.0)
        now[0] += 10.0
        with self.assertRaises(SystemExit) as raised:
            budget.timeout_for("negative control reactive-graph/a.json /steps/*/expect")
        self.assertIn("budget exhausted before negative control", str(raised.exception))

    def test_without_a_verifier_budget_only_the_run_cap_applies(self) -> None:
        budget = generator.Budget(None, 300.0, clock=lambda: 0.0)
        self.assertEqual(budget.timeout_for("baseline"), 300.0)

    def test_malformed_budget_is_rejected(self) -> None:
        for raw in ("0", "-5", "soon"):
            with self.assertRaises(SystemExit):
                generator.Budget(raw, 300.0)


class GeneratorProcessTest(unittest.TestCase):
    """Run the real generator script against a hanging fake `dart test`."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="dart-core-report-test-")
        self.root = Path(self.tmp.name)
        spec_root = self.root / "spec"
        (spec_root / "schemas").mkdir(parents=True)
        (spec_root / "conformance" / "reactive-graph").mkdir(parents=True)
        fixture = "reactive-graph/a.json"
        (spec_root / "conformance" / fixture).write_text('{"steps": []}\n')
        (spec_root / "schemas" / "assertion-blocks.json").write_text(
            json.dumps({"x-fixture-routes": [{"fixture": fixture, "pointer": "/steps/*/expect"}]})
        )
        profile = self.root / "profile.json"
        profile.write_text(
            json.dumps(
                {
                    "profile_id": "core-v1",
                    "bindings": [{"id": "dart", "required_fixtures": [fixture]}],
                    "required_fixtures": [],
                }
            )
        )
        self.pid_file = self.root / "grandchild.pid"
        self.ledger_note = self.root / "ledger-dir.txt"
        dart = write_executable(
            self.root / "bin" / "dart", hanging_dart(self.pid_file, self.ledger_note)
        )
        self.env = dict(os.environ)
        self.env.update(
            {
                "DART": str(dart),
                "LAZILY_CORE_PROFILE_PATH": str(profile),
                "LAZILY_CORE_SPEC_ROOT": str(spec_root),
                "LAZILY_CORE_REPORTS_ROOT": str(self.root / "reports"),
                "LAZILY_CORE_REPORT_PATH": str(self.root / "reports" / "dart.json"),
                "LAZILY_CORE_BINDING_ID": "dart",
            }
        )

    def tearDown(self) -> None:
        # Only reached with live children when a regression is under test;
        # never leave the fake runner's grandchild behind either way.
        if self.pid_file.exists() and self.pid_file.read_text().strip():
            try:
                os.kill(int(self.pid_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.tmp.cleanup()

    def assert_owned_state_released(self) -> None:
        self.assertTrue(process_gone(int(self.pid_file.read_text())), "dart test outlived the generator")
        scratch = Path(self.ledger_note.read_text().strip())
        self.assertTrue(scratch.is_relative_to(ROOT / "build"), scratch)
        self.assertFalse(scratch.exists(), f"scratch directory survived: {scratch}")
        self.assertFalse((self.root / "reports" / "dart.json").exists())

    def test_budget_exhaustion_fails_fast_with_the_phase_named(self) -> None:
        env = dict(self.env, LAZILY_CORE_COMMAND_TIMEOUT_MS=str(int((generator.BUDGET_MARGIN_S + 1) * 1000)))
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, str(GENERATOR)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=60,
        )
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("baseline Core replay did not exit within", result.stderr)
        # Finished inside the verifier's budget, so the verifier's own blind
        # timeout never has to fire.
        self.assertLess(elapsed, generator.BUDGET_MARGIN_S + 1)
        self.assert_owned_state_released()

    def test_sigterm_kills_the_runner_group_and_removes_scratch(self) -> None:
        proc = subprocess.Popen(
            [sys.executable, str(GENERATOR)],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            wait_for_file(self.pid_file)
            proc.send_signal(signal.SIGTERM)
            _, stderr = proc.communicate(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        self.assertEqual(proc.returncode, 128 + signal.SIGTERM, stderr)
        self.assertIn("terminated; child process group killed", stderr)
        self.assert_owned_state_released()


if __name__ == "__main__":
    unittest.main(verbosity=2)
