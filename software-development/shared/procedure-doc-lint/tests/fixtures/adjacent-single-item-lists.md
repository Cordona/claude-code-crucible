# Adjacent single-item lists example

Two genuinely distinct single-item lists, each back-to-back with no blank
line between the two items — a bullet-marker change first, then a
bullet-to-ordered transition. Under CommonMark, a marker-character change or
an ordered/unordered transition between consecutive list-item lines starts a
NEW list, so each pair below is two independent single-item lists, not one
two-item list, and both items in both pairs must be flagged.

- item A
* item B

- item C
1. item D
