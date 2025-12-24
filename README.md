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

Notes
- This is an educational minimal implementation. Do NOT use in production without audits and safety improvements (oracles, fees, partial liquidation, multi-collateral support, pausing, access control, etc.).
