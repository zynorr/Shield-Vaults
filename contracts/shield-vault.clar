;; shield-vault.clar
;; Protected borrow vaults for Stacks lending markets.
;;
;; A vault owns the borrow position on the lending market, keeps a repay
;; buffer, and exposes a permissionless keeper-rescue that fires when the
;; position health drops below the owner's threshold. The lending market and
;; tokens are passed in as trait parameters, so the contract is not coupled
;; to a single protocol.

(define-trait lending-market-trait
  (
    ;; follow the target market's real signatures on integration
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

;; bounty: 2% of the repaid amount. buffer: max 10% of the borrow.
(define-constant BOUNTY-BPS u200)
(define-constant BUFFER-CAP-BPS u1000)

(define-constant ERR-VAULT-NOT-FOUND (err u101))
(define-constant ERR-VAULT-NOT-HEALTHY (err u102))
(define-constant ERR-TRIGGER-NOT-BREACHED (err u103))
(define-constant ERR-POST-STATE-UNSAFE (err u104))
(define-constant ERR-BUFFER-EXCEEDED (err u105))
(define-constant ERR-AMOUNT-ZERO (err u106))

(define-map vaults
  { owner: principal }
  {
    collateral: (string-ascii 32),
    debt: (string-ascii 32),
    trigger-hf: uint,
    buffer: uint,
    status: (string-ascii 16)
  }
)

;; counters for the public dashboard
(define-data-var vault-count uint u0)
(define-data-var total-protected uint u0)

(define-read-only (get-vault (owner principal))
  (map-get? vaults { owner: owner })
)

(define-read-only (get-stats)
  { vaults: (var-get vault-count), protected: (var-get total-protected) }
)


;; pull the collateral and the repay buffer from the caller, then open the
;; position on the lending market with the vault as principal
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

    (try! (as-contract (contract-call? collateral-token transfer collateral-amount contract-caller tx-sender none)))
    (try! (as-contract (contract-call? debt-token transfer buffer-amount contract-caller tx-sender none)))
    (try! (as-contract (contract-call? market deposit-collateral tx-sender collateral-amount)))
    (try! (as-contract (contract-call? market borrow-asset tx-sender borrow-amount)))

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
    (try! (as-contract (contract-call? market repay-debt tx-sender amount)))
    (ok true)
  )
)

;; add to the repay buffer the keeper draws from
(define-public (user-topup (debt-token <sip010-trait>) (amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-VAULT-NOT-FOUND)))
    (asserts! (> amount u0) ERR-AMOUNT-ZERO)
    (try! (as-contract (contract-call? debt-token transfer amount contract-caller tx-sender none)))
    (map-set vaults { owner: tx-sender } (merge vault { buffer: (+ (get buffer vault) amount) }))
    (ok true)
  )
)

;; closing only makes sense on a healthy position; redeeming the collateral
;; lands with the market wiring on the integration milestone
(define-public (close-vault (market <lending-market-trait>))
  (let (
    (vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-VAULT-NOT-FOUND))
    (hf (try! (as-contract (contract-call? market get-health-factor tx-sender))))
  )
    (asserts! (is-eq (get status vault) "active") ERR-VAULT-NOT-HEALTHY)
    (asserts! (>= hf u100) ERR-VAULT-NOT-HEALTHY)
    (map-set vaults { owner: tx-sender } (merge vault { status: "closed" }))
    (ok true)
  )
)

;; permissionless: anyone can restore a breached position and collect the
;; bounty. The whole tx reverts if the repay leaves the position below the
;; trigger, so a keeper is only paid for a rescue that actually worked.
(define-public (keeper-rescue
    (market <lending-market-trait>)
    (debt-token <sip010-trait>)
    (owner principal)
    (repay-amount uint))
  (let (
    (vault (unwrap! (map-get? vaults { owner: owner }) ERR-VAULT-NOT-FOUND))
    (hf-before (try! (as-contract (contract-call? market get-health-factor tx-sender))))
  )
    (asserts! (is-eq (get status vault) "active") ERR-VAULT-NOT-HEALTHY)
    (asserts! (< hf-before (get trigger-hf vault)) ERR-TRIGGER-NOT-BREACHED)
    (asserts! (> repay-amount u0) ERR-AMOUNT-ZERO)
    (asserts! (<= repay-amount (get buffer vault)) ERR-BUFFER-EXCEEDED)

    (try! (as-contract (contract-call? market repay-debt tx-sender repay-amount)))

    (let ((hf-after (try! (as-contract (contract-call? market get-health-factor tx-sender)))))
      (asserts! (>= hf-after (get trigger-hf vault)) ERR-POST-STATE-UNSAFE)
      (let ((bounty (/ (* repay-amount BOUNTY-BPS) u10000)))
        (try! (as-contract (contract-call? debt-token transfer bounty tx-sender contract-caller none)))
        (map-set vaults
          { owner: owner }
          (merge vault { buffer: (- (get buffer vault) (+ repay-amount bounty)) })
        )
        (ok true)
      )
    )
  )
)

;; monitor-only: no funds move, just registers the position so the keeper
;; bot can send threshold alerts
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
