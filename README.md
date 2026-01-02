# CDP Stablecoin (Foundry)

This repository contains a compact collateralized debt position (CDP) stablecoin implementation and a test-suite (Foundry).
The system is intentionally minimal for learning and experimentation. The project implements multi-collateral positions, user-chosen
collateralization ratios, liquidation, and a protocol treasury that accrues fees from liquidations.

**Quickstart**
- **Install Foundry:** https://book.getfoundry.sh/
- **Install test helpers:**
```bash
forge install foundry-rs/forge-std
```
- **Run tests:**
```bash
forge test -v
```

**Core Contracts**
- `src/CDPStablecoin.sol`: The primary contract. It implements an ERC20 stablecoin (the protocol mints `cUSD`) and the CDP logic (deposit, withdraw,
	mint, repay, liquidation, treasury bookkeeping and admin controls).
- `src/MockOracle.sol`: A simple Chainlink-style mock aggregator used by tests.
- `src/SimpleERC20*.sol`: Test tokens (different decimals) used in the test-suite.

**Recent design highlights**
- **OpenZeppelin-style dependencies vendored locally:** The CDP contract now uses OpenZeppelin-compatible `ERC20` (vendored here as a compact
	implementation), `Ownable`, and `ReentrancyGuard` semantics. These live under `lib/openzeppelin-contracts/` to keep the project self-contained for
	testing.
- **Treasury merged into CDP contract:** Seized fees from liquidations are tracked in `treasuryBalance[token]` (mapping of token address to amount).
	This avoids an external `Treasury` contract in tests and provides owner controls directly on the CDP contract.

**Key workflows & semantics**
- **Deposit collateral:** `depositCollateral(token, amount)` — caller must `approve` the CDP contract first.
- **Set collateralization ratio:** `setCollateralizationRatio(token, percent)` — users choose their own ratio but it must be >= `MIN_COLLATERAL_RATIO` (110%).
- **Mint stablecoin:** `mint(token, amount)` — mints `cUSD` up to the allowed amount given the user's collateral and chosen ratio.
- **Repay / burn:** `repay(amount)` — pulls `cUSD` from the caller and burns it, reducing per-token debts proportionally.
- **Liquidation:** `liquidate(user, token, repayAmount)` — when a user's health ratio for that token position falls below `LIQUIDATION_THRESHOLD` (100%),
	a liquidator can repay part of the user's debt and receive collateral. A small fee percent of collateral taken is accrued into
	`treasuryBalance[token]`.

Math note (units):
- All internal USD computations are normalized to 18 decimals.
- Token decimals are read from token contracts (test tokens expose `decimals()` or a public `decimals` getter to be compatible with the helpers).

Liquidation math (summary):
- Given `repayAmount` (cUSD, 18 decimals) the contract calculates how many collateral tokens are needed (using the oracle price normalized to 18 decimals),
	adds the `LIQUIDATION_BONUS` (liquidator incentive), then computes the `LIQUIDATION_FEE` portion to keep in the protocol treasury. The liquidator receives
	the collateral minus the fee; the fee is accounted in `treasuryBalance[token]`.

Events
- `Liquidated(address indexed user, address indexed token, uint256 repaid, uint256 collateralTaken, uint256 treasuryAmount)`
	- `repaid`: stablecoin amount the liquidator repaid and that was burned.
	- `collateralTaken`: gross collateral removed from the user's position (includes bonus to liquidator).
	- `treasuryAmount`: amount of the seized collateral assigned to protocol treasury (kept inside the CDP contract as `treasuryBalance[token]`).

Admin / Owner functions
- `pause()` / `unpause()` — pause protocol actions that are guarded by the `notPaused` modifier.
- `setBlacklist(address who, bool v)` — mark accounts as blacklisted (prevents certain operations).
- `addSupportedToken(token, aggregator)` / `removeSupportedToken(token)` — extend or shrink supported collateral tokens.
- `withdrawTreasury(token, to, amount)` — withdraw protocol treasury-held collateral for `token` (onlyOwner). This reduces `treasuryBalance[token]`.
- `emergencyWithdraw(token, to, amount)` — owner may withdraw tokens that are held by the contract but not reserved for the treasury (i.e., `balanceOf(this) - treasuryBalance[token]`).
	This is useful to recover stray tokens without touching treasury accounting.
- Ownership management is provided by the vendored `Ownable` (`transferOwnership`, `renounceOwnership`).

Helper views
- `estimatedLiquidationPrice(user, token) -> price18` — returns the oracle price (normalized to 18 decimals) at which the given `user`'s
	`token` position would reach the `LIQUIDATION_THRESHOLD` given current collateral amount and outstanding debt. Returns `0` when there is no
	collateral or debt.

Testing notes
- Tests are in `test/` and exercise typical flows: decimals combinations, liquidation fuzzing, rounding/dust edge cases, and the global liquidation
	simulation. The tests use `MockOracle` and local `SimpleERC20` tokens so they are deterministic.

How to extend or change liquidation economics
- To change the split between liquidator and treasury (for example, have the treasury receive the majority and give liquidator only a small
	1% bonus), update the `_computeLiquidationInfo` helper in `src/CDPStablecoin.sol` and adjust tests that assert exact balances or treasury accruals.

Security & audit notes
- This is intentionally small and educational. Real deployments require:
	- Robust oracle protections (staleness, manipulation resistance).
	- More sophisticated liquidation mechanics (partial liquidations, auction, incentives tuning).
	- Safe math beyond Solidity's built-ins where precision matters, and careful edge-case testing for rounding.
	- A governance model and timelocks for sensitive admin operations.
