# A build report's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-builder/scripts/lib/build-report". The
# builder's common rules, and an unchanged tree needs a blocker.
include "code-builder/scripts/lib/builder-common";

def build_report_problems: bc_common_problems(bc_keys), bc_unchanged_problem;
