# ElasticSwap

ElasticSwap is an Automated Market Maker (AMM) built to support elastic supply (rebasing) tokens. It uses the constant product formula `x * y = k` at its core, extended with a novel mathematical model for handling supply changes in the base token.

## Architecture

| Contract | SLOC | Description |
|----------|------|-------------|
| Exchange.sol | 326 | AMM pair contract. Handles addLiquidity, removeLiquidity, and swaps. Inherits ERC20 for LP tokens. |
| ExchangeFactory.sol | 85 | Factory for deploying new Exchange pairs. Manages fee address. |
| MathLib.sol | 709 | Core math library. All AMM calculations: swap amounts, LP token minting, decay handling, fee calculation. |

**Total in scope: ~1,120 SLOC across 3 contracts**

## Key Concepts

**Base Token** vs **Quote Token**: Each Exchange pair has a base token (which may rebase/change supply) and a quote token (fixed supply, e.g., WETH or a stablecoin).

**Decay**: When the base token rebases (supply increases or decreases), the actual balance held by the Exchange diverges from its internally tracked reserves. This imbalance is called "decay." ElasticSwap's novel contribution is handling this decay so LPs receive their expected rebase while still providing liquidity.

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

## Scope Notes

- All source code in `src/contracts/mocks` is out of scope (testing only)
- Fee-on-transfer tokens are NOT supported
- The math model is documented in the [ElasticSwap Math document](https://github.com/ElasticSwap/elasticswap/blob/develop/ElasticSwapMath.md)
