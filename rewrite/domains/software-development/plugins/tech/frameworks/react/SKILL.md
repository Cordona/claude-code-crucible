---
name: framework-react
description: "React rules: toolchain, hooks, effects, state, keys, forms, Server Components, hydration and output safety. Use when writing or reviewing TypeScript that uses React. A framework plugin beside its language plugin. Writes nothing and adds no gate tool. Not for code with no language plugin loaded, pure JavaScript, Remix, React Native, accessibility beyond React's own forms (`standard-accessibility`), or Next.js's and TypeScript's own rules (`framework-nextjs`, `language-typescript`)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: React
---

# Framework: React

## Scope

- **In:** React components and hooks, Server Components included, in a single-page app (Vite, react-router) or under Next.js.
- **In:** React in `.js` and `.jsx` files inside a TypeScript project, as the language plugin covers them; the With TypeScript rules apply only to typed files.
- **Out:** Next.js's own rules (App Router, Server Actions, route handlers, route conventions, `next/dynamic`).
- **Out:** Remix and React Native.

## Toolchain

Settle it after TypeScript's toolchain, before writing a line. Take each fact from the first source below that sets it:

1. The `react` version in `package.json`, else in the lockfile.
2. What the project's own docs on its React code say, where the task's context lists them.
3. Otherwise React 19 (see Version ledger).

- **Treat the React Compiler as on only when** `babel-plugin-react-compiler` is in the dependencies or the build config enables it: otherwise it is off, and each rule below that turns on it takes its off branch.

## With TypeScript

- **Type a component's props explicitly at its boundary,** and let inference type the rest: the props are the contract every caller relies on.
- **Make mutation-sensitive props `readonly`:** a component that mutates a prop in place corrupts the parent's state with no type error on either side.

## Hooks

- **Call hooks only at the top level of a component or a custom hook,** never in a condition or a loop: React matches each hook's state by call order. `use()` alone may be called conditionally, by design.
- **Use `use()`, `useActionState` and `useOptimistic` only for their purpose** (a promise or context, an action's result, a pending value): `useOptimistic` used as general state is thrown away when its action settles.
- **Never mutate the DOM behind React's back or read a ref during render:** React's next render overwrites the DOM change, and a ref isn't set on the first render, so read it in an effect or a handler.

## Effects

- **Use an effect only to synchronize with an external system,** never to derive data: compute what props and state determine during render instead.
- **List every dependency:** a missing one captures a stale closure; use the `setState(prev => …)` updater instead of depending on the current value.
- **Never put an object, array or function literal in a dependency array:** its new identity each render re-fires the effect; depend on primitives, and hoist or memoize the value only when the effect needs the object.
- **Return a cleanup that releases every subscription, timer and listener, from a callback that is never `async`:** what the effect opened otherwise leaks and stacks up, and an `async` callback returns a promise where the cleanup belongs; call an inner `async` function instead.
- **Guard an effect's out-of-order responses with an `AbortController` aborted in its cleanup,** or an ignore flag set there when the call takes no signal: otherwise a slow earlier request overwrites a newer one.

## State

- **Place state as low as it works:** local, then lifted to the nearest common parent, then a server-cache library (such as TanStack Query or SWR) for server data, then the URL for shareable view state; each step up widens what re-renders.
- **Never keep server data in `useState`:** the server-cache library tracks staleness and refetching.
- **Derive state instead of storing it:** a stored copy of what props or state already determine drifts out of step.
- **Keep a context provider's `value` stable:** a new value each render re-renders every consumer.
- **Never expect `useState(prop)` to resync:** it seeds once, so change the subtree's `key` on purpose when the entity it shows changes, and React remounts it with fresh state.
- **Pass an expensive initializer as `useState(() => …)`:** otherwise it runs on every render.

## Server Components, hydration and SSR

- **Where the project renders Server Components (a single-page app has none), make them the default,** with `"use client"` only at the leaf that needs interactivity or browser APIs: each `"use client"` moves its subtree into the client bundle.
- **Never let server-only code or data cross into a client component or its bundle:** it ships secrets and server logic to the browser.
- **Render deterministically:** no `Date.now()`, `Math.random()`, locale or timezone formatting, or browser read during render; gate client-only values behind `useEffect` or `useSyncExternalStore`, since server and client HTML otherwise differ, a hydration mismatch.
- **Never touch `window`, `document` or `localStorage` at module scope or during render:** it crashes server rendering; effects don't run on the server, so read them there.

## Output safety

- **Render text as `{value}`, and sanitize with a maintained library (such as DOMPurify) right before any `dangerouslySetInnerHTML`, whatever the source:** JSX escapes text, so the risk is in opting out, and a trusted source such as a CMS can still carry attacker content.
- **Allow-list the scheme of a supplied `href` or `src`** (`https:`, `mailto:`, relative), rejecting `javascript:` and `data:`: an unchecked scheme is a script-injection sink.
- **Never put a secret or token in client-bundled code, `localStorage` or `sessionStorage`:** any script on the page, an XSS payload included, can read them.

## Inputs, keys, forms and async states

- **Keep each input either controlled (a `value` with its `onChange`) or uncontrolled, never both:** a `value` without `onChange` freezes the input, and flipping between `value` and `defaultValue` is a bug.
- **Key list items by a stable identity, never the index,** where the list reorders, inserts, deletes or is virtualized: an index key binds component state to the wrong row.
- **Build the loading, empty and error states, with error boundaries and Suspense where they fit,** as part of done: async UI without them breaks on the first slow or failed call.
- **Share one Zod schema between client and server:** both sides then check the same shape.
- **Map a parse failure to a field-error state built from the schema's issues, never the raw `ZodError` or its default message in the UI:** each error then shows at its field.

## Render performance

- **Memoize by the React Compiler's state:** with it on, add no `useMemo` or `useCallback` as a habit, since the compiler memoizes; with it off, keep references stable where they gate memoization, since a new inline object, function or array breaks `memo` and re-renders the subtree.
- **Virtualize a list past about 100 rows:** it bounds reconciliation and DOM cost.
- **Load a heavy client tree below the fold with `React.lazy`, inside Suspense and an error boundary:** the tree then leaves the first bundle.
- **Import a module directly where a barrel file would bloat the bundle:** the barrel pulls in code the page never uses.

## Accessibility: React's forms

- **Generate every id a label's `htmlFor` or an `aria-*` attribute points at with `useId`, and write `htmlFor`, never `for`:** JSX takes the DOM property name, and a hand-rolled or module-level id duplicates across list rows and breaks the association.
- **Honor `eslint-plugin-jsx-a11y` where the project configures it,** as Lints below sets for `react-hooks`.

## React mechanisms for the shared standards

- **Observability:** an error boundary that reports to the project's error-tracking sink.
- **Clean code:** stateful logic extracted into a custom hook.
- **Performance and persistence:** no N+1 fetches from a Server Component tree; batch them or fetch them in parallel.

## Lints

- **Honor `eslint-plugin-react-hooks` (`rules-of-hooks`, `exhaustive-deps`) where the project configures it:** it catches the Hooks and Effects breaks above, and it runs in the language plugin's lint. A rule of it turned off or down in the project's lint config is a finding; a reasoned line-level disable complies.

## Version ledger

| Fact | Value |
|---|---|
| Default React major (Toolchain step 3) | 19 |
| React Compiler state when nothing turns it on | off |
