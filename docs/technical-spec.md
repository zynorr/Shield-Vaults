# TECHNICAL SPEC - Shield Vaults v0.1
Sep 21, 2026

## Goal
Protect user borrow positions on Stacks lending protocols from liquidation
via permissionless keepers, vault-held positions, and a bounty economy.

## Scope (milestone 1-2)
- Protocol: Zest Stacks Market V2 (testnet → mainnet)
- Pair: sBTC collateral → USDCx debt (STX collateral as secondary)
- Granite: milestone 4 (stretch)

## System architecture
Component, contract, keeper-bot, lifecycle and sequence diagrams:
[`architecture.md`](architecture.md).

## Contracts
### 1. shield-vault.clar (core)
- `open-vault`: user sets pair, borrow amount, trigger HF (e.g. 1.15),
  buffer size; vault deposits collateral and borrows via Zest V2
- `keeper-rescue`: callable by anyone when trigger breached; uses buffer to
  repay a pre-computed slice of debt (target HF back above trigger); pays
  keeper bounty (e.g. 2% of repaid amount, capped)
- `user-repay` / `user-topup`: user can always repay or add buffer directly
- `close-vault`: withdraw collateral + buffer when position fully repaid;
  only vault owner
- State: define-map vaults {owner, collateral, debt-asset, trigger-hf,
  buffer, status}; no admin key after launch; pausable only by
  owner-withdrawing-all (no global pause)
### 2. shield-registry.clar (M2+)
- Registry of keeper-set params, bounty config per protocol; read-only
  discovery for keepers and UIs
### 3. Keeper bot (off-chain, TypeScript)
- Polls read-only Zest position health each block (or via chainhook events)
- When HF < trigger: builds and broadcasts `keeper-rescue` tx; monitors
  confirmations; alerts channel (Telegram/email)

## Zest V2 integration facts (validated from public docs)
- Health Factor < 1 → full liquidation eligible; partial slightly above 1
- Per-pair thresholds (example sBTC→USDC): LTV-BORROW 60-70%, partial
  liquidation 70-85%, full 75-90%; graduated penalties 5-10%
- Protocol Deep Dive documents borrow call takes user as parameter:
  market.borrow(usdc-aid, 500, tx-sender, none) → vault-as-principal viable
- Oracles: Pyth + DIA inside Zest's market contract; Shield keepers reuse
  Zest's own read-only health logic (no new oracle trust)
- Liquidation pause + grace period exists on Zest; Shield keeps a wider
  safety margin (default trigger HF 1.15) to absorb such events
- Exact V2 function signatures/principals: verified on testnet during M1
  (Zest publishes V2 contract docs for integrators; fallback: deploy-time
  trait calibration)

## Safety properties
- Vault funds only ever move to: Zest market (deposit/borrow), the user
  (withdrawals), keepers (bounty ≤ cap) - no other destinations
- Buffer is capped (e.g. ≤10% of debt) so keeper bounty can never drain the
  vault; a rescue that fails its post-repay health check reverts atomically
- All keeper calls validate post-state (HF restored ≥ trigger) before paying
  bounty - Clarity post-conditions + in-contract checks
- No upgradability, no admin; informal community review before mainnet,
  formal audit targeted post-launch

## Milestone-1 verification checklist
- [ ] Deploy scaffold on testnet via clarinet; record address
- [ ] Confirm Zest V2 testnet principal + exact `collateral-add`/`borrow`/
      `repay` signatures; wire into shield-vault trait
- [ ] Simulated keeper rescue on testnet (price move via oracle mock)
- [ ] Publish spec + repo

## Risks (mirrors application)
UX friction of moving positions (mitigated: monitor-only mode, one-tx
deposit); Zest integration drift (mitigated: trait + calibration layer);
keeper profitability in low-volatility periods (mitigated: bounty floor +
Stack Sats-era volatility).
