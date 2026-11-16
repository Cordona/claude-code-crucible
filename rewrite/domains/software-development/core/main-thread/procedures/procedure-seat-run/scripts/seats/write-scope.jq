# Which files a seat's role may write, judged by path alone: no file is
# read. A module: load it with jq -L <this folder> and include
# "write-scope". A path is relative to the worktree root, "/"-separated, as
# git prints it.
# is_test_path: input a path; true when it names a test file or a file in a
# test folder.
# in_scope($role; $path): true when a seat of $role may write $path; a
# builder writes every path but a test path. A role it does not know is an
# error, so a caller never reads a guess as an answer.

# Folder names whose files are tests or test data.
def write_scope_test_folders: [
	"test", "tests", "__tests__", "__mocks__", "testdata", "testFixtures", "integrationTest"
];
# A Gradle source set directly under src whose name ends in Test, such as
# androidTest or functionalTest.
def write_scope_test_source_set: "\\A.+Test\\z";
# File names of tests, as regexes over the last path segment. [^.]* keeps
# Test, Tests and IT at the end of the name before its first dot, and the
# match is case-sensitive, so Latest.kt or Contest.java stay production
# files. An IT name also needs a lowercase letter somewhere before IT
# (NotesIT.kt, RestAPIIT.java), so an all-caps name such as AUDIT.md or
# IT.md is not a test.
def write_scope_test_names: [
	"\\A[^.]*_test\\.", "\\A[^.]*Test\\.", "\\A[^.]*Tests\\.", "\\A[^.]*[a-z][^.]*IT\\.",
	"\\.test\\.", "\\.spec\\.", "\\.cy\\.",
	"\\Atest_.*\\.py\\z", "_spec\\.rb\\z", "\\Aconftest\\.py\\z", "\\Atests\\.rs\\z",
	"\\Atests\\.py\\z"
];

def write_scope_in_test_folder:
	. as $segments
	| any($segments[:-1][]; IN(write_scope_test_folders[]))
	  or any(range(1; ($segments | length) - 1);
		$segments[. - 1] == "src" and ($segments[.] | test(write_scope_test_source_set)));

def write_scope_has_test_name:
	(.[-1] // "") as $name
	| any(write_scope_test_names[]; . as $pattern | $name | test($pattern));

def is_test_path:
	split("/") | write_scope_in_test_folder or write_scope_has_test_name;

def in_scope($role; $path):
	if $role == "builder" then $path | is_test_path | not
	else error("in_scope: role \($role | tojson) has no write scope; expected builder")
	end;
