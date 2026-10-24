# Ticket-ID allowlist example (clean)

The API uses UTF-8 encoding and SHA-256 hashes, per RFC-2119 and ISO-8601
timestamps.

Payloads are encrypted with AES-256 and signed with RSA and ECDSA keys,
verified over TLS via an HTTP or HTTPS endpoint.

The response body is JSON, never XML, per IEEE, ECMA, ANSI, POSIX, ASCII,
ITU, IETF, and W3C conventions, using UUID identifiers and MIME types, a
CRC checksum, and legacy MD, DES, RC, and PKCS references for historical
context, plus ES-256 as an alternate algorithm name.

None of the above is a ticket ID — this document must lint clean.
