# PHP: development

## Defaults when nothing given says otherwise

- **A new dependency goes into `composer.json` only;** its download is left to the human: record it, and a gate step that needs it doesn't run.

## Edge cases

- **The project's PHP version is before 8.0:** write to the features it has, and record which of the Strict typing and modern idioms it can't use.
- **The project configures no static analyser or formatter:** make no project-wide change (`composer.json`, `phpstan.neon`, `psalm.xml`, the formatter config) unless the task covers it; record the change the code needs, with the file it goes in where that file exists.

## Verification gate

Run the full gate on every PHP file written or changed, the project's composer scripts first. Its tools are `php`, `composer` and the tools in the project's `vendor/bin`; a formatter (Pint, php-cs-fixer or phpcs) and PHPStan or Psalm only where the project configures them.

The gate writes only the tools' caches (PHPStan's tmp dir, `.php-cs-fixer.cache`, PHPUnit's result cache) and what the project's tests write.

Run each tool from the project's `vendor/bin`, and never `composer install` or `composer update`. A step that would need a download doesn't run, as for a missing tool. No `php`, no `composer`, or a gate tool missing from `vendor/bin`: each step that needs it doesn't run, with what is missing and its install hint as the reason. A tool missing from `vendor/bin` has the hint `composer install`.

The baseline is steps 1, 2 and 3: each warning, error and finding with its count; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

**Name each finding by its rule id** (PHPStan's error identifier, Psalm's issue type, the php-cs-fixer or phpcs rule): a finding with no id can't be matched against the baseline the gate compares to.

1. The format check (gate `format`), only where the project configures a formatter: `vendor/bin/pint --test`, `vendor/bin/php-cs-fixer fix --dry-run --diff` or `vendor/bin/phpcs`, whichever it configures. It passes when the change adds no unformatted file to the baseline. Not configured: it doesn't run, for the reason "not configured".
2. The syntax check (gate `typecheck`): `php -l <file>` on each changed file.
3. The lint check (gate `lint`), only where the project configures PHPStan or Psalm: the project's composer script that runs it; else `vendor/bin/phpstan analyse` or `vendor/bin/psalm`. Not configured: it doesn't run, for the reason "not configured".
   - **Take the gate's baseline on top of a project's `phpstan-baseline.neon`:** it is part of the project's PHPStan config.
4. The existing tests (gate `test`): the project's `test` script (`composer test`); else `vendor/bin/pest` when the project has it, otherwise `vendor/bin/phpunit`. None: it doesn't run, for the reason "no test command".

PHP has no build step.

## Self-check before reporting

1. The toolchain was settled in the Toolchain order.
2. Every new file declares `strict_types=1`.
3. No loose `==` or `!=` on a value that matters, and each `in_array` and `array_search` passes strict mode.
4. Each `match` over an enum is exhaustive, with no `default`.
5. No empty or over-broad `catch`, and no swallowed exception.
