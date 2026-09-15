# Ticket-ID allowlist example (real ticket IDs still trigger)

This change was requested in COTE-1543 during planning.

A second, differently-prefixed ticket is tracked as PROJ-99.

This line only mentions a real technical standard and must NOT be flagged:
UTF-8 and SHA-256 are not ticket IDs.

This line mixes a real ticket ID with a standard mention, and must still be
flagged: see COTE-1543 for the RFC-2119 rationale.
