#!/usr/bin/env python3
"""Atheris fuzz harness for Khayyam (Persian/Jalali date & time library).

Khayyam parses and formats Jalali (Persian calendar) date/time strings. The
original mayhemheroes harness drove ``JalaliDatetime.strptime`` on arbitrary
input; this harness keeps that entry point and broadens it to the public
parse/format surface (both ``JalaliDatetime`` and ``JalaliDate``). Atheris
instruments the imported khayyam modules so libFuzzer steers toward new code
paths in the parser/formatter.

Run modes (driven by the compiled launcher ``khayyam_fuzz`` / ``-standalone``):
  * fuzzing      -- ``python3 khayyam_fuzz.py [libFuzzer args]``
  * single input -- ``python3 khayyam_fuzz.py <file>`` (libFuzzer runs it once)
"""
import os
import sys

# fuzz_helpers.py lives alongside this harness -- make it importable when the
# launcher execs us by absolute path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import atheris
import fuzz_helpers

# Instrument the library under test so the fuzzer gets coverage feedback.
with atheris.instrument_imports():
    from khayyam import JalaliDatetime, JalaliDate


# Errors that are legitimate responses to malformed input -- not defects. This is the ORIGINAL
# mayhemheroes exception set (khayyam-fuzzer @ FUZZED): it does NOT excuse re.error, which is the
# bug this backport reproduces -- khayyam's strptime/strftime build a regex internally from the
# format string and never catch its own re.compile() failure, so a malformed format string leaks a
# raw re.error out of the public API instead of a documented ValueError.
_EXPECTED = (ValueError, TypeError, IndexError, KeyError, OverflowError, AttributeError)

# A raw fuzzed `fmt` crashes khayyam's OWN parser-regex builder (_create_parser_regex splices
# non-directive characters straight into a regex, unescaped) on virtually every mutation -- so the
# process never survives long enough between crashes to accumulate/report any libFuzzer coverage
# (edges stayed 0 -- "the harness does not fuzz" -- on the original mayhemheroes run AND on our
# first two backport attempts, one of which also tried Mayhemfile-level libFuzzer flags to force
# continued fuzzing past crashes; Mayhem's own dispatch rejects an explicit `-fork=` override, so
# the fix has to live here). Building `fmt` mostly (4 times out of 5) from valid directives + benign
# literal separators lets the parser/formatter run deep into khayyam's own code most of the time,
# giving libFuzzer real coverage to explore -- while the remaining 1-in-5 draws keep using the
# ORIGINAL raw/unrestricted fuzzed string, so the full variety of malformed-regex crashes the
# original run found (unbalanced parens, "nothing to repeat", duplicate group names, ...) still
# fires regularly, not just the narrow subset a directives-only vocabulary could produce.
_DIRECTIVE_KEYS = list("YyNOnRPmbBgGdDKjJVwWUaAeETx%")
_SAFE_LITERALS = list(" -:/.,_")


def _make_format(fdp) -> str:
    if fdp.ConsumeIntInRange(0, 4) == 0:
        return fdp.ConsumeUnicodeNoSurrogates(fdp.ConsumeIntInRange(0, 64))
    parts = []
    for _ in range(fdp.ConsumeIntInRange(0, 10)):
        if fdp.ConsumeBool():
            parts.append('%' + fdp.PickValueInList(_DIRECTIVE_KEYS))
        else:
            parts.append(fdp.PickValueInList(_SAFE_LITERALS))
    return ''.join(parts)


def TestOneInput(data: bytes) -> None:
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    which = fdp.ConsumeIntInRange(0, 3)
    fmt = _make_format(fdp)
    text = fdp.ConsumeRemainingString()
    try:
        if which == 0:
            JalaliDatetime.strptime(text, fmt)
        elif which == 1:
            JalaliDate.strptime(text, fmt)
        elif which == 2:
            # Exercise the formatter with a fuzzed format string on a fixed date.
            JalaliDatetime(1395, 1, 1).strftime(fmt)
        else:
            JalaliDate(1395, 1, 1).strftime(fmt)
    except _EXPECTED:
        pass


def main() -> None:
    # In libFuzzer FORK mode the driver re-execs sys.argv[0] to spawn each child. As launched by the
    # ELF launcher, argv[0] is THIS .py, whose `#!/usr/bin/env python3` shebang needs `python3` on
    # PATH -- but Mayhem runs fork children under a RESTRICTED PATH with no python3, so every child
    # dies `env: python3: No such file or directory` (exit 127) -> 0 edges / "process exited". Point
    # argv[0] back at the launcher ELF (absolute interpreter baked in via -DPYTHON) so children
    # re-exec THAT instead of the shebang. Single-process smoke goes through the launcher and is
    # immune, which is why this only bites the cloud/fork run.
    _launcher = "/mayhem/khayyam_fuzz"
    if os.path.exists(_launcher):
        sys.argv[0] = _launcher
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
