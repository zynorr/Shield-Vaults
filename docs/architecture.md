# Shield Vaults - Architecture

Protection layer for Stacks lending positions. This document describes the
target architecture (v0.1 contract + keeper bot now; registry and SDK layers
in milestones 2-4).

## 1. System overview

```mermaid
flowchart TB
    subgraph "Users"
        B[Borrower]
        K[Keeper]
    end

    subgraph Chain["Stacks mainnet"]
        SV[shield-vault.clar<br/>protected borrow vaults]
        SR[shield-registry.clar<br/>markets, risk params, bounty config]
        Z[Zest Stacks Market V2]
        T[Tokens sBTC / USDCx]
    end

    subgraph Offchain["Off-chain services"]
        KB[Keeper bot<br/>watch, trigger, execute]
        API[Vault indexer + API<br/>state for UIs]
        AL[Alerting<br/>Telegram / email]
    end

    subgraph Dist["Distribution"]
        W[Wallets<br/>Leather / Xverse / Asigna]
    end

    B -->|open-vault: deposit collateral + buffer| SV
    SV -->|deposit + borrow as vault principal| Z
    SV -->|SIP-010 transfers| T
    SR -->|whitelisted markets + risk params| SV
    K -->|read Health Factor, read-only| Z
    K -->|keeper-rescue when trigger breached| SV
    KB --> API
    API --> AL
    W -->|SDK: position health + one-tap protection| SV
```

## 2. Contracts & on-chain layer

```mermaid
flowchart LR
    subgraph Contracts["Clarity contracts (deployer principal)"]
        SV[shield-vault.clar]
        SR[shield-registry.clar]
        LT[lending-market-trait]
        ST[sip010-trait]
    end

    Z[Zest Stacks Market V2]
    G[Granite lending]
    T[sBTC / USDCx tokens]

    SV -->|dispatch through| LT
    SV -->|dispatch through| ST
    LT -.->|implemented by| Z
    LT -.->|implemented by| G
    ST -.->|implemented by| T
    SR -->|per-market trigger bounds, bounty cap, buffer cap| SV
```

- **shield-vault.clar (v0.1)** - vault lifecycle: `open-vault`,
  `keeper-rescue`, `user-repay`, `user-topup`, `close-vault`,
  `register-monitor`. The vault is the position principal on the lending
  market. No admin key, no upgrade path.
- **shield-registry.clar (milestone 2)** - whitelist of audited lending
  markets, per-market risk parameters (trigger bounds, bounty cap, buffer
  cap), keeper discovery data. Read-only for vaults; makes multi-protocol
  support safe and configurable without touching the vault contract.
- **Traits** - `lending-market-trait` and `sip010-trait` decouple the vault
  from any single protocol. Adding Granite = one registry entry + trait
  conformance check, zero vault changes.

## 3. Off-chain layer - keeper bot

```mermaid
flowchart LR
    Z[Zest V2<br/>Health Factors + events] -->|Chainhooks / poll| W[Watcher]
    W --> E{Trigger engine<br/>HF less than user trigger?}
    E -->|no| W
    E -->|yes| G[Gas + bounty check<br/>profitable?]
    G -->|yes| T[Build keeper-rescue tx]
    T --> B[Broadcast + confirm]
    B --> N[Notify user<br/>Telegram / email]
    N --> P[Publish proof tx + update API]
    G -->|no| W
```

- **Watcher** - subscribes to position/price state via Chainhooks events or a
  block-level poll; never holds keys beyond a hot wallet for gas.
- **Trigger engine** - compares live Health Factor against each vault's
  trigger; only profitable rescues (bounty > gas) are proposed.
- **Executor** - builds and broadcasts `keeper-rescue`; the contract's
  post-state check guarantees the keeper is only paid when safety is
  actually restored.
- **Alerting + API** - every state change is surfaced to the user and to the
  public vault indexer.

## 4. Vault lifecycle

```mermaid
stateDiagram-v2
    [*] --> Active : open-vault
    Active --> Active : user-repay<br/>user-topup<br/>keeper-rescue
    Active --> Closed : close-vault<br/>position fully repaid
    [*] --> Monitor : register-monitor
    Monitor --> Monitor : alerts only<br/>no on-chain action
    Monitor --> [*] : unregister
    Closed --> [*]
```

## 5. Core flow - opening a protected vault

```mermaid
sequenceDiagram
    participant U as Borrower
    participant SV as shield-vault
    participant T as sBTC / USDCx tokens
    participant Z as Zest V2 market

    U->>SV: open-vault(market, tokens, collateral, debt,<br/>amounts, trigger, buffer)
    SV->>T: pull collateral from borrower
    SV->>T: pull repay buffer from borrower
    SV->>Z: deposit-collateral(vault principal)
    SV->>Z: borrow(vault principal)
    SV->>SV: store vault record<br/>trigger-hf, buffer, status active
    SV-->>U: ok
```

## 6. Core flow - keeper rescue

```mermaid
sequenceDiagram
    participant K as Keeper bot
    participant Z as Zest V2 market
    participant SV as shield-vault
    participant T as Debt token

    K->>Z: read Health Factor (read-only)
    Z-->>K: HF below user trigger
    K->>SV: keeper-rescue(market, debt-token, owner, repay-amount)
    SV->>Z: read Health Factor (pre-check)
    SV->>Z: repay-debt(vault principal, repay-amount)
    SV->>Z: read Health Factor (post-check)
    alt post-HF at or above trigger
        SV->>T: pay capped bounty to keeper from buffer
        SV->>SV: debit buffer (repay + bounty)
        SV-->>K: ok true
    else post-HF below trigger
        SV-->>K: err u104 whole tx reverts atomically
    end
```

## 7. Safety invariants

1. **Vault funds only move** to: the lending market (deposit/borrow/repay),
   the vault owner (withdrawals), or keepers (bounty ≤ cap). No other sinks.
2. **No rescue without restoration** - post-state Health Factor must be at or
   above the trigger, otherwise the entire transaction reverts (u104),
   including the bounty.
3. **No griefing healthy vaults** - keeper-rescue reverts when the position
   is above trigger (u103).
4. **Buffer and bounty caps** - buffer ≤ 10% of borrow value; bounty 2% of
   the repaid amount, capped.
5. **No admin, no upgrade path** - after deployment there is no privileged
   caller; risk parameters live in the read-only registry.
6. **Protocol-agnostic via traits** - a new market can be added without
   touching vault code; a broken market can be delisted in the registry.

## 8. Evolution (milestones)

| Milestone | Layer | What changes |
|---|---|---|
| M1 (now) | Contracts | v0.1 vault on testnet, real Zest V2 principals wired |
| M2 | Contracts + off-chain | shield-registry.clar, keeper bot, alerting, monitor-only mode |
| M3 | Product | 25+ protected vaults, first mainnet rescue, user interviews |
| M4 | Distribution | Granite via registry, SDK for wallets, integration demo |

    Monitor --> [*] : unregister
    Closed --> [*]
```
