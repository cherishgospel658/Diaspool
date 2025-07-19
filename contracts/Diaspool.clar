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
(define-constant ERR_INVALID_REFERRAL (err u109))
(define-constant ERR_SELF_REFERRAL (err u110))
(define-constant ERR_INSUFFICIENT_REPUTATION (err u111))

(define-data-var next-pool-id uint u1)
(define-data-var platform-fee-rate uint u250)
(define-data-var reputation-reward-pool uint u0)

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

(define-map user-reputation
  { user: principal }
  {
    reputation-score: uint,
    pools-created: uint,
    successful-pools: uint,
    total-contributed: uint,
    total-pools-contributed: uint,
    referrals-made: uint,
    achievement-badges: uint
  }
)

(define-map user-referrals
  { referrer: principal, referee: principal }
  { referral-bonus: uint, claimed: bool }
)

(define-map reputation-milestones
  { milestone-id: uint }
  {
    required-score: uint,
    reward-amount: uint,
    badge-name: (string-ascii 50),
    active: bool
  }
)

(define-private (update-reputation-on-pool-creation (creator principal))
  (let
    (
      (user-rep (default-to 
        { reputation-score: u0, pools-created: u0, successful-pools: u0, 
          total-contributed: u0, total-pools-contributed: u0, referrals-made: u0, achievement-badges: u0 }
        (map-get? user-reputation { user: creator })))
    )
    (map-set user-reputation
      { user: creator }
      (merge user-rep { 
        pools-created: (+ (get pools-created user-rep) u1),
        reputation-score: (+ (get reputation-score user-rep) u100)
      })
    )
    true
  )
)

(define-private (update-reputation-on-contribution (contributor principal) (amount uint))
  (let
    (
      (user-rep (default-to 
        { reputation-score: u0, pools-created: u0, successful-pools: u0, 
          total-contributed: u0, total-pools-contributed: u0, referrals-made: u0, achievement-badges: u0 }
        (map-get? user-reputation { user: contributor })))
      (contribution-points (/ amount u1000000))
    )
    (map-set user-reputation
      { user: contributor }
      (merge user-rep { 
        total-contributed: (+ (get total-contributed user-rep) amount),
        total-pools-contributed: (+ (get total-pools-contributed user-rep) u1),
        reputation-score: (+ (get reputation-score user-rep) contribution-points)
      })
    )
    true
  )
)

(define-private (update-reputation-on-successful-pool (creator principal))
  (let
    (
      (user-rep (default-to 
        { reputation-score: u0, pools-created: u0, successful-pools: u0, 
          total-contributed: u0, total-pools-contributed: u0, referrals-made: u0, achievement-badges: u0 }
        (map-get? user-reputation { user: creator })))
    )
    (map-set user-reputation
      { user: creator }
      (merge user-rep { 
        successful-pools: (+ (get successful-pools user-rep) u1),
        reputation-score: (+ (get reputation-score user-rep) u500)
      })
    )
    true
  )
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
    (update-reputation-on-pool-creation tx-sender)
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
    
    (update-reputation-on-contribution tx-sender amount)
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
    
    (update-reputation-on-successful-pool (get creator pool-data))
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

(define-public (register-with-referral (referrer principal))
  (let
    (
      (referrer-reputation (default-to 
        { reputation-score: u0, pools-created: u0, successful-pools: u0, 
          total-contributed: u0, total-pools-contributed: u0, referrals-made: u0, achievement-badges: u0 }
        (map-get? user-reputation { user: referrer })))
      (referee-reputation (default-to 
        { reputation-score: u0, pools-created: u0, successful-pools: u0, 
          total-contributed: u0, total-pools-contributed: u0, referrals-made: u0, achievement-badges: u0 }
        (map-get? user-reputation { user: tx-sender })))
    )
    (asserts! (not (is-eq tx-sender referrer)) ERR_SELF_REFERRAL)
    (asserts! (> (get reputation-score referrer-reputation) u0) ERR_INVALID_REFERRAL)
    
    (map-set user-referrals
      { referrer: referrer, referee: tx-sender }
      { referral-bonus: u50, claimed: false }
    )
    
    (map-set user-reputation
      { user: referrer }
      (merge referrer-reputation { 
        referrals-made: (+ (get referrals-made referrer-reputation) u1),
        reputation-score: (+ (get reputation-score referrer-reputation) u25)
      })
    )
    
    (map-set user-reputation
      { user: tx-sender }
      (merge referee-reputation { reputation-score: (+ (get reputation-score referee-reputation) u10) })
    )
    
    (ok true)
  )
)

(define-public (claim-referral-bonus)
  (let
    (
      (referral-data (unwrap! (map-get? user-referrals { referrer: tx-sender, referee: tx-sender }) ERR_INVALID_REFERRAL))
      (bonus-amount (get referral-bonus referral-data))
    )
    (asserts! (not (get claimed referral-data)) ERR_ALREADY_WITHDRAWN)
    (asserts! (> bonus-amount u0) ERR_INSUFFICIENT_FUNDS)
    (asserts! (>= (var-get reputation-reward-pool) bonus-amount) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? bonus-amount tx-sender tx-sender)))
    
    (map-set user-referrals
      { referrer: tx-sender, referee: tx-sender }
      (merge referral-data { claimed: true })
    )
    
    (var-set reputation-reward-pool (- (var-get reputation-reward-pool) bonus-amount))
    (ok bonus-amount)
  )
)

(define-public (create-reputation-milestone (milestone-id uint) (required-score uint) (reward-amount uint) (badge-name (string-ascii 50)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> required-score u0) ERR_INVALID_AMOUNT)
    (asserts! (> reward-amount u0) ERR_INVALID_AMOUNT)
    
    (map-set reputation-milestones
      { milestone-id: milestone-id }
      {
        required-score: required-score,
        reward-amount: reward-amount,
        badge-name: badge-name,
        active: true
      }
    )
    (ok true)
  )
)

(define-public (claim-milestone-reward (milestone-id uint))
  (let
    (
      (milestone-data (unwrap! (map-get? reputation-milestones { milestone-id: milestone-id }) ERR_POOL_NOT_FOUND))
      (user-rep (unwrap! (map-get? user-reputation { user: tx-sender }) ERR_NO_CONTRIBUTION))
      (reward-amount (get reward-amount milestone-data))
    )
    (asserts! (get active milestone-data) ERR_POOL_INACTIVE)
    (asserts! (>= (get reputation-score user-rep) (get required-score milestone-data)) ERR_INSUFFICIENT_REPUTATION)
    (asserts! (>= (var-get reputation-reward-pool) reward-amount) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? reward-amount tx-sender tx-sender)))
    
    (map-set user-reputation
      { user: tx-sender }
      (merge user-rep { achievement-badges: (+ (get achievement-badges user-rep) u1) })
    )
    
    (var-set reputation-reward-pool (- (var-get reputation-reward-pool) reward-amount))
    (ok reward-amount)
  )
)

(define-public (fund-reputation-rewards (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set reputation-reward-pool (+ (var-get reputation-reward-pool) amount))
    (ok true)
  )
)

(define-public (get-reputation-discount (user principal))
  (match (map-get? user-reputation { user: user })
    user-rep (ok (if (>= (get reputation-score user-rep) u1000)
                   (if (>= (get reputation-score user-rep) u5000)
                     u50
                     u25)
                   u0))
    (ok u0)
  )
)

(define-read-only (get-user-reputation (user principal))
  (map-get? user-reputation { user: user })
)

(define-read-only (get-referral-info (referrer principal) (referee principal))
  (map-get? user-referrals { referrer: referrer, referee: referee })
)

(define-read-only (get-milestone-info (milestone-id uint))
  (map-get? reputation-milestones { milestone-id: milestone-id })
)

(define-read-only (get-reputation-reward-pool-balance)
  (var-get reputation-reward-pool)
)

(define-read-only (calculate-reputation-tier (user principal))
  (match (map-get? user-reputation { user: user })
    user-rep (ok (if (>= (get reputation-score user-rep) u10000)
                   "diamond"
                   (if (>= (get reputation-score user-rep) u5000)
                     "gold"
                     (if (>= (get reputation-score user-rep) u1000)
                       "silver"
                       "bronze"))))
    (ok "bronze")
  )
)
