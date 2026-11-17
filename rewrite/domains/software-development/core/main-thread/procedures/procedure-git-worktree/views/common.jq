# The defs this skill's cards share.
include "title";

# seat_names
#   input:  array of seat names
#   output: each seat's name for the human, joined by " + "
def seat_names: map(seat_display) | join(" + ");

# A sha is shown by this many characters where git gives no short form.
def short_sha_length: 7;

# A card names at most this many files of a list.
def max_named: 20;
