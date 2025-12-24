# Liquidation Math and Invariants

This document explains the liquidation calculations and invariants used by `CDPStablecoin`.

## Definitions

- price18: oracle price normalized to 18 decimals (price * 10^(18 - oracleDecimals)).
- tokenScale: `10 ** tokenDecimals` — used to convert token units to standard 18-decimal value.
- repayAmount: amount of stablecoin (18 decimals) the liquidator wants to burn on behalf of the user.
- collateralAmount: the user's current collateral token balance stored in `positions[user][token].collateralAmount`.

Constants used:
- `LIQUIDATION_BONUS` (percent): bonus awarded to liquidator applied to collateral (e.g., 5 = 5%).
- `LIQUIDATION_FEE` (percent): small portion of collateral swept to the `treasury` (e.g., 1 = 1%).


## Core formulas

1) Convert `repayAmount` (stablecoin) to the raw collateral needed:

   collateralNeeded = (repayAmount * tokenScale) / price18

   - Explanation: repayAmount (USD w/18 decimals) divided by token price (USD w/18 decimals) gives number of tokens.
   - tokenScale adjusts for token decimals (e.g., WBTC with 8 decimals uses 1e8).

2) Apply liquidation bonus to determine gross collateral removed from the user's position:

   collateralToLiquidator = collateralNeeded * (1 + LIQUIDATION_BONUS/100)

3) If `collateralToLiquidator > collateralAmount`, cap collateral taken to the user's entire collateral and compute the repayable stable amount from that collateral:

   if collateralToLiquidator > collateralAmount:
     collateralToLiquidator = collateralAmount
     repayPossible = (collateralAmount * price18) / tokenScale
     adjustedRepay = min(repayAmount, repayPossible)

   - `repayPossible` is the stablecoin amount the `collateralAmount` can cover at the current price.
   - The contract uses `adjustedRepay` (which may be < requested `repayAmount`) for the actual burn and debt reduction.

4) Compute fee & net transfer to liquidator:

   fee = (collateralToLiquidator * LIQUIDATION_FEE) / 100
   netToLiquidator = collateralToLiquidator - fee

   - `fee` is transferred to `treasury` and `netToLiquidator` is transferred to the liquidator.

5) State updates:

   positions[user][token].collateralAmount -= collateralToLiquidator
   positions[user][token].debt -= adjustedRepay

   - Debt is reduced by the burned `adjustedRepay` amount (bounded by previous debt).


## Decimals handling notes

- Oracle decimals are normalized to 18 (`price18`) so price math occurs in 18-decimal units.
- Token decimals (tokenScale) convert token units to and from 18-decimal USD units.
- All stablecoin values are 18-decimals.

Example (WETH 18 decimals):
- price = $2,000 => price18 = 2000 * 1e18
- repayAmount = 1 * 1e18 (i.e., $1)
- tokenScale = 1e18
- collateralNeeded = (1e18 * 1e18) / (2000 * 1e18) = 1e18 / 2000 = 5e14 (0.0005 WETH)

Example (WBTC 8 decimals):
- price = $30,000 => price18 = 30000 * 1e18
- repayAmount = 1 * 1e18
- tokenScale = 1e8
- collateralNeeded = (1e18 * 1e8) / (30000 * 1e18) = 1e8 / 30000 ≈ 3333 (i.e., 0.00003333 WBTC in 8-decimal units)


## Safety invariants

- The function checks the user's per-token `healthRatio` before allowing liquidation. Liquidation only proceeds if:

    currentRatio = (collateralValue * 100) / p.debt < LIQUIDATION_THRESHOLD

- `repayAmount` is not immediately pulled; the contract first computes `adjustedRepay` to avoid burning more stablecoin than the collateral can cover.
- The contract uses safe arithmetic (Solidity 0.8 overflow checks) and bounds reductions to prevent underflows.
- After liquidation:
  - `positions[user][token].debt` is <= previous debt.
  - `positions[user][token].collateralAmount` is <= previous collateral.


## Notes & trade-offs

- The contract performs per-token, per-user liquidation: a liquidator repays debt for a single token position and receives collateral of that token. If a user has multiple collateral tokens, each must be liquidated separately.
- The contract uses on-chain oracle spot price, which can be manipulated in tests — in production, you should prefer TWAP or protected feeds.
- The event `Liquidated(user, token, repaid, collateralTaken, fee)` is intended to give off-chain listeners the final accounting of the liquidation with a small footprint (2 indexed fields).


## Recommended monitoring

- Watch `Liquidated` events, compute the implied price from `repaid` and `collateralTaken` to detect oracle anomalies.
- Monitor `healthRatio` for positions approaching `LIQUIDATION_THRESHOLD` and consider alerts when ratio < 120%.

