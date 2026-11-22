# context.cut: one sealed version of the context. Its body is
# {version, paths, links?, spec}: version the next number, paths the outside
# {path, why} entries and the {path, sha256} docs folders, links the {url, why}
# entries, spec the spec.md of one of its docs folders. At most 65536 bytes.
include "link-rule" {search: "../scripts/lib"};
([.prior[] | select(.type == "context.cut")] | length) as $before
| .event.body as $b
| (if ($b | type) != "object" then "the body must be an object" else empty end),
  (($b | keys? // []) - ["version", "paths", "links", "spec"] | .[] | "body.\(.) is not a context.cut field"),
  (if $b.version == $before + 1 then empty else "body.version must be \($before + 1), the next version" end),
  (if ($b.paths | type) == "array" then empty else "body.paths must be an array" end),
  ($b.paths[]? | select(
	(type != "object")
	or ((.path | type) != "string") or (.path | startswith("/") | not)
	or (if has("sha256") then ((.sha256 | test("^[0-9a-f]{64}$") | not) or ((keys - ["path", "sha256"]) != []))
	    else (((.why // "") | test("\\S") | not) or ((keys - ["path", "why"]) != [])) end))
	| "body.paths holds a bad entry: \(tojson | .[:120])"),
  ($b.links[]? | select((type != "object") or ((.url | safe_link) | not) or (((.why // "") | test("\\S")) | not))
	| "body.links holds a bad entry: \(tojson | .[:120])"),
  ([$b.paths[]? | select(has("sha256")) | "\(.path)/spec.md"] as $specs
	| if ($b.spec | type) == "string" and ($specs | index([$b.spec])) then empty
	  else "NO-SPEC: body.spec must be the spec.md of one of the version's docs folders" end),
  (if (.event | tojson | length) <= 65536 then empty else "the event is over 65536 bytes" end)
