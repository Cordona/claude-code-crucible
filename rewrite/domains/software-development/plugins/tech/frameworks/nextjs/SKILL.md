---
name: framework-nextjs
description: "Next.js rules: toolchain, Server Actions, route handlers, middleware, caching, route files and lints. Use when writing or reviewing TypeScript that uses Next.js's App Router. A framework plugin beside its language plugin, and normally beside `framework-react`. Writes nothing and adds no gate tool. Not for code with no language plugin loaded, the Pages Router, Remix, or React's and TypeScript's own rules (`framework-react`, `language-typescript`)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Next.js
---

# Framework: Next.js

The rules that are specific to Next.js. It loads beside the language plugin, never alone, and repeats no rule that plugin holds; `framework-react`, when loaded beside this one, holds React's rules, the server/client component boundary and `"use client"` included, so this file repeats none of them either. Every role receives this file in its first message, after the language plugin's. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** Next.js with the App Router, used from TypeScript, `.js` files inside a TypeScript project included.
- **Out:** Next.js code with no language plugin loaded: this plugin never loads alone.
- **Out:** the Pages Router and Remix: this file holds no rules for them.
- **Out:** React with no Next.js, such as a Vite app or react-router: the React plugin alone covers it.

## Toolchain

Settle it after the language plugin's toolchain, before writing a line. Take each fact from the first source below that sets it:

1. The `next` version in `package.json`, else in the lockfile.
2. What the project's own docs on its Next.js code say, where the task's context lists them.
3. Otherwise "not found": report it so, never a guessed version (see Version ledger).

- **The router:** the App Router when an `app/` directory exists. The React plugin settles React and its compiler.

## Server Actions and route handlers

- **Treat each Server Action and route handler as a network endpoint, and authorize the caller in each one by the access-control rule `standard-security` holds,** loaded only when the task's plan loads it: a client can call the endpoint directly the moment it exists, so "only called from an authenticated page" is no control.
- **Take identity, role and tenant only from the verified server-side session:** a form field, hidden input or action argument is caller-supplied and can say anything.
- **Never make middleware the only authorization check:** the Server Action or route handler behind it still checks.

## Data caching

- **State the cache intent of each data read** instead of relying on the default: the default changes between Next.js majors.
- **Revalidate what a Server Action changes,** with `revalidateTag` when the reads it changes are tagged, else `revalidatePath` for each path that shows the data: otherwise cached pages keep serving the old data.

## Routes

- **Make each segment's `error` file a client component:** Next.js requires it.
- **Never hand-roll route-level code splitting:** the App Router already splits by route.
- **Load a heavy client component or a below-the-fold tree with `next/dynamic`, in place of the React plugin's `React.lazy`:** its code then loads only when it renders.

## Next.js mechanisms for the shared standards

- **Persistence:** scope a transaction to one Server Action or route handler invocation, never split across round-trips: a split leaves a half-applied change when a later call fails or never comes.

## Lints

- **Honor `@next/eslint-plugin-next` (`next/core-web-vitals`) where the project configures it:** it catches Next.js misuse the language plugin's lints don't know. A rule of it turned off or down in the project's lint config is a finding; a reasoned line-level disable follows the language plugin's Lints.
- **With no Next.js lint configured,** the language plugin's Lints apply.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default router (Toolchain) | App Router | not verified by a command: the legacy assumption, kept on 2026-10-31 |
| Default Next.js major (Toolchain step 3) | none | not verified by a command: no source read names one, kept on 2026-10-31 |
