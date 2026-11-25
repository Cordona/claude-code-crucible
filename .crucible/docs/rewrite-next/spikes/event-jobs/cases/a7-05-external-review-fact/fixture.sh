#!/bin/sh
set -eu
er=$("$EV" --session S1 --type external-review.received --root self --body '{"pr":"pr-1","head":"h1","threads":[{"thread":"t1","file":"a.sh","text":"quote this variable"},{"thread":"t2","file":null,"text":"add a usage line"}]}')
