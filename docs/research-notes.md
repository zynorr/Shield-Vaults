# Shield Vaults — Ecosystem Research Notes (Sep 2026)

Why liquidation protection is the right product for Stacks right now.
All facts from primary sources (protocol docs, forum, DeFiLlama, official
blogs) as of Sep 2026.

## Market context
- Deep bear: BTC ~$58.5K, STX ~$0.17 (96% off ATH). Stacks Endowment has a
  24-month runway; internal planning assumes BTC could test $50K / STX $0.11.
- 2026 priority #1 across the Stacks ecosystem: Bitcoin Staking. Thesis:
  "STX is the asset you hold to earn yield on your Bitcoin, without custody
  risk, bridging, or cross-chain exposure."
  Flywheel: bonds → LSTs → DeFi → new users.
- H2: incentive-matching program for protocols that source external capital.

## Bitcoin Staking & Genesis Bond (LIVE Sept 2026)
- PoX-5 hardfork: July 30, 2026 (BTC block 960,230). Genesis Bond: Sep 10,
  2026 (block 966,350) — 21Shares, HashKey Cloud, UTXO Mgmt, Sypher bonded
  250 BTC. 3% target BTC APY, 6-month periods, weekly payouts, no slashing.
- Bond = BTC timelocked on Bitcoin L1 (self-custodial) + STX at 5% of BTC value
- Bonding periods open ~monthly; whitelisted during bootstrap; PoX-6
  (permissionless auction) in 6–12 months
- "Self-custodial borrowing against staked BTC is on the roadmap" — protocol
  roadmap item (core-team territory, not ours to build)
- Pooled bond path: Esbee DAO (Fast Pool / Friedger) building sbtc-pool-bond-
  staker contract suite + DAO UI (forum t/18972, Sep 2, 2026)
- Stack Sats program (Sep 10–Dec 10, 2026): 1 BTC/month incentives — Bitflow
  trading + Zest lending (0.25 BTC/mo to sBTC suppliers, 0.25 to USDCx
  borrowers w/ ≥20% LTV). **Liquidated positions excluded from rewards.**
  This is onboarding thousands of new leveraged borrowers right now.

## DeFi protocol inventory (DeFiLlama, Sep 2026, ~$89M TVL)
- Zest $76M (Lending — 85% of TVL; "zero bad debt", V2 live)
- StackingDAO $39M (Liquid staking), Granite $7.2M (Lending, no-rehypothecation)
- Hermetica $6M, Bitflow $2.9M (DEX), Arkadiko $1.4M (CDP), CityCoins $1.4M,
  ALEX $1.3M (DEX), Velar $0.5M, LISA $0.4M (LST), StackSwap $0.1M

## Zest V2 liquidation mechanics (docs.zestprotocol.com)
- Three thresholds per pair (sBTC→USDCx example): LTV-BORROW 70%,
  LTV-LIQ-PARTIAL 85%, LTV-LIQ-FULL ~90–95%
- Partial liquidations + graduated penalties (5% min → 10% max, scaled by LTV)
- Pyth + DIA oracles; liquidation pause + grace period (borrowers can still
  repay during pause)
- KEY CONSTRAINT: Market contract "only callable by users for their own
  positions" → third-party repay-on-behalf likely NOT possible; liquidation
  calls are permissionless. ⇒ Shield Vaults must be a VAULT that owns the
  position.
- Zest has its own "Stacks Vaults" (Levered Bitcoin Staking Vault, 6–8% APY) —
  automated yield strategy, NOT user-position protection. Different product.

## Keeper infrastructure state
- Clarity WG (Aug 18, 2026): "Clarity has no autonomous execution — every
  action needs an externally initiated transaction. Keeper + flag is the
  working pattern." Bitflow keeper architecture is the ecosystem reference.
- Rapha (Apr 2026) proposed a SIP-018 signed-intent stop-loss/execution layer
  (idea only, never built). No liquidation-protection product exists.

## Ecosystem project landscape (duplicate check)
Q1 2026 (15): BigMarket (prediction markets), FlashStack (flash loans),
FlowVault (vault primitives), SatoshiYield (yield aggregation/vaults),
sBTC Pay (merchant payments), sBTC Escrow, ShadowFeed (data marketplace),
Stacks Agent Protocol, Stacks Stablecoin Engine (stablecoin + own liquidations),
Stacks Strategy Protocol (token/liquidity primitives), StacksPot, StackStream
(streaming), VelumX (gasless), VoltFi (gold vault), x402 Stacks (API payments).
Q1 Builder (3): Bitflow Night Owl (CEX/DEX arb), Signal21 (declined), Zero
Authority. Q2 (10): PaySats, Jing (RFQ sBTC swaps), Covault (options), BitYield,
DeepStack, AgentPay, PerkOS, Vibewatch (agent analytics), Privara, Degen Labs.
Community grants (6): BFF.ARMY (education), Stacks Sponsor Network (ads/
discovery), Xtrata Forever Twins (NFTs), dev tooling, DeOrganized passkey
onboarding, HermesBridge (stablecoin bridge — now also a cross-chain
liquidity gateway, forum t/18955).

## In-flight / adjacent (collaborate, don't duplicate)
- 1delta (Achim): scoping unified yield read/write API (forum t/18848)
- Melchizedek4ever: building risk-adjusted yield ranking UI (same thread)
- Stacking Tracker: complete STX stacking analytics + Telegram bot
- sBTC Pulse: sBTC personal dashboard + gamification (hackathon-grade)
- stacks-defi-sentinel: 2024 Builder Challenge whale monitor (not position
  health; low adoption)
- Signal21 runs ecosystem dashboards; Vibewatch does agent-readable analytics

## Confirmed white space (validated against all of the above)
1. **Liquidation protection / collateral risk tools for lending positions** —
   ZERO products exist; Stack Sats is onboarding thousands of new leveraged
   borrowers RIGHT NOW; Zest's own vaults don't do user-position protection.
   ← Shield Vaults targets this gap.
2. On-chain risk disclosure registry/standard — would feed 1delta + Melchizedek
3. Bond (Bitcoin Staking) position tracking/verification for institutions —
   crowded (Esbee DAO, Stacking Tracker, core team tooling)
4. sBTC peg/signer transparency — generic dashboards exist; weak angle
