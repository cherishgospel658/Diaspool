(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_POOL_NOT_FOUND (err u101))
(define-constant ERR_POOL_INACTIVE (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_INVALID_AMOUNT (err u104))
(define-constant ERR_POOL_ENDED (err u105))
(define-constant ERR_POOL_NOT_ENDED (err u106))
(define-constant ERR_ALREADY_WITHDRAWN (err u107))
(define-constant ERR_NO_CONTRIBUTION (err u108))

(define-data-var next-pool-id uint u1)
(define-data-var platform-fee-rate uint u250)

(define-map pools
  { pool-id: uint }
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    target-amount: uint,
    current-amount: uint,
    end-block: uint,
    active: bool,
    completed: bool,
    funds-withdrawn: bool
  }
)

(define-map contributions
  { pool-id: uint, contributor: principal }
  { amount: uint, withdrawn: bool }
)

(define-map pool-contributors
  { pool-id: uint }
  { contributor-count: uint }
)

(define-public (create-pool (title (string-ascii 100)) (description (string-ascii 500)) (target-amount uint) (duration-blocks uint))
  (let
    (
      (pool-id (var-get next-pool-id))
      (end-block (+ stacks-block-height duration-blocks))
    )
    (asserts! (> target-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> duration-blocks u0) ERR_INVALID_AMOUNT)
    
    (map-set pools
      { pool-id: pool-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        target-amount: target-amount,
        current-amount: u0,
        end-block: end-block,
        active: true,
        completed: false,
        funds-withdrawn: false
      }
    )
    
    (map-set pool-contributors
      { pool-id: pool-id }
      { contributor-count: u0 }
    )
    
    (var-set next-pool-id (+ pool-id u1))
    (ok pool-id)
  )
)

(define-public (contribute-to-pool (pool-id uint) (amount uint))
  (let
    (
      (pool-data (unwrap! (map-get? pools { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
      (existing-contribution (default-to { amount: u0, withdrawn: false } 
                                        (map-get? contributions { pool-id: pool-id, contributor: tx-sender })))
      (contributors-data (unwrap! (map-get? pool-contributors { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
    )
    (asserts! (get active pool-data) ERR_POOL_INACTIVE)
    (asserts! (< stacks-block-height (get end-block pool-data)) ERR_POOL_ENDED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data { current-amount: (+ (get current-amount pool-data) amount) })
    )
    
    (map-set contributions
      { pool-id: pool-id, contributor: tx-sender }
      { amount: (+ (get amount existing-contribution) amount), withdrawn: false }
    )
    
    (if (is-eq (get amount existing-contribution) u0)
      (map-set pool-contributors
        { pool-id: pool-id }
        { contributor-count: (+ (get contributor-count contributors-data) u1) }
      )
      true
    )
    
    (ok true)
  )
)

(define-public (finalize-pool (pool-id uint))
  (let
    (
      (pool-data (unwrap! (map-get? pools { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender (get creator pool-data)) ERR_UNAUTHORIZED)
    (asserts! (get active pool-data) ERR_POOL_INACTIVE)
    (asserts! (>= stacks-block-height (get end-block pool-data)) ERR_POOL_NOT_ENDED)
    
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data { active: false, completed: true })
    )
    
    (ok true)
  )
)

(define-public (withdraw-funds (pool-id uint))
  (let
    (
      (pool-data (unwrap! (map-get? pools { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
      (platform-fee (/ (* (get current-amount pool-data) (var-get platform-fee-rate)) u10000))
      (creator-amount (- (get current-amount pool-data) platform-fee))
    )
    (asserts! (is-eq tx-sender (get creator pool-data)) ERR_UNAUTHORIZED)
    (asserts! (get completed pool-data) ERR_POOL_INACTIVE)
    (asserts! (not (get funds-withdrawn pool-data)) ERR_ALREADY_WITHDRAWN)
    (asserts! (> (get current-amount pool-data) u0) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? creator-amount tx-sender (get creator pool-data))))
    (try! (as-contract (stx-transfer? platform-fee tx-sender CONTRACT_OWNER)))
    
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data { funds-withdrawn: true })
    )
    
    (ok creator-amount)
  )
)

(define-public (refund-contribution (pool-id uint))
  (let
    (
      (pool-data (unwrap! (map-get? pools { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
      (contribution-data (unwrap! (map-get? contributions { pool-id: pool-id, contributor: tx-sender }) ERR_NO_CONTRIBUTION))
    )
    (asserts! (not (get active pool-data)) ERR_POOL_INACTIVE)
    (asserts! (not (get completed pool-data)) ERR_POOL_INACTIVE)
    (asserts! (>= stacks-block-height (get end-block pool-data)) ERR_POOL_NOT_ENDED)
    (asserts! (not (get withdrawn contribution-data)) ERR_ALREADY_WITHDRAWN)
    (asserts! (> (get amount contribution-data) u0) ERR_NO_CONTRIBUTION)
    
    (try! (as-contract (stx-transfer? (get amount contribution-data) tx-sender tx-sender)))
    
    (map-set contributions
      { pool-id: pool-id, contributor: tx-sender }
      (merge contribution-data { withdrawn: true })
    )
    
    (ok (get amount contribution-data))
  )
)

(define-public (cancel-pool (pool-id uint))
  (let
    (
      (pool-data (unwrap! (map-get? pools { pool-id: pool-id }) ERR_POOL_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender (get creator pool-data)) ERR_UNAUTHORIZED)
    (asserts! (get active pool-data) ERR_POOL_INACTIVE)
    
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data { active: false, completed: false })
    )
    
    (ok true)
  )
)

(define-public (set-platform-fee (new-fee-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-fee-rate u1000) ERR_INVALID_AMOUNT)
    (var-set platform-fee-rate new-fee-rate)
    (ok true)
  )
)

(define-read-only (get-pool (pool-id uint))
  (map-get? pools { pool-id: pool-id })
)

(define-read-only (get-contribution (pool-id uint) (contributor principal))
  (map-get? contributions { pool-id: pool-id, contributor: contributor })
)

(define-read-only (get-pool-contributors-count (pool-id uint))
  (map-get? pool-contributors { pool-id: pool-id })
)

(define-read-only (get-next-pool-id)
  (var-get next-pool-id)
)

(define-read-only (get-platform-fee-rate)
  (var-get platform-fee-rate)
)

(define-read-only (is-pool-active (pool-id uint))
  (match (map-get? pools { pool-id: pool-id })
    pool (and (get active pool) (< stacks-block-height (get end-block pool)))
    false
  )
)

(define-read-only (get-pool-progress (pool-id uint))
  (match (map-get? pools { pool-id: pool-id })
    pool (ok {
      current-amount: (get current-amount pool),
      target-amount: (get target-amount pool),
      percentage: (if (> (get target-amount pool) u0)
                    (/ (* (get current-amount pool) u100) (get target-amount pool))
                    u0),
      blocks-remaining: (if (> (get end-block pool) stacks-block-height)
                          (- (get end-block pool) stacks-block-height)
                          u0)
    })
    ERR_POOL_NOT_FOUND
  )
)

(define-read-only (calculate-refund-amount (pool-id uint) (contributor principal))
  (match (map-get? contributions { pool-id: pool-id, contributor: contributor })
    contribution (if (get withdrawn contribution)
                   u0
                   (get amount contribution))
    u0
  )
)
