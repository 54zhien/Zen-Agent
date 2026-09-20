#!/usr/bin/env bash
#
# Primitives for guard-selftest.yml. Sourced, never executed on its own.
#
# Every probe works in a throwaway copy of the checkout under $RUNNER_TEMP, so a
# failed probe cannot leave the pushed branch dirty. Nothing here writes inside
# the repository.
#
# Callers must run under `set -e`. The premise checks below sit inside command
# substitutions (`tree=$(fresh_tree …)`), where an `exit 1` reaches the caller
# as a failed assignment — fatal under -e, and silently ignored without it. This
# file deliberately does not turn -e on for its callers; run_guard manages the
# one place that needs it off.

set -uo pipefail

harness_dir="${RUNNER_TEMP:?RUNNER_TEMP must be set}/guard-selftest"
old_guard="${harness_dir}/old-deployment-guard.sh"
new_guard=".github/scripts/managed-build-settings-guard.sh"

# fresh_tree <label> — a throwaway copy of the checkout. Prints its path; every
# other word goes to stderr, so the path is the only thing on stdout.
fresh_tree() {
  local label="$1"
  local dir="${harness_dir}/${label}"
  local required

  rm -rf "$dir"
  mkdir -p "$dir"

  # `cp -R` of the directory's contents rather than `git worktree add`: .git is
  # a file (a worktree pointer) in this checkout and a directory in a plain one,
  # and no probe wants history — only the tree the guard reads.
  cp -R "${GITHUB_WORKSPACE}/." "$dir/"
  rm -rf "${dir}/.git"

  # The premise, asserted. A copy that lost project.yml or Config/ would make
  # every probe below "pass" for the wrong reason.
  for required in \
    project.yml \
    Config/Common.xcconfig \
    Config/Debug.xcconfig \
    Config/Release.xcconfig \
    .github/scripts/managed-build-settings-guard.sh
  do
    if [ ! -f "${dir}/${required}" ]; then
      echo "::error::the throwaway copy is missing ${required}; the probe would test nothing." >&2
      exit 1
    fi
  done

  printf '%s\n' "$dir"
}

# generate_project <tree> — generate the Xcode project inside <tree>, which is
# what the guard's third invariant reads.
#
# Probes call this *after* mutating, so the generated project reflects the
# violation rather than the tree as pushed. It is also where a spec XcodeGen
# refuses is reported, as a broken probe input, instead of surfacing later as a
# mysterious guard failure.
generate_project() {
  local tree="$1"

  if ! ( cd "$tree" && xcodegen generate ) 1>&2; then
    echo "::error::xcodegen generate failed in ${tree}; the probe input is not a project XcodeGen accepts." >&2
    exit 1
  fi

  if [ ! -d "${tree}/ZenAgent.xcodeproj" ]; then
    echo "::error::xcodegen generate produced no ZenAgent.xcodeproj in ${tree}; the guard would fail for the wrong reason." >&2
    exit 1
  fi
}

# strip_cr <file> — rewrite <file> with LF endings only.
#
# project.yml holds CRLF in the repository itself, and core.autocrlf does not
# rewrite it on checkout. An awk anchor written as `$0 == "    type:
# application"` would then match nothing, the probe would quietly test the
# unmodified tree, and only assert_contains below would notice.
strip_cr() {
  local file="$1"
  local tmp="${file}.lf"

  tr -d '\r' < "$file" > "$tmp"
  mv "$tmp" "$file"
}

# run_guard <label> <tree> <script> <logfile> — run a guard inside <tree>, print
# its output and its exit code, and leave the code in $guard_status. It never
# fails the step itself: the caller asserts on the code.
guard_status=0
run_guard() {
  local label="$1" tree="$2" script="$3" log="$4"

  # The frozen guard's path is spelled both here and in the Freeze step, and the
  # new guard's is relative to the tree. A mismatch would otherwise surface as
  # four probes reporting "exited 127" — four broken probes rather than one
  # broken harness premise.
  if [ ! -f "$script" ] && [ ! -f "${tree}/${script}" ]; then
    echo "::error::${script} exists neither at that path nor under ${tree}; the harness premise is broken, not the guard." >&2
    exit 1
  fi

  echo "===== ${label} ====="
  echo "command: (cd ${tree} && sh ${script})"

  set +e
  ( cd "$tree" && sh "$script" ) >"$log" 2>&1
  guard_status=$?
  set -e

  echo "exit code: ${guard_status}"
  echo "--- output ---"
  cat "$log"
  echo "--- end output ---"
}

# assert_exit <what> <zero|nonzero> <status>
assert_exit() {
  local what="$1" expectation="$2" status="$3"

  case "$expectation" in
    zero)
      if [ "$status" -eq 0 ]; then
        echo "ASSERT OK: ${what} exited 0, as required"
        return 0
      fi
      echo "::error::${what} exited ${status}; this probe requires 0."
      ;;
    nonzero)
      if [ "$status" -ne 0 ]; then
        echo "ASSERT OK: ${what} exited ${status} (non-zero), as required"
        return 0
      fi
      echo "::error::${what} exited 0. The guard did not reject the violation this probe manufactured."
      ;;
    *)
      echo "::error::assert_exit: unknown expectation '${expectation}'."
      ;;
  esac

  exit 1
}

# assert_contains <what> <file> <extended-regex> — the file contains what the
# probe expects. `what` reads as a positive claim, so the failure message reads
# as its negation.
assert_contains() {
  local what="$1" file="$2" pattern="$3"

  if grep -Eq -- "$pattern" "$file"; then
    echo "ASSERT OK: ${what} (/${pattern}/ in ${file}):"
    grep -E -- "$pattern" "$file" | sed 's/^/    /'
    return 0
  fi

  echo "::error::expected ${what}, but /${pattern}/ is absent from ${file}."
  exit 1
}

# assert_log <what> <logfile> <extended-regex> — the guard rejected the
# violation for the expected reason. A guard that dies of an unrelated error
# also exits non-zero, and that is not evidence of anything.
assert_log() {
  local what="$1" log="$2" pattern="$3"

  assert_contains "${what} to have reported the expected reason" "$log" "$pattern"
}
