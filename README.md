## Found Bugs

The full technical reports for the following vulnerabilities can be found in the [issue](issue/) directory.

1. **Precision loss in nested scaling overestimates decay**, forcing excessive gas costs for LPs
2. **Internal reserve accounting mismatch** enables profit extraction via base token rebases
3. **Mismatched withdrawal accounting** allows permanent protocol DoS via direct token donations

## Missed Bugs (3/3)

1. `In the case of Single Asset Entry, new liquidity providers will suffer fund loss due to wrong formula of ΔRo`
   &rarr; Overlooked because the complex mathematical derivation of this specific formula was initially skipped during the audit.
2. `Transferring quoteToken to the exchange pool contract will cause future liquidity providers to lose funds`
   &rarr; Initially dismissed under the assumption that the attacker's upfront capital loss would outweigh any potential profit. The logic assumed profitability was only possible if the attacker was the sole liquidity provider—a scenario viewed as a duplication of a "first depositor" bug (the reasoning for which is detailed in the next point).
3. `The value of LP token can be manipulated by the first minister, allowing future shares to be diluted`
   &rarr; Missed due to an incorrect assumption that the user-defined `min` slippage parameters would mitigate this manipulation; in reality, those parameters address separate protocol behaviors.

## Resources

- [Zenlynx shadow arena](https://academy.zealynx.io/shadow-arena/elasticswap)
- [Code4rena report](https://code4rena.com/reports/2022-01-elasticswap)
