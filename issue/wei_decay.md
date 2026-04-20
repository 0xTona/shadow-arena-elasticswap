# Overestimated decay due to nested wDiv scaling forces standard LPs into expensive decay resolution

## Summary

The `isSufficientDecayPresent` function is designed to enforce active decay resolution only when the accumulated base token decay is worth more than "1 unit of quote token". However, due to nested `wDiv` scaling mathematical cancellation, the decay is severely overestimated leading to a 1-wei sensitivity check (where it is evaluated if decay is >= 1 _wei_ of quote token). This flaw incorrectly forces almost all `addLiquidity` actions into complex, gas-heavy, single-asset decay resolution paths for micro-dust imbalances.

## Root Cause

When a user adds liquidity, the protocol checks if there is a significant discrepancy between external and internal balances (decay) caused by rebases. If the discrepancy is "greater than 1 unit of quote token" as the developer commented, the user must resolve it first.

```solidity
    function isSufficientDecayPresent(
        uint256 _baseTokenReserveQty,
        InternalBalances memory _internalBalances
    ) public pure returns (bool) {
        return (wDiv(
@>          diff(_baseTokenReserveQty, _internalBalances.baseTokenReserveQty) * WAD,
            wDiv(
                _internalBalances.baseTokenReserveQty,
                _internalBalances.quoteTokenReserveQty
            )
@>      ) >= WAD); // the amount of base token (a) decay is greater than 1 unit of quote token (token b)
    }
```

The developer intended to evaluate the quote token value of the decay and check if it is `>= 1` full token. However, `wDiv(a, b)`calculates`(a \* WAD) / b`.

Let `dX` = base token decay, `inX` = internal base tokens, and `inY` = internal quote tokens.

By expanding the nested `wDiv` functions, the return condition evaluates mathematically to:
`((dX * WAD) * WAD) / ((inX * WAD) / inY) >= WAD`

Simplifying the fraction and dividing by `WAD` reveals the true condition:
`(dX * inY) / inX >= 1`

Because `WAD` cancels out entirely from the threshold, the function is evaluating whether the decay is worth **>= 1 quote token wei** (e.g., 0.000001 USDC or 0.000000000000000001 WETH)—not 1 full token calculation. This effectively overestimates the decay constraint dramatically.

## Impact

1. **Passive Gas Inflation:** Any rebase of the elastic base token that alters the pool's external balance by even a tiny fraction of a cent (equivalent to 1 quote token wei) will trigger `isSufficientDecayPresent` as `true`. Normal users calling `addLiquidity` with standard double-asset parameters will be unexpectedly forced into the `calculateAddQuoteTokenLiquidityQuantities` logical branches, subjecting them to significantly higher gas costs.
2. **Active Griefing Attack:** Because the threshold is so low, a malicious actor can actively grief the liquidity pool by transferring just 1 wei of `baseToken` directly to the `Exchange` contract. This artificial decay trips the 1-wei threshold, guaranteeing that the next genuine liquidity provider is forced to pay the inflated gas cost to resolve the microscopic 1-wei "decay" before they can deposit.

## Likelihood

- **Trigger Scope:** Guaranteed to trigger upon the smallest rebase update, or can be triggered manually by an attacker at will.
- **Cost:** Virtually zero cost to the attacker (1 wei of base token). This is an intrinsic logical bug affecting the core UX of the protocol for all users.

## Proof of Concept

### Attack Scenario (Active Griefing)

1. An attacker observes a target ElasticSwap pool operating normally without any pending rebases.
2. The attacker directly transfers 1 wei of `baseToken` to the `Exchange` contract.
3. The pool's external balance now exceeds the internal balance `inX` by 1 wei.
4. An everyday user calls `addLiquidity` to pair 100 USDC and 100 base tokens.
5. `MathLib.calculateAddLiquidityQuantities()` evaluates `isSufficientDecayPresent()`. The function calculates the decay: `(1 * inY) / inX >= 1`, which evaluates to `true`.
6. Instead of executing a simple double-asset deposit, the user's transaction is forcefully routed into the single-asset decay resolution path to "clean up" the attacker's 1 wei dust, penalizing the user with inflated gas costs and unnecessarily complicating the LP's position.

## Recommended Mitigation

Multiplying `WAD` by the quote token's precision to scale the check from 1 wei up to 1 full token, effectively enforcing the developer's original intent.

```diff
    function isSufficientDecayPresent(
        //...
+       uint256 _quoteTokenDecimals
    ) public pure returns (bool) {
        return (wDiv(
            diff(_baseTokenReserveQty, _internalBalances.baseTokenReserveQty) *
                WAD,
            wDiv(
                _internalBalances.baseTokenReserveQty,
                _internalBalances.quoteTokenReserveQty
            )
-       ) >= WAD);
+       ) >= WAD * (10 ** _quoteTokenDecimals));
    }
```
