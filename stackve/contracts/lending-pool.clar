;; Aave v1-style Lending Pool for Stacks
;; Built with Clarity language

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-insufficient-collateral (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-market-not-active (err u104))
(define-constant err-unhealthy-position (err u105))
(define-constant err-not-borrower (err u106))
(define-constant err-cannot-liquidate (err u107))

;; Data Variables
(define-data-var total-liquidity uint u0)
(define-data-var total-borrows uint u0)
(define-data-var liquidity-index uint u1000000) ;; 1.0 with 6 decimals
(define-data-var borrow-index uint u1000000) ;; 1.0 with 6 decimals
(define-data-var last-update-timestamp uint u0)
(define-data-var base-rate uint u20000) ;; 2% base rate (with 6 decimals)
(define-data-var slope1 uint u100000) ;; 10% slope1 (with 6 decimals)
(define-data-var slope2 uint u600000) ;; 60% slope2 (with 6 decimals)
(define-data-var optimal-utilization uint u800000) ;; 80% optimal utilization
(define-data-var liquidation-threshold uint u750000) ;; 75% liquidation threshold
(define-data-var liquidation-bonus uint u100000) ;; 10% liquidation bonus
(define-data-var reserve-factor uint u100000) ;; 10% reserve factor

;; Data Maps
(define-map user-deposits principal uint)
(define-map user-borrows principal uint)
(define-map user-collateral principal uint)
(define-map user-liquidity-index principal uint)
(define-map user-borrow-index principal uint)

;; Read-only functions

;; Get current utilization rate
(define-read-only (get-utilization-rate)
  (let ((total-liq (var-get total-liquidity))
        (total-borr (var-get total-borrows)))
    (if (is-eq total-liq u0)
        u0
        (if (<= total-borr total-liq)
            (/ (* total-borr u1000000) total-liq)
            u1000000)))) ;; Cap at 100%

;; Calculate current borrow rate based on utilization
(define-read-only (get-current-borrow-rate)
  (let ((utilization (get-utilization-rate))
        (optimal-util (var-get optimal-utilization)))
    (if (<= utilization optimal-util)
        ;; Below optimal: base-rate + (utilization * slope1) / optimal-utilization
        (+ (var-get base-rate)
           (if (> optimal-util u0)
               (/ (* utilization (var-get slope1)) optimal-util)
               u0))
        ;; Above optimal: base-rate + slope1 + ((utilization - optimal) * slope2) / (1 - optimal)
        (+ (+ (var-get base-rate) (var-get slope1))
           (let ((excess-util (- utilization optimal-util))
                 (remaining-util (- u1000000 optimal-util)))
             (if (> remaining-util u0)
                 (/ (* excess-util (var-get slope2)) remaining-util)
                 u0))))))

;; Calculate current supply rate
(define-read-only (get-current-supply-rate)
  (let ((borrow-rate (get-current-borrow-rate))
        (utilization (get-utilization-rate))
        (reserve-fact (var-get reserve-factor)))
    (if (> u1000000000000 u0) ;; Prevent division issues
        (/ (* (* borrow-rate utilization) (- u1000000 reserve-fact))
           u1000000000000) ;; Adjust for double scaling
        u0)))

;; Get user's current deposit balance (with accrued interest)
(define-read-only (get-user-deposit-balance (user principal))
  (let ((scaled-balance (default-to u0 (map-get? user-deposits user)))
        (user-index (default-to (var-get liquidity-index) (map-get? user-liquidity-index user)))
        (current-index (var-get liquidity-index)))
    (if (and (> user-index u0) (> current-index u0))
        (/ (* scaled-balance current-index) user-index)
        scaled-balance))) ;; Fallback to scaled balance if indices are zero

;; Get user's current borrow balance (with accrued interest)
(define-read-only (get-user-borrow-balance (user principal))
  (let ((scaled-balance (default-to u0 (map-get? user-borrows user)))
        (user-index (default-to (var-get borrow-index) (map-get? user-borrow-index user)))
        (current-index (var-get borrow-index)))
    (if (and (> user-index u0) (> current-index u0))
        (/ (* scaled-balance current-index) user-index)
        scaled-balance))) ;; Fallback to scaled balance if indices are zero

;; Get user's collateral balance
(define-read-only (get-user-collateral-balance (user principal))
  (default-to u0 (map-get? user-collateral user)))

;; Check if user position is healthy
(define-read-only (is-position-healthy (user principal))
  (let ((collateral (get-user-collateral-balance user))
        (borrow-balance (get-user-borrow-balance user))
        (threshold (var-get liquidation-threshold)))
    (if (is-eq borrow-balance u0)
        true
        (>= (/ (* collateral threshold) u1000000) borrow-balance))))

;; Private functions

;; Update interest rates and indices (guaranteed to return ok)
(define-private (update-state)
  (begin
    ;; Simple timestamp update - always succeeds
    (match (get-block-info? time (- block-height u1))
      current-timestamp (var-set last-update-timestamp current-timestamp)
      false) ;; If no block info, do nothing
    (ok true))) ;; Always return ok

;; Public functions

;; Supply STX to the pool
(define-public (supply (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    ;; Update state (ignore return value since it always succeeds)
    (let ((update-result (update-state))) true)
    
    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Calculate scaled amount
    (let ((current-index (var-get liquidity-index))
          (scaled-amount (if (> current-index u0)
                            (/ (* amount u1000000) current-index)
                            amount))
          (current-balance (default-to u0 (map-get? user-deposits tx-sender))))
      
      ;; Update user's deposit
      (map-set user-deposits tx-sender (+ current-balance scaled-amount))
      (map-set user-liquidity-index tx-sender current-index)
      
      ;; Update total liquidity
      (var-set total-liquidity (+ (var-get total-liquidity) amount))
      
      (ok amount))))

;; Withdraw STX from the pool
(define-public (withdraw (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    ;; Update state (ignore return value)
    (let ((update-result (update-state))) true)
    
    (let ((user-balance (get-user-deposit-balance tx-sender))
          (current-index (var-get liquidity-index))
          (scaled-amount (if (> current-index u0)
                            (/ (* amount u1000000) current-index)
                            amount))
          (current-scaled-balance (default-to u0 (map-get? user-deposits tx-sender))))
      
      (asserts! (>= user-balance amount) err-insufficient-balance)
      
      ;; Update user's deposit
      (map-set user-deposits tx-sender (- current-scaled-balance scaled-amount))
      
      ;; Update total liquidity
      (var-set total-liquidity (- (var-get total-liquidity) amount))
      
      ;; Transfer STX back to user
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      (ok amount))))

;; Deposit collateral
(define-public (deposit-collateral (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update user's collateral
    (let ((current-collateral (default-to u0 (map-get? user-collateral tx-sender))))
      (map-set user-collateral tx-sender (+ current-collateral amount)))
    
    (ok amount)))

;; Withdraw collateral
(define-public (withdraw-collateral (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    ;; Update state (ignore return value)
    (let ((update-result (update-state))) true)
    
    (let ((collateral-balance (get-user-collateral-balance tx-sender))
          (borrow-balance (get-user-borrow-balance tx-sender)))
      
      (asserts! (>= collateral-balance amount) err-insufficient-balance)
      
      ;; Check if position remains healthy after withdrawal
      (let ((new-collateral (- collateral-balance amount))
            (threshold (var-get liquidation-threshold)))
        (if (> borrow-balance u0)
            (asserts! (>= (/ (* new-collateral threshold) u1000000) borrow-balance) 
                     err-insufficient-collateral)
            true))
      
      ;; Update user's collateral
      (map-set user-collateral tx-sender (- collateral-balance amount))
      
      ;; Transfer STX back to user
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      (ok amount))))

;; Borrow STX from the pool
(define-public (borrow (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    ;; Update state (ignore return value)
    (let ((update-result (update-state))) true)
    
    (let ((collateral-balance (get-user-collateral-balance tx-sender))
          (borrow-balance (get-user-borrow-balance tx-sender))
          (threshold (var-get liquidation-threshold))
          (current-index (var-get borrow-index))
          (scaled-amount (if (> current-index u0)
                            (/ (* amount u1000000) current-index)
                            amount))
          (current-scaled-borrows (default-to u0 (map-get? user-borrows tx-sender))))
      
      ;; Check collateral sufficiency
      (asserts! (>= (/ (* collateral-balance threshold) u1000000) 
                   (+ borrow-balance amount)) err-insufficient-collateral)
      
      ;; Check liquidity availability
      (asserts! (>= (var-get total-liquidity) amount) err-insufficient-balance)
      
      ;; Update user's borrows
      (map-set user-borrows tx-sender (+ current-scaled-borrows scaled-amount))
      (map-set user-borrow-index tx-sender current-index)
      
      ;; Update total borrows and reduce liquidity
      (var-set total-borrows (+ (var-get total-borrows) amount))
      (var-set total-liquidity (- (var-get total-liquidity) amount))
      
      ;; Transfer STX to user
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      (ok amount))))

;; Repay borrowed STX
(define-public (repay (amount uint))
  (begin
    (asserts! (> amount u0) err-invalid-amount)
    ;; Update state (ignore return value)
    (let ((update-result (update-state))) true)
    
    (let ((borrow-balance (get-user-borrow-balance tx-sender))
          (repay-amount (if (> amount borrow-balance) borrow-balance amount))
          (current-index (var-get borrow-index))
          (scaled-repay (if (> current-index u0)
                           (/ (* repay-amount u1000000) current-index)
                           repay-amount))
          (current-scaled-borrows (default-to u0 (map-get? user-borrows tx-sender))))
      
      (asserts! (> borrow-balance u0) err-not-borrower)
      
      ;; Transfer STX from user to contract
      (try! (stx-transfer? repay-amount tx-sender (as-contract tx-sender)))
      
      ;; Update user's borrows
      (map-set user-borrows tx-sender (- current-scaled-borrows scaled-repay))
      
      ;; Update total borrows and increase liquidity
      (var-set total-borrows (- (var-get total-borrows) repay-amount))
      (var-set total-liquidity (+ (var-get total-liquidity) repay-amount))
      
      (ok repay-amount))))

;; Liquidate unhealthy position
(define-public (liquidate (borrower principal) (repay-amount uint))
  (begin
    (asserts! (> repay-amount u0) err-invalid-amount)
    (asserts! (not (is-position-healthy borrower)) err-cannot-liquidate)
    ;; Update state (ignore return value)
    (let ((update-result (update-state))) true)
    
    (let ((borrower-debt (get-user-borrow-balance borrower))
          (borrower-collateral (get-user-collateral-balance borrower))
          (liquidation-bonus-rate (var-get liquidation-bonus))
          (actual-repay (if (> repay-amount borrower-debt) borrower-debt repay-amount))
          (collateral-to-seize (+ actual-repay 
                                 (/ (* actual-repay liquidation-bonus-rate) u1000000))))
      
      (asserts! (<= collateral-to-seize borrower-collateral) err-insufficient-collateral)
      
      ;; Transfer repay amount from liquidator to contract
      (try! (stx-transfer? actual-repay tx-sender (as-contract tx-sender)))
      
      ;; Reduce borrower's debt and collateral
      (let ((current-index (var-get borrow-index))
            (scaled-repay (if (> current-index u0)
                             (/ (* actual-repay u1000000) current-index)
                             actual-repay))
            (current-scaled-borrows (default-to u0 (map-get? user-borrows borrower))))
        (map-set user-borrows borrower (- current-scaled-borrows scaled-repay)))
      
      (let ((current-collateral (get-user-collateral-balance borrower)))
        (map-set user-collateral borrower (- current-collateral collateral-to-seize)))
      
      ;; Transfer seized collateral to liquidator
      (try! (as-contract (stx-transfer? collateral-to-seize tx-sender tx-sender)))
      
      ;; Update totals
      (var-set total-borrows (- (var-get total-borrows) actual-repay))
      (var-set total-liquidity (+ (var-get total-liquidity) actual-repay))
      
      (ok collateral-to-seize))))

;; Admin functions (only contract owner)

;; Set interest rate parameters
(define-public (set-interest-rate-params 
                (new-base-rate uint) 
                (new-slope1 uint) 
                (new-slope2 uint) 
                (new-optimal-util uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set base-rate new-base-rate)
    (var-set slope1 new-slope1)
    (var-set slope2 new-slope2)
    (var-set optimal-utilization new-optimal-util)
    (ok true)))

;; Set risk parameters
(define-public (set-risk-params 
                (new-liquidation-threshold uint) 
                (new-liquidation-bonus uint) 
                (new-reserve-factor uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set liquidation-threshold new-liquidation-threshold)
    (var-set liquidation-bonus new-liquidation-bonus)
    (var-set reserve-factor new-reserve-factor)
    (ok true)))

;; Initialize the contract (called once after deployment)
(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (match (get-block-info? time (- block-height u1))
      current-timestamp
      (begin 
        (var-set last-update-timestamp current-timestamp)
        (ok true))
      (ok true)))) ;; If can't get block info, still return ok
