# Contributing

Thanks for helping. This project handles other people's money, so changes are reviewed carefully.

## Before you start

- Open an issue to discuss anything larger than a small fix.
- Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Setup

You need Docker (with Compose) and `make`. Nothing else.

```sh
git clone <repo-url> && cd postlayer-core
make image      # build the pinned tooling image
make ci         # run everything CI runs
```

Details: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Workflow

1. Branch from `main` (`feat/...`, `fix/...`, `chore/...`, `docs/...`).
2. Write the test first, watch it fail, then write the smallest change that makes it pass.
3. Run `make ci` before pushing. It must pass.
4. Open a pull request using the template. Keep it focused; one concern per PR.
5. Do not push directly to `main`.

## Rules for contract changes

- Follow [docs/CONVENTIONS.md](docs/CONVENTIONS.md).
- A change that weakens a check, widens an owner's power or touches money flow needs a clear explanation in the PR and a test for it.
- Storage changes are append-only and need an upgrade test (deploy old, write state, upgrade, verify).
- Add fuzz or invariant tests for any arithmetic or accounting change.
- No new dependency without a reason in the PR description.
- Keep contracts small; avoid speculative abstractions.

## Commit messages

Short imperative subject (for example `Add ReactionModule`), then a body explaining why when it is not obvious.

## License

By contributing you agree your work is released under the MIT License in [LICENSE](LICENSE).
