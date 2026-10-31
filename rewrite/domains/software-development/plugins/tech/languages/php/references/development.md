# PHP: development

Apply after `SKILL.md`'s rules, before writing any PHP.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The toolchain found** (PHP version, Composer version, the static analyser and formatter configured, the test runner) -> the report's `toolchain`, because the reviewer judges the code against the PHP version and tools it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, its `gate` value as its step names it, because a gate result the report doesn't show reads as a gate that never ran.
- **Each warning, error or finding that predates your change** goes in its command's `note`, with its count.
- **A step you didn't run** is `not_run`, with its reason in `note`, or `narrowed` when `TASK` narrowed it; never leave it out.

## Defaults when the first message is silent

- **The toolchain** comes from `SKILL.md`'s Toolchain order.

## Edge cases

- **The project's PHP version is before 8.0:** write to the features it has, and record in the report's `decisions` which of `SKILL.md`'s Strict typing and modern idioms it can't use.
- **The project configures no static analyser or formatter:** make no project-wide change (`composer.json`, `phpstan.neon`, `psalm.xml`, the formatter config) unless the task covers it; record the change the code needs in the report's `noticed`.

## Verification gate

Take the baseline before your first edit; run the full gate on every change, before reporting done, on every PHP file written or changed, the project's composer scripts first. Its tools are `php`, `composer` and the tools in the project's `vendor/bin`; a formatter (Pint, php-cs-fixer or phpcs) and PHPStan or Psalm only where the project configures them.

The gate writes only the tools' caches (PHPStan's tmp dir, `.php-cs-fixer.cache`, PHPUnit's result cache) and what the project's tests write.

The gate fetches and installs nothing: run each tool from the project's `vendor/bin`, and never `composer install` or `composer update`. A step that would need a download is `not_run`, as for a missing tool. No `php`, no `composer`, or a gate tool missing from `vendor/bin`: record each step that needs it `not_run`, with a note naming what is missing and its install hint: a hint to record, never a command to run. A tool missing from `vendor/bin` has the hint `composer install`.

Before your first edit, run steps 1, 2 and 3 and record each warning, error and finding with its count as the baseline; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

1. The format check (gate `format`), only where the project configures a formatter: `vendor/bin/pint --test`, `vendor/bin/php-cs-fixer fix --dry-run --diff` or `vendor/bin/phpcs`, whichever it configures. It passes when your change adds no unformatted file to the baseline. Not configured: `not_run`, with "not configured" as its note.
2. The syntax check (gate `typecheck`): `php -l <file>` on each changed file. It passes when your change adds nothing to the baseline.
3. The lint check (gate `lint`), only where the project configures PHPStan or Psalm: the project's composer script that runs it; else `vendor/bin/phpstan analyse` or `vendor/bin/psalm`. It passes when your change adds nothing to the baseline. Not configured: `not_run`, with "not configured" as its note.
4. The existing tests (gate `test`): the project's `test` script (`composer test`); else `vendor/bin/pest` when the project has it, otherwise `vendor/bin/phpunit`. None: `not_run`, with "no test command" as its note.

PHP has no build step.

## Self-check before reporting

1. The toolchain was settled in `SKILL.md`'s order.
2. Every new file declares `strict_types=1`.
3. No loose `==` or `!=` on a value that matters, and each `in_array` and `array_search` passes strict mode.
4. Each `match` over an enum is exhaustive, with no `default`.
5. No empty or over-broad `catch`, and no swallowed exception.
6. Each gate step ran, or is `not_run` or `narrowed` with its reason.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
