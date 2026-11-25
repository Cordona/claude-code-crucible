# Step 4: the parked cases

**Not run.** The cells `parked-build` and `parked-test` are built in `lab/cells.sh`:
- the tree carries a 50-second soak test, `tests/test_slow.sh`;
- the session sets `BASH_MAX_TIMEOUT_MS=30000` through the settings env.

They were held back with the rest of step 4 (see `README.md`). In the trial, the real builder took one Bash denial (`<check>; echo rc=$?`) as "Bash denied in this session" and ran no check after it. Under these permission rules, a parked case would most likely never start its long check, so it would show nothing about parking.
