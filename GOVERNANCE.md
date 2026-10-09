# Governance

## Who decides

PostLayer is maintained by [@PramodTKodag](https://github.com/PramodTKodag), who has the final say on scope, design and releases. Contributions are welcome through pull requests; see [CONTRIBUTING.md](CONTRIBUTING.md).

## How changes are made

- Every change goes through a pull request that passes `make ci`. Nobody pushes to `main`, including the maintainer.
- Only the maintainer merges, tags and releases.
- Anything that touches funds, access control, upgrades or storage layout needs a written explanation and tests, and is reviewed more strictly.
- `CODEOWNERS` lists the files that always need the maintainer's review (deployment configuration, funding, ownership of the release tooling).
- Larger design changes are discussed in an issue or a Discussion before code is written.

## Releases

Versions are git tags and are recorded in [CHANGELOG.md](CHANGELOG.md). No release is audited or supported yet; see [SECURITY.md](SECURITY.md).

## Code of conduct

All spaces follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Changing this document

By pull request, like any other change.
