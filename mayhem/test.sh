#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Khayyam's own test suite (deps already installed by mayhem/build.sh) and
# emit a CTRF (ctrf.io) summary. exit 0 iff failed==0. PATCH-grade oracle: a no-op patch that
# neuters the library breaks the suite's behavioral assertions, so it FAILS here (anti-reward-hacking).
#
# It does NOT compile — build.sh installed pytest + atheris into the in-image site dir and compiled
# the khayyam_run_tests ELF wrapper. We only RUN the suite, routed through that compiled NON-system
# wrapper so the gate's sabotage check (neuter non-system binaries to exit(0)) actually perturbs the
# run (the CPython interpreter under /usr/bin would otherwise be spared).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

# Put the in-image site dir (atheris + pytest + rtl) and the Khayyam source on PYTHONPATH.
PY_PREFIX=/opt/toolchains/python
# shellcheck disable=SC1091
[ -f "$PY_PREFIX/env.sh" ] && source "$PY_PREFIX/env.sh"
export PYTHONPATH="$PY_PREFIX/site:$SRC${PYTHONPATH:+:$PYTHONPATH}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/khayyam_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# Two upstream tests assert a wall-clock-DEPENDENT result: khayyam's %y (2-digit-year) parse infers
# the century from JalaliDate.today() (year.py:17 — `today().year//100*100 + shortyear`). The tests
# hard-code expectations from the authoring era (Jalali 13xx → "94" == 1394); run in Jalali 14xx
# (Gregorian 2026) the same code returns 1494, so they fail purely because of the clock, not because
# the library regressed. They are therefore NOT stable behavioral assertions — deselect them so the
# oracle is deterministic on the known-good baseline. All 70 other assertions (incl. the C-extension
# known-answer tests) remain the behavioral oracle.
DESELECT=(
  --deselect "khayyam/tests/test_jalali_date_formatter.py::JalaliDateFormatterTestCase::test_year"
  --deselect "khayyam/tests/test_jalali_datetime_formatter.py::JalaliDatetimeFormatterTestCase::test_locale_date_time"
)

# Run the suite. -p no:cacheprovider keeps the read-only image happy; khayyam/tests is the suite.
LOG="$(mktemp)"
"$RUNNER" -p no:cacheprovider -o addopts= -q "${DESELECT[@]}" khayyam/tests/ 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Parse pytest's summary line, e.g. "6 passed in 0.4s" / "1 failed, 5 passed in ...".
line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -f "$LOG"

# pytest errors (collection/setup) count as failures for the oracle.
failed=$(( failed + errors ))

# If pytest itself could not run (rc!=0 and no parseable counts), report a failure.
if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
