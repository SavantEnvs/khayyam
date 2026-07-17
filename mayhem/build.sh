#!/usr/bin/env bash
#
# mayhem/build.sh — build the Khayyam Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own test suite. Runs inside the commit image (mayhem/Dockerfile)
# as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + the test deps OFFLINE from that wheelhouse into a fixed site dir on
#      PYTHONPATH. Khayyam itself stays the editable source tree ($SRC/khayyam, exposed via
#      PYTHONPATH) so a PATCH agent's edits take effect with no reinstall.
#   2. Compile the khayyam C extension (algorithms_c) in place so the fuzzer exercises the real
#      (C) code path rather than the slow pure-python fallback. If it cannot build, khayyam falls
#      back to algorithms_pure automatically — the harness still runs.
#   3. Compile launcher.c -> the ELF Mayhem target `khayyam_fuzz` (Atheris is a Python script;
#      Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   4. Build the same launcher as the standalone (run-once) reproducer `khayyam_fuzz-standalone`.
#   5. Compile the pytest-runner ELF wrapper so the sabotage/anti-reward-hack check bites the suite.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). The launcher is
# a thin C exec wrapper — sanitizing it with $SANITIZER_FLAGS would instrument the wrapper, not the
# fuzzed Python; Atheris instruments the khayyam library itself at import time. We thread DEBUG_FLAGS
# for DWARF < 4 debug info on the compiled ELF targets.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every test/runtime dependency ONCE (online). On the air-gapped re-run the
#    directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython; pytest is the suite runner; rtl is a khayyam test dependency;
#    setuptools is needed to compile the khayyam C extension (distutils is gone in CPython >=3.12).
PKGS=(atheris pytest rtl setuptools)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# Khayyam is a flat package at the repo root ($SRC/khayyam); expose it (and the site dir) on
# PYTHONPATH so a PATCH agent's edits under khayyam/ take effect immediately with no reinstall.
PYRUN="$SITE:$SRC"

# 2b) Compile the C extension in place (algorithms_c.<ext>.so lands under khayyam/). Best-effort:
#     on failure khayyam imports the pure-python fallback automatically, so the harness still runs.
echo ">> building khayyam C extension in place (best-effort)"
if PYTHONPATH="$PYRUN" "$PY" setup.py build_ext --inplace >/tmp/khayyam_ext_build.log 2>&1; then
  echo ">> C extension built"
else
  echo ">> WARNING: C extension build failed — falling back to pure-python algorithms" >&2
  tail -20 /tmp/khayyam_ext_build.log >&2 || true
fi

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, pytest; from khayyam import JalaliDatetime, JalaliDate; print("imports OK")'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
HARNESS="$SRC/mayhem/khayyam_fuzz.py"
echo ">> compiling khayyam_fuzz (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/khayyam_fuzz"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/khayyam_fuzz-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/khayyam_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/khayyam_fuzz" "$SRC/khayyam_fuzz-standalone" "$SRC/khayyam_run_tests"
