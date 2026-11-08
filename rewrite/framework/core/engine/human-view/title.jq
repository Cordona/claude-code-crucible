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

# seat_parts
#   input:  a seat name, such as build-agent-alpha or build-agent-alpha-2
#   output: {words: the words before the letter, letter: the letter and, from
#           the second round, its round, such as "Alpha" or "Alpha 2"}
def seat_parts:
	split("-")
	| if length > 1 and (.[-1] | test("\\A[0-9]+\\z")) then {words: .[:-2], letter: "\(.[-2] | capitalised) \(.[-1])"}
	  else {words: .[:-1], letter: (.[-1] | capitalised)}
	  end;

# seat_letter
#   input:  a seat name, such as build-agent-alpha or build-agent-alpha-2
#   output: its letter capitalised, with its round from the second one, such
#           as "Alpha" or "Alpha 2"
def seat_letter: seat_parts | .letter;

# seat_display
#   input:  a seat name, such as build-agent-alpha or build-agent-alpha-2
#   output: its words with spaces, the first capitalised, then its letter as
#           seat_letter gives it, such as "Build agent Alpha" or "Build agent
#           Alpha 2"
def seat_display:
	seat_parts
	| if .words == [] then .letter
	  else [(.words[0] | capitalised)] + .words[1:] + [.letter] | join(" ")
	  end;

# seat_title($role; $seat)
#   input:  as title's
#   output: title's, with $seat's letter right after the role word: "Rust
#           developer Alpha", "Kotlin developer Alpha with Spring", "Generic
#           developer Alpha"
def seat_title($role; $seat): title("\($role) \($seat | seat_letter)");
