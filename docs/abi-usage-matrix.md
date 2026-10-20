# Helpers public execution ABI usage matrix

The consolidated candidate has 43 base selectors, one retained Market
exact-output selector and one universal exact-input selector (45 total).
`generated/abi/HelpersDiamond.json`, `HelpersMarket.json` and
`HelpersExactInput.json` are the three generated surfaces. This is a local
release candidate; exporting an ABI does not install a selector.

## Universal exact input

`executeExactInput(ExactInputPlan, FundingBundle)` is the single payable
exact-input execution entrypoint. Its four intents are:

| Intent | Original funding | Recipient outcome |
| --- | --- | --- |
| `BuyCygld` | one exact ETH or ERC20 amount | net CYGLD from ordered Core/Market branches |
| `SellCygld` | one exact gross CYGLD amount | net ETH/ERC20 plus any positive recovery shares |
| `IssueBasket` | complete ordered exact ERC20 basket vector | Core issuance plus mandatory residual Market continuation |
| `RedeemBasket` | one exact gross CYGLD amount | complete ordered Core ERC20/ERC1155 vector |

A scalar plan may split between multiple Core and Market branches. AMM
subplans support split V2/V3/V4 paths and explicit ETH/WETH transitions.
Core calls use actual measured lots and the complete current ordered basket or
redemption descriptors. The implementation enters the existing shared pause
and reentrancy boundary once; modules never call guarded public trade selectors.

Each newly requested allowance or ERC2612/Permit2 authorization is the declared
exact original input. An already sufficient allowance remains usable. Helpers
acquires that amount once. `FundingBundle.authorizations` is aligned with all
original inputs; Permit2's single batch contains only positive Permit2-funded
ERC20 entries. Native input requires `msg.value` to equal the declared native
amount. Native output and actual native V4 currencies use `address(0)`;
WETH remains a distinct ERC20.

Measured unused AMM input is an explicit protocol charge, retained in its
physical currency at Helpers and excluded from later branch spending. There
is no full-consumption rejection or user withdrawal ledger. Successful Core
issuance residuals instead follow the declared continuation, including a
canonical PAXG/CYGLD final conversion. Zero lots skip their swap and literal
Market fee. Core Helpers fees and literal Market fees remain separate from
retained assets; all favorable recipient output is paid out.

`TradeResult` and the sole `ExactInputExecuted` event report acquired inputs,
measured stages, recipient outputs, recovery shares, physical retained input,
Core protocol fees, Helpers fees, Market fees, retained custodian and actual
fee beneficiary. Consumers must not sum underlying Core logs into this outcome.
The universal plan carries an optional deadline (`0` preserves no router expiry).

## Retained exact output

| Flow | Allowance | ERC2612 | Permit2 |
| --- | --- | --- | --- |
| Issue exact CYGLD from ERC20 | `issueFromTokenExactOut` | `issueFromTokenExactOutWithPermit` | `issueFromTokenExactOutWithPermit2` |
| Issue exact CYGLD from ETH | `issueFromNativeExactOut` | — | — |
| Issue exact CYGLD from the complete basket | — | `issueFromBasketExactOutWithMixedPermits` (per-input authorization) | `issueFromBasketExactOutWithPermit2` |
| Market exact output | `swapExactOutput` funding mode | same selector | same selector |

These seven executors retain their public tuple ABI and refund economics.
Token/native routed issuance acquires its maximum budget and refunds unused
input in the same transaction. Basket issuance pulls fresh Core lots within
signed ceilings. Core settlement uses the same measured issuance routine as
the universal engine; it is compiled inline for retained facets and linked
for the universal facet's EIP-170 budget.

The App's output-target Core-sale construction solves an exact CYGLD input;
its fresh universal quote adopts disclosed retention. It is not one of the
seven true exact-output executors. Captured old plans must be refreshed through
ordinary quotation, never relabeled with the new payload or economics.

## Retained previews

All six existing exact-input views remain:
`previewIssueFromTokenExactIn`, `previewIssueFromNativeExactIn`,
`previewIssueFromBasketExactIn`, `previewRedeemToTokenExactIn`,
`previewRedeemToNativeExactIn` and `previewRedeemToBasketExactIn`.

Four exact-output views remain: `previewIssueFromTokenExactOut`,
`previewIssueFromNativeExactOut`, `previewIssueFromBasketExactOut` and
`previewRedeemToBasketExactOut`. A view's direction does not imply that its
former specialized execution selector remains installed. Share-only scalar
redemption still allows a zero aggregate minimum; positive ERC20 redemption
requires the existing positive aggregate minimum.

## Adapter and migration bindings

The new facet binds Permit2 and the successor `UniswapRoutingAdapter`
immutably. There is no new mutable default-adapter slot in the Diamond and no
per-plan arbitrary target. The existing adapter-approved set is checked when
an AMM is actually invoked. Core-only identity routes need no adapter call.

The successor public payload omits hooks and hook data. Mandatory upstream V4
structures receive zero hooks and empty data. Adjacent compatible V4 hops use
`PathKey[]` / `SWAP_EXACT_IN`; repeated currencies split groups while preserving
the whole-subplan intermediate accounting rule. Supported homogeneous ERC20
exact-output V2/V3/V4 payloads preserve refunds; native/mixed exact-output
expansion is outside this release.

`script/config/helpers-exact-input-migration.json` freezes the 12 execution
retirements (11 base, one Market), six exact-input views, seven exact-output
executors and four exact-output views. Activation precedes caller adoption and
retirement. Both old Uniswap adapter approvals are revoked only after consumer
and exact-output encoder adoption. OneInch is outside that retirement.

The test-only `test/fixtures/legacy-exact-input/` archive preserves the former
54-selector base and two-selector Market surfaces for historical regression
qualification. It is not installed by the current production deployment helper.
