# `Exchange.removeLiquidity` improperly deducts external return quantities from internal reserves allowing permanent DoS of the AMM via token donations

## Summary
In `Exchange.removeLiquidity()`, the protocol incorrectly assumes the external and internal balances of the quote token natively remain aligned. When a user removes liquidity, the contract scales their quote token payout against the external balance, but directly subtracts that payout from the internal storage tracking. If a direct transfer (donation/airdrop) inflates the external balance, any subsequent withdrawal payout will exceed its proportional internal share. This forcefully floors the internal quote token reserve to `0`, permanently breaking the pool via division-by-zero reverts.

## Root Cause

### Normal Flow
When a liquidity provider removes liquidity from an AMM, their LP tokens are burned in exchange for their proportional percentage of the pool's external balances. Correspondingly, the AMM's internal reserve variables (`x` and `y`) must be reduced by the exact same proportional percentage to ensure the internal price ratio doesn't warp and values don't overflow.

### The Bug
The protocol implements this perfectly for the `baseToken` by explicitly calculating a completely separate variable to deduct from internal accounting (line 265). However, for the `quoteToken`, it lazily subtracts the calculated external payout directly from the internal reserves:

* `elasticswap/src/contracts/Exchange.sol` #L229-L279
```solidity
        // Calculate proportional external payout
        uint256 quoteTokenReserveQty = IERC20(quoteToken).balanceOf(address(this));
        uint256 quoteTokenQtyToReturn = (_liquidityTokenQty * quoteTokenReserveQty) / totalSupplyOfLiquidityTokens;
        
        // ...
        
        //6.2 {
        // We should ensure no possible overflow here.
        if (quoteTokenQtyToReturn > internalBalances.quoteTokenReserveQty) {
@>          internalBalances.quoteTokenReserveQty = 0;
        } else {
@>          internalBalances.quoteTokenReserveQty -= quoteTokenQtyToReturn;
        }
        //} 6.2
```

Direct transfers to the `Exchange` contract bypass standard internal accounting, safely inflating `balanceOf(address(this))` (or `quoteTokenReserveQty` here) while leaving `internalBalances.quoteTokenReserveQty` identical. 

Because `quoteTokenQtyToReturn` now represents a share of both the legitimate pool **plus** the donated tokens, the withdrawal amount mathematically exceeds the proportional share of the internal balance. The system forcefully subtracts this inflated number from the uninflated `internalBalances.quoteTokenReserveQty`. If the donation was large enough, or if a user removes a massive portion of liquidity after a smaller donation, it triggers the `>` condition and permanently sets the internal quote token reserve to `0`. 

## Impact
Once `internalBalances.quoteTokenReserveQty` hits `0`, the AMM's core $K$ invariant ($x \times y$) is destroyed.
- The AMM spot price effectively becomes zero or infinity.
- Any subsequent calls to `swapBaseTokenForQuoteToken`, `swapQuoteTokenForBaseToken`, or `addLiquidity` will revert permanently due to division-by-zero errors in `MathLib.sol`.
- All remaining liquidity provided by honest users in the pool enters an irreparably locked, unrecoverable state, constituting a complete loss of protocol funds. 

## Likelihood
- **Trigger:** Any external user can intentionally trigger this DoS by directly sending quote tokens to the contract (a griefing attack). Even without an attacker, benign unprompted token airdrops or user mistakes (accidentally transferring tokens to a contract instead of swapping) will naturally trigger this fatal flaw.
- **Cost:** An attacker must sacrifice a certain amount of quote tokens or wait for someone else's accidental transfer. Because it permanently halts the contract and traps all underlying assets, it is highly attractive.

## Proof of Concept

### Attack Scenario
1. **Initial State:** A pool has an internal and external reserve of 1,000 Quote Tokens and 100 outstanding LP tokens. 
2. **The Sabotage:** An attacker executes a single ERC20 `transfer()` of 1,000 Quote Tokens directly to the `Exchange.sol` contract. 
   - External quote balance = `2,000`.
   - Internal quote balance = `1,000`.
3. **The Trigger:** An honest LP holds 60 LP tokens (60% of the pool) and calls `removeLiquidity()`.
4. **The Bad Math:**
   - The contract calculates `quoteTokenQtyToReturn`: `(60 * 2,000) / 100 = 1,200`.
   - The user is sent `1,200` quote tokens. 
   - The contract updates the internal balance: `if (1,200 > 1,000) { internalBalances.quoteTokenReserveQty = 0 }`.
5. **Result:** The internal quote reserve is forever `0`. The pool is locked. Remaining LPs cannot add, trade, or efficiently remove their initial capital structures. 

*(Coded PoC omitted per request)*

## Recommended Mitigation
Do not deduct the external withdrawal amount directly from the internal balances. Mathematically deduce the proportional share of the internal reserve being burned independently, exactly as is already correctly implemented for the `baseToken`.

```diff
        //6.1 {
        uint256 baseTokenQtyToRemoveFromInternalAccounting = (_liquidityTokenQty *
                internalBalances.baseTokenReserveQty) /
                totalSupplyOfLiquidityTokens;

        internalBalances
            .baseTokenReserveQty -= baseTokenQtyToRemoveFromInternalAccounting;
        //} 6.1

        //6.2 {
-       // We should ensure no possible overflow here.
-       if (quoteTokenQtyToReturn > internalBalances.quoteTokenReserveQty) {
-           internalBalances.quoteTokenReserveQty = 0;
-       } else {
-           internalBalances.quoteTokenReserveQty -= quoteTokenQtyToReturn;
-       }
+       uint256 quoteTokenQtyToRemoveFromInternalAccounting = (_liquidityTokenQty *
+               internalBalances.quoteTokenReserveQty) /
+               totalSupplyOfLiquidityTokens;
+               
+       internalBalances.quoteTokenReserveQty -= quoteTokenQtyToRemoveFromInternalAccounting;
        //} 6.2
```
