#!/usr/bin/env sh
#
# run-all-tests.sh — run every inspect-project suite and report one verdict.
#
# WHY THE SUITES ARE SEPARATE FILES AT ALL. Each owns a different PATH-toolbox
# matrix (see each one's own `run()` selector map), and one combined file would
# have to enumerate every combination of six stub directories. The split is by
# CONCERN, and each file's header says which one:
#
#   run-git-tests.sh         the index save/restore dance          (real git)
#   run-resolution-tests.sh  finding the IntelliJ binary
#   run-intellij-tests.sh    the IntelliJ engine's output
#   run-sonar-tests.sh       the SonarQube engine
#   run-cli-tests.sh         argv, exit codes, output layout
#   run-menu-tests.sh        the interactive menu                  (real pty)
#
# Every suite is independently runnable and leaves nothing behind: no temp
# directory, no stub process, and nothing written outside its own mktemp'd work
# directory and the git repositories it creates inside it.
#
# Usage:  sh run-all-tests.sh
#         VERBOSE=1 sh run-all-tests.sh
# Exit 0 = every suite passed, 1 = at least one failed.
#
set -eu

ALL_TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
ALL_FAILED=""

for suite in git resolution intellij sonar cli menu; do
	printf '\n############################################################\n'
	printf '# run-%s-tests.sh\n' "$suite"
	printf '############################################################\n'
	if ! sh "$ALL_TESTS_DIR/run-$suite-tests.sh"; then
		ALL_FAILED="$ALL_FAILED $suite"
	fi
done

printf '\n############################################################\n'
if [ -n "$ALL_FAILED" ]; then
	printf '# FAILED suites:%s\n' "$ALL_FAILED"
	printf '############################################################\n'
	exit 1
fi
printf '# all suites passed\n'
printf '############################################################\n'
