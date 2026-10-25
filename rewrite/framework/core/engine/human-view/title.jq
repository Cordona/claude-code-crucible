# The one place a developer or reviewer title is built; a caller passes the role
# word and never adds it itself.

# joined_labels
#   input:  array of labels
#   output: "A", "A and B", or "A, B and C" for three or more, in the given order
def joined_labels:
	if length <= 1 then (.[0] // "")
	else (.[:-1] | join(", ")) + " and " + .[-1]
	end;

# title($role)
#   input:  {language: label, frameworks: [labels]}, either key absent or null
#   $role:  the role word, such as developer or reviewer
#   output: "<language> <role>" with no framework; "<frameworks> <role> with
#           <language>" with one or more; "Generic <role>" with no language
def title($role):
	(.frameworks // []) as $frameworks
	| if (.language // "") == "" then "Generic \($role)"
	  elif ($frameworks | length) == 0 then "\(.language) \($role)"
	  else "\($frameworks | joined_labels) \($role) with \(.language)"
	  end;
