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
import re
import sys

# fuzz_helpers.py lives alongside this harness -- make it importable when the
# launcher execs us by absolute path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import atheris
import fuzz_helpers

# Instrument the library under test so the fuzzer gets coverage feedback.
with atheris.instrument_imports():
    from khayyam import JalaliDatetime, JalaliDate


# Errors that are legitimate responses to malformed input -- not defects.
# re.error (aka re.PatternError) is raised when a fuzzed *format string* makes khayyam build
# an invalid parser regex -- a benign response to malformed input, not a defect. Without it the
# harness treats that as an uncaught crash, so every libFuzzer fork child exits at once (0 edges).
_EXPECTED = (ValueError, TypeError, IndexError, KeyError, OverflowError, AttributeError, re.error)


def TestOneInput(data: bytes) -> None:
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    which = fdp.ConsumeIntInRange(0, 3)
    fmt = fdp.ConsumeUnicodeNoSurrogates(fdp.ConsumeIntInRange(0, 64))
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
