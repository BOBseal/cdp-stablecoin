# CDP Stablecoin (Foundry)

This minimal Foundry project implements a collateralized debt position (CDP) stablecoin where users choose their own collateralization ratio with a minimum of 110%.

Features
- Users deposit an ERC20 collateral token.
- Users must set a collateralization ratio >= 110% before minting.
- The contract mints a stablecoin `cUSD` to the user up to their allowed amount.
- Basic liquidation: if collateralization falls below 100% anyone can liquidate the position.

Quickstart

1. Install Foundry: https://book.getfoundry.sh/

2. From project root, install `forge-std` for testing:

```bash
forge install foundry-rs/forge-std
```

3. Run tests:

```bash
forge test -v
```

Event semantics
- `Liquidated(address indexed user, address indexed token, address indexed liquidator, uint256 repaid, uint256 collateralTaken, uint256 fee)`
	- Emitted when a liquidation runs. `repaid` is the stablecoin amount burned, `collateralTaken` is the gross collateral amount removed
		from the user's position (before fee), and `fee` is the portion of collateral sent to the treasury. `user`, `token` and
		`liquidator` are indexed for easy querying.

Running tests
- Install Foundry and dependencies

```bash
forge test -v
```

Gas report
- To run tests with a gas report for hot functions:

```bash
forge test --gas-report
```

Files of interest
- `src/CDPStablecoin.sol`: main contract (mint, repay, liquidate, multi-collateral handling)
- `src/MockOracle.sol`: chainlink-like mock price feeds used by tests
- `test/`: unit tests, fuzz tests and edge-case tests (including decimals handling and rounding tests)
 - `docs/liquidation.md`: explanation of liquidation math, decimals handling, fee/bonus calculations, and invariants
Notes
- This is an educational minimal implementation. Do NOT use in production without audits and safety improvements (oracles, fees, partial liquidation, multi-collateral support, pausing, access control, etc.).
