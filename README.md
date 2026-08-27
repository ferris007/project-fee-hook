# project-fee-hook

A Uniswap v4 hook that charges one disclosed **1% fee on every swap** in **one designated pool** and routes it to a
treasury.

Unaudited and undeployed. See [Status](#status).

## What it does

The hook charges its fee on the swap's **specified** leg — the side the trader pins:

| Swap type | Specified leg | Effect |
| --- | --- | --- |
| Exact input | Input currency | Trader spends exactly the amount they named; the output shrinks by the fee. |
| Exact output | Output currency | Trader receives exactly the amount they named; the input grows by the fee. |

Charging the specified leg means the returned delta is `+fee` in both cases, so a single sign rule covers all four
direction/exactness quadrants — no `hookData` witness, no partial-fill dependency, no exact-input/exact-output
inversion. The rate is bounded well below 100%, so the residual AMM leg never crosses zero.

## The fee

```
fee = |amountSpecified| * 10_000 / 1_000_000     // 1.00%
```

The total is **inclusive, never additive**. The protocol share is carved out of the 1%, not added to it:

| Share | Rate | Recipient |
| --- | --- | --- |
| Protocol | 1_000 / 1_000_000 (10 bps) | `protocolFeeRecipient` |
| Treasury | 9_000 / 1_000_000 (90 bps) | `treasury` |
| **Total charged** | **10_000 / 1_000_000 (100 bps)** | — |

A trader is never charged more than the disclosed 1%. `quoteFee()` is a `pure` view so any trading surface can
disclose the exact charge before a swap is signed.

## Design guarantees

- **No custody.** Fees mint as ERC-6909 claims directly to each recipient. The hook never holds a balance, so there is
  nothing to drain, rescue, or mis-account.
- **No redirection.** Both recipients are `immutable`, set at deploy. Neither can be changed, and neither can redirect
  the other's share.
- **One pool.** v4 initialization is permissionless, so `beforeInitialize` rejects every key but the designated
  one. No third party can attach a pool to this hook, and `totalFeesAccrued` is a figure no outside pool can inflate.
- **Minimum permissions.** Only `beforeInitialize`, `beforeSwap`, `afterSwap` and `beforeSwapReturnDelta` are
  enabled; the other 10 are disabled.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) and Node.js.

```bash
npm install     # pins v4-core 1.0.2, v4-periphery 1.0.3, OZ 5.6.1, uniswap-hooks 1.1.1
forge test
```

28 tests cover the four swap quadrants, exact-amount preservation, rounding at and below the charge threshold, share
conservation under fuzzing, unauthorized direct callbacks, pool isolation, rejection of undesignated pools,
single-collection, claim redemption, partial-fill reverts, permission-mask encoding in the deployed address, and a
reconciliation invariant.

## Status

**Unaudited. Undeployed. Not submitted, not approved.**

Passing tests are implementation evidence, not an audit, a deployment, or an approval. This hook has never run against
a live PoolManager, router, or pool. Do not deploy it without an independent audit and real integration testing.

Built with the [Programmable v4 Builder](https://github.com/0xprogrammable/hookbuilder). The initial commit is a
reproducible provenance record from the materializer, which is why it carries a fixed synthetic identity and timestamp.

## License

MIT — see [LICENSE](LICENSE).
