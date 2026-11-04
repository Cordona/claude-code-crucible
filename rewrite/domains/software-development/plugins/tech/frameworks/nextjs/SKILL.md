---
name: framework-nextjs
description: "Next.js rules: toolchain, Server Actions, route handlers, middleware, caching, route files and lints. Use when writing or reviewing TypeScript that uses Next.js's App Router. A framework plugin beside its language plugin, and normally beside `framework-react`. Writes nothing and adds no gate tool. Not for code with no language plugin loaded, the Pages Router, Remix, or React's and TypeScript's own rules (`framework-react`, `language-typescript`)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Next.js
---

# Framework: Next.js

## Scope

- **In:** Next.js with the App Router, used from TypeScript, `.js` files inside a TypeScript project included.
- **Out:** the Pages Router and Remix.

## Toolchain

Settle it after TypeScript's toolchain, before writing a line. Take each fact from the first source below that sets it:

1. The `next` version in `package.json`, else in the lockfile.
2. What the project's own docs on its Next.js code say, where the task's context lists them.
3. Otherwise none: never a guessed version (see Version ledger).

- **The router:** the App Router when an `app/` directory exists.

## Server Actions and route handlers

- **Treat each Server Action and route handler as a network endpoint, and authorize the caller in each one:** a client can call the endpoint directly the moment it exists, so "only called from an authenticated page" is no control.
- **Take identity, role and tenant only from the verified server-side session:** a form field, hidden input or action argument is caller-supplied and can say anything.
- **Never make middleware the only authorization check:** the Server Action or route handler behind it still checks.

## Data caching

- **State the cache intent of each data read** instead of relying on the default: the default changes between Next.js majors.
- **Revalidate what a Server Action changes,** with `revalidateTag` when the reads it changes are tagged, else `revalidatePath` for each path that shows the data: otherwise cached pages keep serving the old data.

## Routes

- **Make each segment's `error` file a client component:** Next.js requires it.
- **Never hand-roll route-level code splitting:** the App Router already splits by route.
- **Load a heavy client component or a below-the-fold tree with `next/dynamic`, in place of `React.lazy`:** its code then loads only when it renders.

## Next.js mechanisms for the shared standards

- **Persistence:** scope a transaction to one Server Action or route handler invocation, never split across round-trips: a split leaves a half-applied change when a later call fails or never comes.

## Lints

- **Honor `@next/eslint-plugin-next` (`next/core-web-vitals`) where the project configures it:** it catches Next.js misuse the TypeScript lints don't know. A rule of it turned off or down in the project's lint config is a finding; a reasoned line-level disable complies.

## Version ledger

| Fact | Value |
|---|---|
| Default router (Toolchain) | App Router |
| Default Next.js major (Toolchain step 3) | none |
