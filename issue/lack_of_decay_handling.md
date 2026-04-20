# `MathLib.calculateQuoteTokenQty` uses internal balances during swaps allowing swappers to extract excess quote tokens after positive rebases

## Summary

The `calculateQuoteTokenQty()` function calculates swap returns using internal base token reserves instead of actual external balances. When an elastic base token rebases upward (decay up), the swap formula uses a smaller-than-actual base token reserve in its denominator, returning disproportionately more quote tokens to the swapper than the true pool ratio dictates.

## Root Cause

### Normal Flow

During a swap, the AMM invariant should dictate that adding base tokens to a pool that grew its base token reserve yields fewer quote tokens compared to before the growth, as base tokens have become relatively less valuable in the pool.

However, the protocol calculates the swap return based on internal accounting rather than the real external balance:

- `elasticswap/src/libraries/MathLib.sol` [#L770-L800](https://github.com/ElasticDAO/shadow-arena-elasticswap)

```solidity
    function calculateQuoteTokenQty(
        uint256 _baseTokenQty,
        uint256 _quoteTokenQtyMin,
        uint256 _liquidityFeeInBasisPoints,
        InternalBalances storage _internalBalances
    ) public returns (uint256 quoteTokenQty) {
        require(
            _baseTokenQty > 0 && _quoteTokenQtyMin > 0,
            "MathLib: INSUFFICIENT_TOKEN_QTY"
        );

@>      quoteTokenQty = calculateQtyToReturnAfterFees(
            _baseTokenQty,
@>          _internalBalances.baseTokenReserveQty,
            _internalBalances.quoteTokenReserveQty,
            _liquidityFeeInBasisPoints
        );

        require(
            quoteTokenQty > _quoteTokenQtyMin,
            "MathLib: INSUFFICIENT_QUOTE_TOKEN_QTY"
        );
        // ...

```

Here, `_internalBalances.baseTokenReserveQty` is passed to `calculateQtyToReturnAfterFees` as the initial `_tokenAReserveQty`.

In the event of a positive rebase ("decay up"), the real external balance of base tokens in the contract increases and strictly exceeds `_internalBalances.baseTokenReserveQty`. The mathematical formula for returning quote tokens is `(dALessFee * _tokenBReserveQty) / (_tokenAReserveQty * BASIS_POINTS + dALessFee)`. By passing the smaller, un-updated `_internalBalances.baseTokenReserveQty`, the denominator becomes smaller, resulting in a significantly larger return amount (`quoteTokenQty`).

The swapper effectively bypasses the price impact of the positive rebase, extracting more quote tokens than mathematically permitted by the actual tokens present in the pool.

## Impact

Users swapping base tokens for quote tokens immediately following a positive rebase will systematically receive more quote tokens than they are mathematically entitled to. This broken pricing dynamic directly drains quote token liquidity from LPs, giving swappers an artificially favorable execution rate and degrading the invariant of the pool.

## Likelihood

- **Trigger:** Anyone can trigger this by executing a swap of base tokens to quote tokens immediately after a positive rebase occurs.
- **Cost:** Cost of the swap fee and basic gas fees.
- **Limiting factors:** The exploitability directly scales with the size of the positive rebase; very small rebases might not cover the 0.3% implicit liquidity fee, but any substantial rebase creates an immediate, risk-free arbitrage opportunity against the LPs.

## Proof of Concept

### Attack Scenario

1. **Initial State:**
   - The liquidity pool contains 1,000 `baseToken` (an elastic supply token) and 1,000 `quoteToken` (a stablecoin like USDC).
   - Under the hood, `_internalBalances.baseTokenReserveQty` = 1,000 and `_internalBalances.quoteTokenReserveQty` = 1,000.

2. **Decay Up (Positive Rebase):**
   - The elastic `baseToken` experiences a 10% positive rebase.
   - The pool's actual external balance of `baseToken` increases to 1,100.
   - The `_internalBalances` are completely unaware of this and still track `baseTokenReserveQty` as 1,000.

3. **The Swap Execution:**
   - Immediately after the rebase, an attacker calls `swapBaseTokenForQuoteToken(100 baseTokens)`.
   - `MathLib.calculateQtyToReturnAfterFees` calculates the swapper's return using the 1,000 internal `baseToken` reserve instead of the actual 1,100 reserve.

4. **Value Extraction (Mathematical Proof):**
   - **What it should be (using actual 1,100 reserve):**
     `(99.7 * 1000) / (1100 + 99.7)` = **83.10** quote tokens out.
   - **What actually happens (using internal 1,000 reserve):**
     `(99.7 * 1000) / (1000 + 99.7)` = **90.66** quote tokens out.
5. **Result:** The attacker received ~9% more quote tokens (90.66 instead of 83.10) for their 100 base tokens than the pool's true reserves should allow. This systematic overcharge drains quote tokens directly from the liquidity providers.

## Recommended Mitigation

Ensure `calculateQuoteTokenQty` takes into account the actual `IERC20(baseToken).balanceOf(address(this))` when processing the swap. If the external balance indicates a positive rebase, the pool should adjust the `_tokenAReserveQty` upwards or recalculate the implied reserve ratio similar to how `calculateBaseTokenQty` currently handles decay down states, ensuring swappers do not receive an artificially better price.
