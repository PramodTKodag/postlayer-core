# Conventions

Every name should explain itself. These rules follow the [Solidity style guide](https://docs.soliditylang.org/en/latest/style-guide.html) and widely used team guides ([Optimism](https://devdocs.optimism.io/contracts-bedrock/contributing/style-guide), [Sablier](https://sablier.notion.site/Sablier-Coding-Practices-Contracts-2f5920cf497646b4a2ea982c1bacb5a8)).

## Files and contracts

| Kind | Rule | Example |
|---|---|---|
| Contract or library | PascalCase noun; file name equals contract name | `PostRegistryModule.sol` |
| Interface | `I` prefix | `IPostRegistry.sol` |
| Storage struct | `<Module>Storage` | `PostRegistryStorage` |
| Test file | `<Contract>.t.sol` | `TippingModule.t.sol` |
| Script | `<Action>.s.sol` | `DeployPostLayer.s.sol` |

## Code

| Kind | Rule | Example |
|---|---|---|
| Function | camelCase verb phrase | `publishPost`, `tipPost` |
| Internal or private function | leading underscore | `_splitTip` |
| State variable | camelCase, no abbreviations | `postCount` |
| Constant or immutable | UPPER_SNAKE_CASE | `MAX_PLATFORM_FEE_BPS` |
| Event | past tense PascalCase | `PostPublished` |
| Custom error | PascalCase, says why | `NotPostAuthor`, `TipBelowMinimum` |
| Role | UPPER_SNAKE with `_ROLE` | `UPGRADER_ROLE` |
| Names with units | include the unit | `feeBps`, `amountWei` |

## Rules

- Custom errors, not revert strings.
- `///` NatSpec with `@notice` on every external and public item.
- `calldata` for external array and string parameters.
- Checks, effects, interactions; `nonReentrant` on functions that pay out.
- No magic numbers; name constants.
- Small files, one purpose each.
- Layout inside a contract: types, state, events, errors, modifiers, constructor, external, public, internal, private.
- Format with `make fmt`; CI runs `make fmt-check`.

## Tests

Format: `test(Fuzz)?_(RevertWhen_)?<behavior>`.

- `test_publishPost_succeeds`
- `test_RevertWhen_callerIsNotPostAuthor`
- `testFuzz_tipPost_splitsAmountExactly`
- `invariant_noFundsHeldAfterTip`
