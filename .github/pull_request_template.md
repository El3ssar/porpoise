## What this changes

<!-- What and why. Screenshots or a short recording help for anything visible. -->

## How I tested it

<!-- Give exact commands/results. Distinguish focused tests, full watchdog/coverage, shipping build and UI checks. -->

## Checklist

- [ ] Focused tests and full `scripts/test-with-watchdog.sh --enable-code-coverage` pass; `python3 scripts/coverage.py --min 92` passes
- [ ] `swift build -c release --product Porpoise` and `swift format lint --strict -r Sources Tests` pass
- [ ] Tried visible changes in an isolated app instance in light and dark (see CONTRIBUTING.md); attached evidence and stated any unverified behavior
- [ ] Follows the code style in CONTRIBUTING.md

<!-- Maintainers: add release:patch, release:minor or release:major before merging to publish a new version. -->
