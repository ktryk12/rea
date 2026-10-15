#!/bin/sh
# The verification gate for this fork, as one runnable script.
#
#   ./podman/ci-gate.sh [static|provenance|negative|all]     (default: all)
#
# It exists as a script, not as CI configuration, so the same checks run
# identically on a developer machine, in GitHub Actions, or on a self-hosted
# runner. CI should call this and nothing else.
#
# Requirements: node and npm on PATH, a Git checkout, and rootless podman for
# the provenance and negative stages. No secrets, no network beyond `npm ci`,
# no publishing, and nothing outside this repository is touched.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
in_repo() { (CDPATH= cd -- "$repo_root" && "$@"); }
stage="${1:-all}"

passes=0
failures=0
report() {
  if [ "$1" = pass ]; then
    passes=$((passes + 1))
    printf 'PASS  %s\n' "$2"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s\n' "$2"
  fi
}

# Run a command and assert its exit status. Output is kept quiet unless the
# expectation is not met, so a green run stays readable.
# POSIX sh has no function scope: every assignment here is global. These locals
# are therefore prefixed, because an earlier version assigned `out` and silently
# clobbered the caller's output directory, so later tests measured an error
# message as if it were a path.
expect_status() {
  _g_want="$1"
  _g_name="$2"
  shift 2
  _g_got=0
  _g_out="$("$@" 2>&1)" || _g_got=$?
  if [ "$_g_got" = "$_g_want" ]; then
    report pass "$_g_name (exit $_g_got)"
  else
    report fail "$_g_name (expected exit $_g_want, got $_g_got)"
    printf '%s\n' "$_g_out" | tail -15 | sed 's/^/        /'
  fi
}

# Assert that a command's output contains a string.
expect_output() {
  _g_needle="$1"
  _g_name="$2"
  shift 2
  _g_out="$("$@" 2>&1 || true)"
  case "$_g_out" in
    *"$_g_needle"*) report pass "$_g_name" ;;
    *)
      report fail "$_g_name (missing: $_g_needle)"
      printf '%s\n' "$_g_out" | tail -15 | sed 's/^/        /'
      ;;
  esac
}

IMAGE=localhost/rea-runtime:current
HARDENED="--rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges"

# Run one analysis and return the provenance digest for its input.
#
# The manifest is deleted first and its presence asserted afterwards. Without
# that, a run which never reached the provenance step leaves the PREVIOUS
# manifest in place and the caller silently measures stale state. That happened
# while building this gate: three directory fixtures all reported the digest of
# an earlier file input, which would equally have allowed a false pass.
analyze_input_digest() {
  _g_src="$1"
  _g_dest="$2"
  rm -f "$_g_dest/rea-run-provenance.json"
  sh "$repo_root/podman/rea-analyze.sh" "$_g_src" "$_g_dest" inspect-artifact /snapshot/input >/dev/null 2>&1 || true
  if [ ! -f "$_g_dest/rea-run-provenance.json" ]; then
    echo "NO_MANIFEST"
    return 0
  fi
  # node runs from the repository root with a RELATIVE path: native node on
  # Windows cannot open the POSIX form that podman needs for its mounts.
  _g_rel="${_g_dest#"$repo_root"/}"
  in_repo node -e 'const j=require("./"+process.argv[1]);process.stdout.write(j.input.sha256)' "$_g_rel/rea-run-provenance.json"
}

# ---------------------------------------------------------------------------
run_static() {
  echo "--- static ---"
  in_repo env HUSKY=0 npm ci --ignore-scripts --no-fund --no-audit >/dev/null
  expect_status 0 "typecheck" sh -c "cd '$repo_root' && npx tsc --noEmit"
  expect_status 0 "compile" sh -c "cd '$repo_root' && npm run compile >/dev/null"
  expect_status 0 "format" sh -c "cd '$repo_root' && npx oxfmt --check . >/dev/null"
  expect_status 0 "lint" sh -c "cd '$repo_root' && npx oxlint >/dev/null"
  expect_status 0 "domain tests" sh -c "cd '$repo_root' && npx vitest run --project domain --reporter=dot >/dev/null"
}

# ---------------------------------------------------------------------------
run_provenance() {
  echo "--- provenance ---"
  expect_status 0 "runtime image builds from the commit" \
    sh "$repo_root/podman/rea-build-runtime.sh"
  expect_output '"verdict": "SOURCE_BINDING_VERIFIED"' "source binding verified" \
    sh "$repo_root/podman/rea-verify-source.sh" "$IMAGE"

  # A. Negative source binding: change source files, keep the declared commit.
  # podman accepts a POSIX path for -v but NOT as a build context in this
  # environment: an absolute POSIX path was resolved under the wrong drive root
  # and the build failed with 'context must be a directory'. The context is
  # therefore relative to the repository root, with podman run from there.
  tamper_rel=".rea-gate-tamper"
  tamper="$repo_root/$tamper_rel"
  rm -rf "$tamper"
  mkdir -p "$tamper"
  # A quoted heredoc, not `echo`: dash's echo expands backslash escapes while
  # bash's does not, so the generated Containerfile was valid locally and a
  # syntax error on CI ("unterminated quoted string"). The appended text is
  # written by a shell inside the build, so it must survive two levels intact.
  cat > "$tamper/Containerfile" <<TAMPER
FROM $IMAGE
USER root
RUN echo >> /opt/rea/scripts/rea.mjs && echo '// injected' >> /opt/rea/scripts/rea.mjs
USER node
TAMPER
  in_repo podman build -q -f "$tamper_rel/Containerfile" -t localhost/rea-gate-tamper:test "$tamper_rel" >/dev/null
  expect_output '"verdict": "SOURCE_BINDING_FAILED"' \
    "source binding rejects modified sources under a held-constant SHA" \
    sh "$repo_root/podman/rea-verify-source.sh" localhost/rea-gate-tamper:test
  expect_status 7 "analysis refuses a tampered runtime when the gate is required" \
    env REA_IMAGE=localhost/rea-gate-tamper:test REA_REQUIRE_SOURCE_BINDING=1 \
    sh "$repo_root/podman/rea-analyze.sh" "$repo_root/package.json" "$tamper/out" inspect-artifact /snapshot/input
  podman rmi -f localhost/rea-gate-tamper:test >/dev/null 2>&1 || true
  rm -rf "$tamper"
}

# ---------------------------------------------------------------------------
run_negative() {
  echo "--- negative ---"
  work="$repo_root/.rea-gate-work"
  rm -rf "$work"
  mkdir -p "$work/in" "$work/out"
  printf 'sample\n' > "$work/in/sample.txt"
  in_repo node -e '
    const { writeFileSync, mkdirSync } = require("node:fs");
    // Three trees that an contents-only digest cannot tell apart.
    for (const [dir, names] of [["A/x", ["one", "two"]], ["B/y", ["one", "two"]], ["C", ["two", "one"]]]) {
      mkdirSync(`.rea-gate-work/trees/${dir}`, { recursive: true });
      writeFileSync(`.rea-gate-work/trees/${dir}/${names[0]}.txt`, "alpha\n");
      writeFileSync(`.rea-gate-work/trees/${dir}/${names[1]}.txt`, "beta\n");
    }
  '

  analyze="$repo_root/podman/rea-analyze.sh"
  input="$repo_root/.rea-gate-work/in/sample.txt"
  out="$repo_root/.rea-gate-work/out"

  # Command injection: the payload must never execute.
  injected="$(sh "$analyze" "$input" "$out" inspect-artifact '/snapshot/input; id; echo INJECTED' 2>&1 || true)"
  if printf '%s\n' "$injected" | grep -qE '^uid=|^INJECTED$'; then
    report fail "argument injection is blocked"
  else
    report pass "argument injection is blocked"
  fi

  expect_status 2 "operation allowlist rejects an injected operation" \
    sh "$analyze" "$input" "$out" '--version; id'
  for op in setup mcp update uninstall; do
    expect_status 2 "operation allowlist rejects $op" sh "$analyze" "$input" "$out" "$op"
  done

  expect_output "EROFS" "container root filesystem is read-only" \
    sh -c "podman run $HARDENED --entrypoint /usr/local/bin/node $IMAGE -e 'try{require(\"fs\").writeFileSync(\"/opt/rea/x\",\"1\")}catch(e){console.log(e.code)}'"
  expect_output "EAI_AGAIN" "container has no network" \
    sh -c "podman run $HARDENED --entrypoint /usr/local/bin/node $IMAGE -e 'require(\"dns\").lookup(\"registry.npmjs.org\",e=>console.log(e?e.code:\"RESOLVED\"))'"
  expect_output "false,false" "no podman or docker socket is reachable" \
    sh -c "podman run $HARDENED --entrypoint /usr/local/bin/node $IMAGE -e 'const f=require(\"fs\");console.log([\"/run/podman/podman.sock\",\"/var/run/docker.sock\"].map(x=>f.existsSync(x)).join(\",\"))'"
  expect_status 1 "image hands out no shell by default" \
    sh -c "podman run --rm --network=none $IMAGE sh -c 'echo SHELL' >/dev/null 2>&1"

  # B. Special files are refused rather than recorded.
  vol="$(podman volume create)"
  podman run --rm --network=none --cap-drop=ALL -v "$vol":/w:rw \
    --entrypoint /bin/sh "$IMAGE" \
    -c 'mkdir -p /w/src /w/snap && echo d > /w/src/real.txt && ln -s /etc/passwd /w/src/escape.txt && mkfifo /w/src/pipe' >/dev/null
  expect_status 5 "snapshot refuses symbolic links and special files" \
    sh -c "podman run $HARDENED -e REA_SNAPSHOT_SOURCE=/w/src -e REA_SNAPSHOT_TARGET=/w/snap/input -v $vol:/w:rw --entrypoint /usr/local/bin/node $IMAGE /opt/rea/podman/rea-snapshot.mjs"
  podman volume rm "$vol" >/dev/null 2>&1 || true

  # B. A directory digest must distinguish structure, not only contents.
  digests=""
  for tree in A B C; do
    digests="$digests $(analyze_input_digest "$repo_root/.rea-gate-work/trees/$tree" "$out")"
  done
  unique="$(printf '%s\n' $digests | sort -u | wc -l | tr -d ' ')"
  if [ "$unique" = 3 ]; then
    report pass "directory digests distinguish renames and swapped filenames"
  else
    report fail "directory digests collide ($unique distinct of 3):$digests"
  fi

  # B. Output paths must stay distinct rather than collapse to a basename.
  rm -rf "$out"
  mkdir -p "$out/a" "$out/b"
  printf 'A\n' > "$out/a/report.json"
  printf 'B\n' > "$out/b/report.json"
  rm -f "$out/rea-run-provenance.json"
  sh "$analyze" "$input" "$out" inspect-artifact /snapshot/input >/dev/null 2>&1 || true
  if [ -f "$out/rea-run-provenance.json" ]; then
    expect_output 'a/report.json' "output manifest records relative paths" \
      in_repo node -e 'const j=require("./"+process.argv[1]);console.log(j.output.filter(o=>o.kind==="file").map(o=>o.path).join(","))' ".rea-gate-work/out/rea-run-provenance.json"
  else
    report fail "output manifest records relative paths (no manifest produced)"
  fi

  rm -rf "$work"
}

case "$stage" in
  static) run_static ;;
  provenance) run_provenance ;;
  negative) run_negative ;;
  all)
    run_static
    run_provenance
    run_negative
    ;;
  *)
    echo "usage: ci-gate.sh [static|provenance|negative|all]" >&2
    exit 2
    ;;
esac

echo "--- summary ---"
echo "passed: $passes  failed: $failures"
[ "$failures" = 0 ] || exit 1
