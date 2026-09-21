;; shield-vault.clar - Shield Vaults scaffold v0.1
;; PoC scaffold. Deploy on Stacks TESTNET via clarinet.
;;
;; STATUS: scaffold. The lending market and tokens are passed as TRAIT
;; PARAMETERS (dynamic dispatch), so this contract compiles standalone.
;; Wire the real Zest V2 principals + signatures in milestone 1.
;;
;; Design notes (mirrors technical-spec-shield-vault.md):
;; - Vault is the position principal (Zest docs: borrow takes user as param)
;; - Permissionless keeper-rescue only when trigger-hf breached; bounty capped
;; - Post-state validated before bounty payout; reverts atomically otherwise
;; - No admin key, no upgrade path

(define-trait lending-market-trait
  (
    ;; TODO M1: match Zest V2 signatures exactly (collateral-add / borrow /
    ;; repay with on-behalf parameters per Zest Protocol Deep Dive docs)
    (deposit-collateral (principal uint) (response bool uint))
    (borrow-asset (principal uint) (response bool uint))
    (repay-debt (principal uint) (response bool uint))
    (get-health-factor (principal) (response uint uint))
  )
)

(define-trait sip010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
  )
)

(define-constant BOUNTY-BPS u200)     ;; 2% keeper bounty, capped
(define-constant BUFFER-CAP-BPS u1000) ;; buffer max 10% of borrow amount
(define-constant DEFAULT-TRIGGER-HF u115) ;; HF 1.15 default trigger

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-VAULT-NOT-FOUND (err u101))
(define-constant ERR-VAULT-NOT-HEALTHY (err u102))
(define-constant ERR-TRIGGER-NOT-BREACHED (err u103))
(define-constant ERR-POST-STATE-UNSAFE (err u104))
(define-constant ERR-BUFFER-EXCEEDED (err u105))
(define-constant ERR-AMOUNT-ZERO (err u106))

;; ---------------------------------------------------------------------------
;; State
;; ---------------------------------------------------------------------------
(define-map vaults
  { owner: principal }
  {
    collateral: (string-ascii 32),
    debt: (string-ascii 32),
    trigger-hf: uint,
    buffer: uint,
    status: (string-ascii 16) ;; "active" | "monitor" | "closed"
  }
)

(define-data-var vault-count uint u0)
(define-data-var total-protected uint u0)

;; ---------------------------------------------------------------------------
;; Read-only
;; ---------------------------------------------------------------------------
(define-read-only (get-vault (owner principal))
  (map-get? vaults { owner: owner })
)

;; ---------------------------------------------------------------------------
;; Vault lifecycle (market/tokens passed as trait params)
;; ---------------------------------------------------------------------------
(define-public (open-vault
    (market <lending-market-trait>)
    (collateral-token <sip010-trait>)
    (debt-token <sip010-trait>)
    (collateral (string-ascii 32))
    (debt (string-ascii 32))
    (collateral-amount uint)
    (borrow-amount uint)
    (trigger-hf uint)
    (buffer-amount uint))
  (begin
    (asserts! (> collateral-amount u0) ERR-AMOUNT-ZERO)
    (asserts! (is-none (map-get? vaults { owner: tx-sender })) ERR-VAULT-NOT-FOUND)
    (asserts! (>= trigger-hf u100) ERR-POST-STATE-UNSAFE)
    (asserts! (<= buffer-amount (/ (* borrow-amount BUFFER-CAP-BPS) u10000)) ERR-BUFFER-EXCEEDED)

    ;; TODO M1: real token pulls + Zest deposit/borrow as vault principal
    (try! (contract-call? collateral-token transfer collateral-amount tx-sender tx-sender none))
    (try! (contract-call? debt-token transfer buffer-amount tx-sender tx-sender none))
    (try! (contract-call? market deposit-collateral tx-sender collateral-amount))
    (try! (contract-call? market borrow-asset tx-sender borrow-amount))

    (map-set vaults
      { owner: tx-sender }
      { collateral: collateral, debt: debt, trigger-hf: trigger-hf, buffer: buffer-amount, status: "active" }
    )
    (var-set vault-count (+ (var-get vault-count) u1))
    (var-set total-protected (+ (var-get total-protected) collateral-amount))
    (ok true)
  )
)

(define-public (user-repay (market <lending-market-trait>) (amount uint))
  (begin
    (asserts! (> amount u0) ERR-AMOUNT-ZERO)
    (unwrap! (map-get? vaults { owner: tx-sender }) ERR-VAULT-NOT-FOUND)
    ;; TODO M1: repay on Zest V2 for this vault's position
    (try! (contract-call? market repay-debt tx-sender amount))
    (ok true)
  )
)

(define-public (user-topup (debt-token <sip010-trait>) (amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-VAULT-NOT-FOUND)))
    (asserts! (> amount u0) ERR-AMOUNT-ZERO)
    (try! (contract-call? debt-token transfer amount tx-sender tx-sender none))
    (map-set vaults
      { owner: tx-sender }
      (merge vault { buffer: (+ (get buffer vault) amount) })
    )
    (ok true)
  )
)

(define-public (close-vault (market <lending-market-trait>))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-VAULT-NOT-FOUND)))
    ;; TODO M1: require position fully repaid on Zest + return collateral/buffer
    ;; to owner; set status "closed"
    (asserts! (is-eq (get status vault) "active") ERR-VAULT-NOT-HEALTHY)
    (ok true)
  )
)

;; ---------------------------------------------------------------------------
;; Keeper rescue (permissionless)
;; ---------------------------------------------------------------------------
(define-public (keeper-rescue
    (market <lending-market-trait>)
    (debt-token <sip010-trait>)
    (owner principal)
    (repay-amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND))
        (hf-before (unwrap-panic (contract-call? market get-health-factor tx-sender))))
    (asserts! (is-eq (get status vault) "active") ERR-VAULT-NOT-HEALTHY)
    ;; Trigger check: rescue only allowed when HF below the owner's trigger
    (asserts! (< hf-before (get trigger-hf vault)) ERR-TRIGGER-NOT-BREACHED)
    (asserts! (> repay-amount u0) ERR-AMOUNT-ZERO)
    (asserts! (<= repay-amount (get buffer vault)) ERR-BUFFER-EXCEEDED)

    ;; TODO M1: execute partial repay on Zest V2 as the vault principal
    (try! (contract-call? market repay-debt tx-sender repay-amount))

    ;; Post-state check: HF must be restored above trigger, else revert all
    (let ((hf-after (unwrap-panic (contract-call? market get-health-factor tx-sender))))
      (asserts! (>= hf-after (get trigger-hf vault)) ERR-POST-STATE-UNSAFE)

      ;; Keeper bounty (capped % of repaid amount) from the buffer
      (let ((bounty (/ (* repay-amount BOUNTY-BPS) u10000)))
        (try! (contract-call? debt-token transfer bounty tx-sender tx-sender none))
        (map-set vaults
          { owner: owner }
          (merge vault { buffer: (- (get buffer vault) (+ repay-amount bounty)) })
        )
        (ok true)
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; Monitor-only mode (M2): alerts only, no on-chain action. Keeper bot watches
;; vaults with status "monitor"; registered here so UIs can discover them.
;; ---------------------------------------------------------------------------
(define-public (register-monitor (trigger-hf uint))
  (begin
    (asserts! (>= trigger-hf u100) ERR-POST-STATE-UNSAFE)
    (map-set vaults
      { owner: tx-sender }
      { collateral: "monitor", debt: "monitor", trigger-hf: trigger-hf, buffer: u0, status: "monitor" }
    )
    (ok true)
  )
)

