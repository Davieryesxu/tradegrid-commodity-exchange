;; tradegrid-reputation
;; 
;; This contract maintains reputation scores for all participants in the TradeGrid
;; commodity exchange. Scores are based on successful trade completions, timeliness,
;; and quality. The reputation system incentivizes honest trading behavior through
;; benefits for high-reputation traders and penalties for dishonest actors.
;; The contract also implements a dispute resolution system for handling conflicts
;; between traders.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-UNKNOWN-USER (err u101))
(define-constant ERR-INVALID-RATING (err u102))
(define-constant ERR-INVALID-PARAMETERS (err u103))
(define-constant ERR-ALREADY-RATED (err u104))
(define-constant ERR-DISPUTE-NOT-FOUND (err u105))
(define-constant ERR-DISPUTE-ALREADY-RESOLVED (err u106))
(define-constant ERR-CANNOT-SELF-RATE (err u107))
(define-constant ERR-EVIDENCE-TOO-LONG (err u108))
(define-constant ERR-DISPUTE-PERIOD-EXPIRED (err u109))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u110))
(define-constant ERR-TRADE-NOT-FOUND (err u111))

;; Constants
(define-constant ADMIN-ADDRESS tx-sender)
(define-constant MINIMUM-RATING u1)
(define-constant MAXIMUM-RATING u5)
(define-constant DEFAULT-REPUTATION u50)
(define-constant MAX-REPUTATION u100)
(define-constant MIN-REPUTATION u0)
(define-constant DISPUTE-WINDOW-BLOCKS u144) ;; ~1 day assuming 10-minute blocks
(define-constant MAX-EVIDENCE-LENGTH u1000)

;; Data maps
;; Stores reputation scores for each trader
(define-map trader-reputation
  { trader: principal }
  { score: uint, trade-count: uint, last-updated: uint }
)

;; Tracks ratings given for specific trades
(define-map trade-ratings
  { trade-id: (buff 32), rater: principal }
  { ratee: principal, rating: uint, comment: (string-ascii 100), block-height: uint }
)

;; Stores dispute information
(define-map disputes
  { dispute-id: (buff 32) }
  {
    trade-id: (buff 32),
    complainant: principal,
    respondent: principal,
    status: (string-ascii 20), ;; "open", "resolved-for-complainant", "resolved-for-respondent", "compromise"
    complainant-evidence: (string-ascii 1000),
    respondent-evidence: (string-ascii 1000),
    resolution-details: (string-ascii 500),
    created-at: uint,
    resolved-at: uint
  }
)

;; Maps trades to associated disputes for quick lookup
(define-map trade-disputes
  { trade-id: (buff 32) }
  { dispute-id: (buff 32) }
)

;; Tracks arbitrators approved to resolve disputes
(define-map approved-arbitrators
  { arbitrator: principal }
  { active: bool, resolution-count: uint }
)

;; Map of traders who have trusted reputation from an outside source
(define-map trusted-traders
  { trader: principal }
  { verified: bool, verification-source: (string-ascii 100) }
)

;; Data variables
(define-data-var dispute-count uint u0)

;; Private functions

;; Initialize a new trader with default reputation
(define-private (initialize-trader (trader principal))
  (map-set trader-reputation
    { trader: trader }
    { score: DEFAULT-REPUTATION, trade-count: u0, last-updated: block-height }
  )
)

;; Calculate new reputation score based on existing score and new rating
(define-private (calculate-new-reputation (current-score uint) (rating uint) (trade-count uint))
  (let
    (
      ;; More weight to new ratings for traders with few trades, less impact for established traders
      (weight (/ u100 (+ u10 trade-count)))
      (rating-impact (* (- rating u3) weight))
      (new-score (+ current-score rating-impact))
    )
    ;; Ensure score stays within bounds
    (if (> new-score MAX-REPUTATION)
      MAX-REPUTATION
      (if (< new-score MIN-REPUTATION)
        MIN-REPUTATION
        new-score
      )
    )
  )
)

;; Check if a trader exists, and initialize them if not
(define-private (get-or-create-trader (trader principal))
  (match (map-get? trader-reputation { trader: trader })
    existing-data existing-data
    (begin
      (initialize-trader trader)
      (map-get? trader-reputation { trader: trader })
    )
  )
)

;; Generate a new dispute ID
(define-private (generate-dispute-id (trade-id (buff 32)) (complainant principal) (block-time uint))
  (sha256 (concat (concat trade-id (principal->buff complainant)) (uint->buff block-time)))
)

;; Check if caller is an approved arbitrator
(define-private (is-arbitrator (caller principal))
  (match (map-get? approved-arbitrators { arbitrator: caller })
    arbitrator-data (get active arbitrator-data)
    false
  )
)

;; Read-only functions

;; Get reputation score for a trader
(define-read-only (get-reputation (trader principal))
  (match (map-get? trader-reputation { trader: trader })
    reputation-data (get score reputation-data)
    DEFAULT-REPUTATION
  )
)

;; Get complete reputation data for a trader
(define-read-only (get-trader-details (trader principal))
  (match (map-get? trader-reputation { trader: trader })
    reputation-data (ok reputation-data)
    (err ERR-UNKNOWN-USER)
  )
)

;; Check if trader has minimum required reputation
(define-read-only (meets-minimum-reputation (trader principal) (required-score uint))
  (>= (get-reputation trader) required-score)
)

;; Get a specific rating
(define-read-only (get-rating (trade-id (buff 32)) (rater principal))
  (map-get? trade-ratings { trade-id: trade-id, rater: rater })
)

;; Get dispute details
(define-read-only (get-dispute (dispute-id (buff 32)))
  (match (map-get? disputes { dispute-id: dispute-id })
    dispute-data (ok dispute-data)
    ERR-DISPUTE-NOT-FOUND
  )
)

;; Check if dispute exists for a trade
(define-read-only (has-dispute (trade-id (buff 32)))
  (is-some (map-get? trade-disputes { trade-id: trade-id }))
)

;; Check if a trader is verified
(define-read-only (is-verified-trader (trader principal))
  (match (map-get? trusted-traders { trader: trader })
    trader-data (get verified trader-data)
    false
  )
)

;; Public functions

;; Submit a rating for a trade counterparty
(define-public (submit-rating 
    (trade-id (buff 32)) 
    (ratee principal) 
    (rating uint) 
    (comment (string-ascii 100))
  )
  (let 
    (
      (rater tx-sender)
    )
    ;; Check if rating is valid
    (asserts! (and (>= rating MINIMUM-RATING) (<= rating MAXIMUM-RATING)) ERR-INVALID-RATING)
    
    ;; Check if trader is not rating themselves
    (asserts! (not (is-eq rater ratee)) ERR-CANNOT-SELF-RATE)
    
    ;; Check if rater has already rated this trade
    (asserts! (is-none (map-get? trade-ratings { trade-id: trade-id, rater: rater })) ERR-ALREADY-RATED)
    
    ;; Record the rating
    (map-set trade-ratings
      { trade-id: trade-id, rater: rater }
      { 
        ratee: ratee, 
        rating: rating, 
        comment: comment, 
        block-height: block-height 
      }
    )
    
    ;; Update reputation of the rated party
    (match (map-get? trader-reputation { trader: ratee })
      reputation-data
      (let
        (
          (current-score (get score reputation-data))
          (trade-count (get trade-count reputation-data))
          (new-score (calculate-new-reputation current-score rating trade-count))
          (new-trade-count (+ trade-count u1))
        )
        (map-set trader-reputation
          { trader: ratee }
          { 
            score: new-score, 
            trade-count: new-trade-count, 
            last-updated: block-height 
          }
        )
      )
      ;; Initialize new trader with this rating
      (let
        (
          (new-score (calculate-new-reputation DEFAULT-REPUTATION rating u0))
        )
        (map-set trader-reputation
          { trader: ratee }
          { 
            score: new-score, 
            trade-count: u1, 
            last-updated: block-height 
          }
        )
      )
    )
    
    (ok true)
  )
)

;; File a dispute against a trader
(define-public (file-dispute 
    (trade-id (buff 32)) 
    (respondent principal) 
    (evidence (string-ascii 1000))
  )
  (let
    (
      (complainant tx-sender)
      (current-block block-height)
      (dispute-id (generate-dispute-id trade-id complainant current-block))
    )
    ;; Check evidence length
    (asserts! (<= (len evidence) MAX-EVIDENCE-LENGTH) ERR-EVIDENCE-TOO-LONG)
    
    ;; Check if dispute already exists
    (asserts! (is-none (map-get? trade-disputes { trade-id: trade-id })) ERR-DISPUTE-ALREADY-RESOLVED)
    
    ;; Create dispute
    (map-set disputes
      { dispute-id: dispute-id }
      {
        trade-id: trade-id,
        complainant: complainant,
        respondent: respondent,
        status: "open",
        complainant-evidence: evidence,
        respondent-evidence: "",
        resolution-details: "",
        created-at: current-block,
        resolved-at: u0
      }
    )
    
    ;; Track dispute for this trade
    (map-set trade-disputes
      { trade-id: trade-id }
      { dispute-id: dispute-id }
    )
    
    ;; Increment dispute count
    (var-set dispute-count (+ (var-get dispute-count) u1))
    
    (ok dispute-id)
  )
)

;; Submit evidence for a dispute (respondent)
(define-public (submit-evidence 
    (dispute-id (buff 32)) 
    (evidence (string-ascii 1000))
  )
  (let
    (
      (sender tx-sender)
    )
    ;; Check evidence length
    (asserts! (<= (len evidence) MAX-EVIDENCE-LENGTH) ERR-EVIDENCE-TOO-LONG)
    
    (match (map-get? disputes { dispute-id: dispute-id })
      dispute-data
      (begin
        ;; Check if dispute is still open
        (asserts! (is-eq (get status dispute-data) "open") ERR-DISPUTE-ALREADY-RESOLVED)
        
        ;; Check if sender is the respondent
        (asserts! (is-eq sender (get respondent dispute-data)) ERR-NOT-AUTHORIZED)
        
        ;; Check if dispute period is still active
        (asserts! 
          (< block-height (+ (get created-at dispute-data) DISPUTE-WINDOW-BLOCKS)) 
          ERR-DISPUTE-PERIOD-EXPIRED
        )
        
        ;; Update dispute with evidence
        (map-set disputes
          { dispute-id: dispute-id }
          (merge dispute-data { respondent-evidence: evidence })
        )
        
        (ok true)
      )
      ERR-DISPUTE-NOT-FOUND
    )
  )
)

;; Resolve a dispute
(define-public (resolve-dispute 
    (dispute-id (buff 32)) 
    (resolution-type (string-ascii 20)) 
    (details (string-ascii 500))
    (complainant-adjustment int)
    (respondent-adjustment int)
  )
  (let
    (
      (arbitrator tx-sender)
    )
    ;; Check if caller is authorized arbitrator
    (asserts! (or (is-eq arbitrator ADMIN-ADDRESS) (is-arbitrator arbitrator)) ERR-NOT-AUTHORIZED)
    
    ;; Validate resolution type
    (asserts! 
      (or 
        (is-eq resolution-type "resolved-for-complainant") 
        (is-eq resolution-type "resolved-for-respondent")
        (is-eq resolution-type "compromise")
      ) 
      ERR-INVALID-PARAMETERS
    )
    
    (match (map-get? disputes { dispute-id: dispute-id })
      dispute-data
      (begin
        ;; Check if dispute is still open
        (asserts! (is-eq (get status dispute-data) "open") ERR-DISPUTE-ALREADY-RESOLVED)
        
        ;; Update dispute status
        (map-set disputes
          { dispute-id: dispute-id }
          (merge dispute-data 
            { 
              status: resolution-type, 
              resolution-details: details,
              resolved-at: block-height
            }
          )
        )
        
        ;; Adjust reputation for both parties
        (if (not (is-eq complainant-adjustment 0))
          (adjust-reputation-by-amount (get complainant dispute-data) complainant-adjustment)
          true
        )
        
        (if (not (is-eq respondent-adjustment 0))
          (adjust-reputation-by-amount (get respondent dispute-data) respondent-adjustment)
          true
        )
        
        ;; Update arbitrator stats if not admin
        (if (not (is-eq arbitrator ADMIN-ADDRESS))
          (match (map-get? approved-arbitrators { arbitrator: arbitrator })
            arbitrator-data
            (map-set approved-arbitrators
              { arbitrator: arbitrator }
              (merge arbitrator-data { resolution-count: (+ (get resolution-count arbitrator-data) u1) })
            )
            true
          )
          true
        )
        
        (ok true)
      )
      ERR-DISPUTE-NOT-FOUND
    )
  )
)

;; Adjust reputation by a specified amount (positive or negative)
(define-public (adjust-reputation-by-amount (trader principal) (amount int))
  (begin
    ;; Only admin or arbitrators can adjust reputation
    (asserts! (or (is-eq tx-sender ADMIN-ADDRESS) (is-arbitrator tx-sender)) ERR-NOT-AUTHORIZED)
    
    (match (map-get? trader-reputation { trader: trader })
      reputation-data
      (let
        (
          (current-score (get score reputation-data))
          (new-score (+ (to-int current-score) amount))
        )
        (map-set trader-reputation
          { trader: trader }
          (merge reputation-data {
            score: (if (< new-score (to-int MIN-REPUTATION))
                    MIN-REPUTATION
                    (if (> new-score (to-int MAX-REPUTATION))
                      MAX-REPUTATION
                      (to-uint new-score)
                    )
                  ),
            last-updated: block-height
          })
        )
        (ok true)
      )
      (begin
        (initialize-trader trader)
        (adjust-reputation-by-amount trader amount)
      )
    )
  )
)

;; Admin Functions

;; Add or update an arbitrator
(define-public (set-arbitrator (arbitrator principal) (active bool))
  (begin
    (asserts! (is-eq tx-sender ADMIN-ADDRESS) ERR-NOT-AUTHORIZED)
    
    (map-set approved-arbitrators
      { arbitrator: arbitrator }
      (match (map-get? approved-arbitrators { arbitrator: arbitrator })
        existing-data (merge existing-data { active: active })
        { active: active, resolution-count: u0 }
      )
    )
    
    (ok true)
  )
)

;; Set a trader as verified (e.g., for established companies or KYC'd entities)
(define-public (set-verified-trader (trader principal) (verified bool) (source (string-ascii 100)))
  (begin
    (asserts! (is-eq tx-sender ADMIN-ADDRESS) ERR-NOT-AUTHORIZED)
    
    (map-set trusted-traders
      { trader: trader }
      { verified: verified, verification-source: source }
    )
    
    (ok true)
  )
)

;; Set base reputation for a trader (for onboarding established traders)
(define-public (set-base-reputation (trader principal) (reputation uint))
  (begin
    (asserts! (is-eq tx-sender ADMIN-ADDRESS) ERR-NOT-AUTHORIZED)
    (asserts! (<= reputation MAX-REPUTATION) ERR-INVALID-PARAMETERS)
    
    (map-set trader-reputation
      { trader: trader }
      (match (map-get? trader-reputation { trader: trader })
        existing-data (merge existing-data { score: reputation, last-updated: block-height })
        { score: reputation, trade-count: u0, last-updated: block-height }
      )
    )
    
    (ok true)
  )
)