# A seat brought up to date with the seats it was cut from.
include "title";
include "common";

# view
#   input:  {seat, parents: [S...], the seats whose newer work it took}
#   output: one line
def view: "\(.seat | seat_display) now holds the latest work of \(.parents | seat_names).";
