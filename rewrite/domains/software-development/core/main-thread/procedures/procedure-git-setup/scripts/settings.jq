# An effort's git settings, kept as settings.set events: the identity its
# worker commits are authored and signed with, whether the stop hook pushes
# them, and the remote. A module: load it with jq -L <this folder> and
# include "settings".
# Each *_problems def prints a list of "<field> <problem>; expected <x>"
# lines, empty when its input fits. $names maps each field to the name a
# problem calls it by (settings_file_names for the file, or a caller's own,
# such as its option names). The shape defs check what a reader relies on;
# the length caps are a writer's and apply only in settings_problems.

def settings_formats: ["openpgp", "ssh"];
def settings_remote: "origin";
# The Identity question's AskUserQuestion takes four options at most, and
# one is always "No, set up git first".
def settings_max_identities: 3;
# Far past any real name, and short enough for one option label.
def settings_max_name_chars: 200;
# The longest address an SMTP path holds (RFC 5321).
def settings_max_email_chars: 254;
# Holds a key:: literal of an 8192-bit RSA key, the longest git takes.
def settings_max_key_chars: 2000;
def settings_file_names: {
	identity: "identity", name: "identity.name", email: "identity.email",
	signing: "identity.signing", format: "identity.signing.format", key: "identity.signing.key",
	auto_push: "auto_push", remote: "remote"};

# A control character, or a line or paragraph separator.
def settings_has_control: test("[\u0000-\u001f\u007f\u2028\u2029]");
def settings_unknown_keys($allowed; $at):
	(keys - $allowed)[] | "\($at) holds the unknown key \(tojson); expected only \($allowed | join(", "))";

# Git drops these characters from both ends of a name or email, so a value
# holding one there would be written other than given.
def settings_has_trimmed_edge: test("\\A[[:space:].,:;\"'\\\\]|[[:space:].,:;\"'\\\\]\\z");
def settings_trimmed_edge_problem($at):
	"\($at) starts or ends with a space or one of . , : ; \" ' \\; expected neither";

# Git refuses "<" and ">" in an author name.
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def settings_name_problems($at):
	if type != "string" then "\($at) is a JSON \(type); expected a string"
	elif test("\\A[[:space:]]*\\z") then "\($at) is empty; expected the author name"
	elif settings_has_control then "\($at) holds a control character; expected one line of text"
	elif test("[<>]") then "\($at) holds < or >; expected a name git can write"
	elif settings_has_trimmed_edge then settings_trimmed_edge_problem($at)
	else empty end;

def settings_email_problems($at):
	if type != "string" then "\($at) is a JSON \(type); expected a string"
	elif test("\\A[^[:space:][:cntrl:]<>@-][^[:space:][:cntrl:]<>@]*@[^[:space:][:cntrl:]<>@]+\\z") | not
	then "\($at) is not an email address; expected <local>@<domain>, no space, < or >, not starting with -"
	elif settings_has_trimmed_edge then settings_trimmed_edge_problem($at)
	else empty end;

# An openpgp key is anything gpg's --local-user takes (an id, a fingerprint,
# an email); an ssh key is what git's user.signingkey takes for ssh: a
# key:: or ssh- literal, the only literals git reads as a key, or an
# absolute key file path. Neither may start with "-".
def settings_key_problems($format; $at):
	if type != "string" then "\($at) is a JSON \(type); expected a string"
	elif test("\\A[[:space:]]*\\z") then "\($at) is empty; expected the signing key"
	elif settings_has_control then "\($at) holds a control character; expected one line of text"
	elif startswith("-") then "\($at) starts with -; expected a key, not an option"
	elif $format == "ssh" and (test("\\A(key::|ssh-|/)") | not)
	then "\($at) is no SSH key git reads; expected key::<type> <key>, ssh-<type> <key> or an absolute key file path"
	else empty end;

def settings_signing_problems($names):
	if . == null then empty
	elif type != "object" then "\($names.signing) is a JSON \(type); expected an object or null"
	else (.format as $given | if any(settings_formats[]; . == $given) then $given else "" end) as $format
		| settings_unknown_keys(["format", "key"]; $names.signing),
		  (if has("format") | not then "\($names.format) is missing; expected \(settings_formats | join(" or "))"
		   elif $format == "" then "\($names.format) is \(.format | tojson); expected \(settings_formats | join(" or "))"
		   else empty end),
		  (if has("key") then .key | settings_key_problems($format; $names.key) else "\($names.key) is missing; expected the signing key" end)
	end;

# The identity object's shape: name, email and signing (an object or null).
def settings_identity_problems($names):
	if type != "object" then "\($names.identity) is a JSON \(type); expected an object"
	else settings_unknown_keys(["name", "email", "signing"]; $names.identity),
		(if has("name") then .name | settings_name_problems($names.name) else "\($names.name) is missing; expected the author name" end),
		(if has("email") then .email | settings_email_problems($names.email) else "\($names.email) is missing; expected the author email" end),
		(if has("signing") then .signing | settings_signing_problems($names) else "\($names.signing) is missing; expected an object or null" end)
	end;

def settings_length_problem($at; $max; $why):
	if type == "string" and length > $max then "\($at) is \(length) characters; expected at most \($max), \($why)" else empty end;

# The length caps of an identity whose shape fits.
def settings_identity_length_problems($names):
	(.name | settings_length_problem($names.name; settings_max_name_chars; "the most a card option shows")),
	(.email | settings_length_problem($names.email; settings_max_email_chars; "the longest email address")),
	(.signing.key // "" | settings_length_problem($names.key; settings_max_key_chars; "the longest key git takes"));

# An identity a writer may save: its shape, then its length caps.
def settings_writable_identity_problems($names):
	[settings_identity_problems($names)] as $shape
	| if ($shape | length) > 0 then $shape[] else settings_identity_length_problems($names) end;

# One of identity-candidates.sh's identities: a writable identity that signs,
# plus its key's fingerprint (a string, "" when unknown).
def settings_candidate_problems($names):
	if type != "object" then "\($names.identity) is a JSON \(type); expected an object"
	elif (.fingerprint | type) != "string" then "\($names.identity).fingerprint is \(.fingerprint | tojson); expected a string"
	elif .signing == null then "\($names.signing) is null; expected a signing key"
	else del(.fingerprint) | settings_writable_identity_problems($names) end;

# The settings object's shape, as a reader checks it.
def settings_shape_problems($names):
	if type != "object" then "the settings are a JSON \(type); expected an object"
	else settings_unknown_keys(["identity", "auto_push", "remote"]; "the settings object"),
		(if has("identity") then .identity | settings_identity_problems($names) else "\($names.identity) is missing; expected an object" end),
		(if (.auto_push | type) == "boolean" then empty else "\($names.auto_push) is \(.auto_push | tojson); expected true or false" end),
		(if .remote == settings_remote then empty else "\($names.remote) is \(.remote | tojson); expected \(settings_remote | tojson)" end)
	end;

# The settings object as a writer checks it: its shape, then the length caps.
def settings_problems($names):
	[settings_shape_problems($names)] as $shape
	| if ($shape | length) > 0 then $shape[] else .identity | settings_identity_length_problems($names) end;

# The lines settings.sh get prints, one per field, of settings that fit.
def settings_lines:
	"NAME=\(.identity.name)",
	"EMAIL=\(.identity.email)",
	"SIGNING_FORMAT=\(.identity.signing.format // "")",
	"SIGNING_KEY=\(.identity.signing.key // "")",
	"AUTO_PUSH=\(if .auto_push then "yes" else "no" end)",
	"REMOTE=\(.remote)";

# An SSH key's fingerprint as a label shows it: its hash name and the first
# 12 characters of its hash, 72 bits, so two keys' labels never match.
def settings_short_fingerprint: .[0:19];

# How a label names a signing key, from its signing object or null and its
# fingerprint ("" when unknown).
def settings_key_text($fingerprint):
	if . == null then "unsigned"
	elif .format == "ssh" then "SSH key" + (if $fingerprint == "" then "" else " \($fingerprint | settings_short_fingerprint)" end)
	else "GPG key \(.key)" end;

# One line naming an identity that fits, as the human reads it on the git
# setup question and in its saved line: "<name> · <email> · GPG key <key>",
# "… · SSH key <fingerprint>" or "… · unsigned". A candidate carries its key's
# fingerprint; an identity without one shows "SSH key" alone.
def settings_identity_text:
	(.fingerprint // "") as $fingerprint
	| "\(.name) · \(.email) · " + (.signing | settings_key_text($fingerprint));
