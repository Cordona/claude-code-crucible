# The one place a developer or reviewer title and a seat's name for the human
# are built; a caller passes the role word and never adds it itself.

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
#   output: "<language> <role>" with no framework; "<language> <role> with
#           <frameworks>" with one or more; "Generic <role>" with no language
def title($role):
	(.frameworks // []) as $frameworks
	| if (.language // "") == "" then "Generic \($role)"
	  elif ($frameworks | length) == 0 then "\(.language) \($role)"
	  else "\(.language) \($role) with \($frameworks | joined_labels)"
	  end;

# capitalised
#   input:  a word
#   output: the word with its first letter in upper case
def capitalised: (.[:1] | ascii_upcase) + .[1:];

# seat_letter
#   input:  a seat name, such as software-developer-alpha
#   output: its last word capitalised, such as "Alpha"
def seat_letter: split("-") | .[-1] | capitalised;

# seat_display
#   input:  a seat name, such as software-developer-alpha
#   output: its words with spaces, the first and the last capitalised, such
#           as "Software developer Alpha"
def seat_display:
	split("-")
	| if length == 1 then .[0] | capitalised
	  else [(.[0] | capitalised)] + .[1:-1] + [.[-1] | capitalised] | join(" ")
	  end;

# seat_title($role; $seat)
#   input:  as title's
#   output: title's, with $seat's letter right after the role word: "Rust
#           developer Alpha", "Kotlin developer Alpha with Spring", "Generic
#           developer Alpha"
def seat_title($role; $seat): title("\($role) \($seat | seat_letter)");
