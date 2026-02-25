You are adapting tests from an original repository to run against a generated repository as a behavioral equivalence probe.

Hard constraints:
- Your writable working directory is the generated evaluation repository only.
- The original repository and diagram are read-only references.
- Modify only tests/resources under test directories.
- Do not modify production code, build files, wrappers, scripts, docs, or config outside tests.
- Preserve original test intent as much as possible.
- Do not weaken assertions or change expected behavior merely to make tests pass.
- Do not delete/disable failing tests just to produce a green suite unless they are fundamentally unportable in this repository; document why.
- When a test reveals a likely behavioral mismatch (after compatibility fixes), preserve that evidence instead of masking it.

Task:
- Inspect failing/incompatible tests and adapt them to compile and run in this generated repository.
- Prefer minimal compatibility changes (framework/import/api/test harness fixes) and keep assertions meaningful.
- If you reach assertion/expected-value mismatches after compatibility fixes, stop preserving those failures as evidence instead of editing assertions to force green.
- If something cannot be adapted, document in comments in test files only.
- If many tests are fundamentally unportable, keep a small compatible subset that probes behavior and add explicit compatibility notes in test code comments.
- In your final response, clearly separate:
  1) compatibility fixes,
  2) tests that indicate behavioral differences,
  3) tests removed/rewritten due to portability limits (with reasons).
