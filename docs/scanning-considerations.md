# Scanning pitfalls & expected errors (Java batch scans)

This project will scan many Java repos with SonarQube. Even if all repos are “Java”, scans can fail for predictable reasons.
This document lists the main failure modes and what to do.

---

## 1) Build JDK mismatch (most common)

**Symptom**
- Maven: `release version X not supported`
- Gradle: `Unsupported class file major version` / toolchain errors

**Cause**
- Repo requires JDK X (8/11/17/21), but the runner is using a different JDK.

**Fix**
- Ensure the scan runner selects the correct build JDK per repo.
- Always print and verify:
  - `java -version`
  - `mvn -v` / `./gradlew -version`

**Note (macOS/Homebrew)**
- `JAVA_HOME=$(/usr/libexec/java_home -v 21)` may not work for keg-only JDKs unless registered.
- Prefer explicit Homebrew path for `JAVA_HOME` when needed.

---

## 2) Maven/Gradle layout mismatch

**Symptom**
- `No pom.xml found at repo root`
- `./gradlew: No such file or directory`

**Cause**
- Build is in a subdirectory, multi-module repo, or uses a different build tool.

**Fix**
- Add per-repo overrides:
  - `buildTool: maven|gradle`
  - `subdir: path/to/project`

---

## 3) Scanner runtime mismatch / incompatible native scanner

**Symptom**
- Maven or Gradle build succeeds, but Sonar submission fails with:
  - `UnsupportedClassVersionError`
  - `compiled by a more recent version of the Java Runtime`
  - scanner/plugin classpath incompatibility

**Cause**
- The repo builds on one JDK, but the Sonar scanner requires a newer runtime
  or the repo pins an outdated scanner/plugin version.

**Fix**
- Keep build and coverage on the successful build JDK.
- Run Sonar submission with a separate scanner runtime when needed.
- Always pass `sonar.java.jdkHome` when analysis runtime differs from the
  project JDK.
- Prefer a Lidskjalv-owned scanner version and fall back to `sonar-scanner`
  CLI when native Maven/Gradle submission is incompatible.

---

## 4) Sonar Maven plugin not found

**Symptom**
- `No plugin found for prefix 'sonar'`

**Cause**
- Maven can’t resolve `sonar:sonar` prefix mapping in current setup.

**Fix**
- Call the plugin by coordinates:
  - `org.sonarsource.scanner.maven:sonar-maven-plugin:sonar`

---

## 5) Dependency / repository access failures

**Symptom**
- 401/403 downloading deps
- cannot resolve artifacts
- timeouts to internal repositories

**Cause**
- Private Maven repositories or credentials required.

**Fix**
- Provide `settings.xml` (or env-based auth) for the runner.
- Document required credentials per repo/org.

---

## 6) Tests / build steps still run

**Symptom**
- Build fails even with `-DskipTests=true`
- Integration tests or checks run in other phases/plugins.

**Fix**
- Prefer stronger skip:
  - `-Dmaven.test.skip=true`
- Add repo-specific skip flags if needed.

---

## 7) Coverage report missing even though tests ran

**Symptom**
- Build and tests succeed, but Sonar runs without coverage.
- JaCoCo is configured, but no XML report is found.

**Cause**
- Repo binds JaCoCo report generation later than `test`, skips tests by
  configuration, or writes reports to module-specific locations.

**Fix**
- Force unit tests back on during the coverage phase.
- If needed, run one late non-test lifecycle pass (`install -DskipTests`) to
  materialize report goals and reactor artifacts.
- Discover actual JaCoCo XML reports recursively instead of assuming a single
  default path.

---

## 8) Non-Java prerequisites (rare but real)

**Symptom**
- build fails due to missing Node, Python, native libs, git submodules, git-lfs, etc.

**Fix**
- Extend runner image/tooling OR mark repo as “needs manual prerequisites”.
- Capture exceptions in per-repo config.

---

## 9) SonarQube server readiness / processing delays

**Symptom**
- Scan uploads but results aren’t visible yet.

**Cause**
- Server not `UP` or Compute Engine still processing.

**Fix**
- Healthcheck: `/api/system/status` must be `UP`.
- Poll Compute Engine task (or wait) before fetching metrics.

---

## Recommended runner behavior (minimum)

- Load `.env` automatically (no manual exporting required).
- Print `java -version` and `mvn -v` for each repo.
- Support per-repo overrides: `jdk`, `buildTool`, `subdir`, `extraArgs`.
- Track build JDK, coverage JDK, scanner JDK, scanner mode, and fallback chain.
- Continue-on-error and produce a failure report with reason per repo.
