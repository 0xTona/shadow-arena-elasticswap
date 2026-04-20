# ElasticSwap

ElasticSwap is an Automated Market Maker (AMM) built to support elastic supply (rebasing) tokens. It uses the constant product formula `x * y = k` at its core, extended with a novel mathematical model for handling supply changes in the base token.

## Architecture

| Contract | Lines | Description |
|----------|-------|-------------|
| Exchange.sol | 326 | AMM pair contract. Handles addLiquidity, removeLiquidity, and swaps. Inherits ERC20 for LP tokens. |
| ExchangeFactory.sol | 84 | Factory for deploying new Exchange pairs. Manages fee address. |
| MathLib.sol | 709 | Core math library. All AMM calculations: swap amounts, LP token minting, decay handling, fee calculation. |

**Total in scope: ~1,119 lines (~739 SLOC) across 3 contracts**

## Key Concepts

**Base Token** vs **Quote Token**: Each Exchange pair has a base token (which may rebase/change supply) and a quote token (fixed supply, e.g., WETH or a stablecoin).

**How Rebasing Works**: A rebase changes `balanceOf()` for all holders without emitting a transfer event. After a rebase, `IERC20(baseToken).balanceOf(address(this))` differs from the Exchange's internally tracked `baseTokenReserveQty`. The ratio between external balance and internal reserve is the rebase factor (referred to as "alpha" in the code). The internal base-to-quote ratio is "omega."

**Decay**: The difference between external balance and internal reserve after a rebase. When base token supply increases ("rebase up"), external balance > internal reserve = "alpha decay." When supply decreases ("rebase down"), external balance < internal reserve = "beta decay." ElasticSwap's novel contribution is handling this decay so LPs receive their expected rebase while still providing liquidity.

**Internal Balances**: The Exchange tracks `baseTokenReserveQty`, `quoteTokenReserveQty`, and `kLast` internally. These may differ from actual ERC20 balances due to rebases. The AMM pricing curve operates on internal balances, while actual balances reflect the true token holdings.

**Single Asset Entry**: When decay is present (after a rebase), LPs can add liquidity with only one token to resolve the imbalance. This is a special liquidity provision mode not found in standard AMMs.

**Double Asset Entry**: Standard two-sided liquidity provision (same as Uniswap V2), used when no decay is present.

## Fee Structure

- Total fee: 30 basis points (0.3%), same as Uniswap V2
- 25 BP to liquidity providers, 5 BP to the DAO
- DAO fee is collected as LP token minting (similar to Uniswap V2's protocol fee via sqrt(k) growth)

## Running Tests

```bash
cd elasticswap
npm install
npx hardhat test
```

## Reading Order

Start with **Exchange.sol** (the pair contract, analogous to UniswapV2Pair). Follow calls into **MathLib.sol** for all calculation logic. ExchangeFactory.sol is simple and can be read last.

## What to Look For

- Where actual token balances vs internal reserves are used in formulas
- What protections exist for the first depositor
- How single-asset entry math differs from standard proportional minting

## Scope Notes

- All source code in `src/contracts/mocks` is out of scope (testing only)
- Fee-on-transfer tokens are NOT supported
- The math model is documented in the [ElasticSwap Math document](https://github.com/ElasticSwap/elasticswap/blob/develop/ElasticSwapMath.md)
