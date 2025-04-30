;; tradegrid-commodity
;; 
;; This contract manages the core functionality of the TradeGrid Commodity Exchange,
;; enabling peer-to-peer trading of physical commodities on the Stacks blockchain.
;; It allows users to create listings, place orders, match trades, and handles
;; the escrow and settlement process for commodity transactions.

;; Error codes
(define-constant err-not-authorized (err u100))
(define-constant err-listing-not-found (err u101))
(define-constant err-order-not-found (err u102))
(define-constant err-invalid-quantity (err u103))
(define-constant err-invalid-price (err u104))
(define-constant err-insufficient-funds (err u105))
(define-constant err-invalid-status (err u106))
(define-constant err-already-exists (err u107))
(define-constant err-escrow-failed (err u108))
(define-constant err-delivery-not-confirmed (err u109))
(define-constant err-invalid-operation (err u110))

;; Status codes for listings
(define-constant status-active u1)
(define-constant status-inactive u2)
(define-constant status-completed u3)
(define-constant status-cancelled u4)

;; Status codes for trades
(define-constant trade-status-initiated u1)
(define-constant trade-status-escrowed u2)
(define-constant trade-status-in-delivery u3)
(define-constant trade-status-delivered u4)
(define-constant trade-status-completed u5)
(define-constant trade-status-disputed u6)
(define-constant trade-status-cancelled u7)

;; Order types
(define-constant order-type-buy u1)
(define-constant order-type-sell u2)

;; Data structures

;; Commodity listings - stores details about commodities offered for sale
(define-map commodity-listings
  { listing-id: uint }
  {
    seller: principal,
    commodity-type: (string-ascii 64),
    quality-grade: (string-ascii 16),
    quantity: uint,
    unit: (string-ascii 16),
    price-per-unit: uint,
    location: (string-ascii 64),
    delivery-terms: (string-ascii 256),
    status: uint,
    created-at: uint
  }
)

;; Orders - stores buy and sell orders
(define-map orders
  { order-id: uint }
  {
    creator: principal,
    order-type: uint,  ;; buy or sell
    listing-id: uint,
    quantity: uint,
    price-per-unit: uint,
    status: uint,
    created-at: uint
  }
)

;; Trades - stores matched trades between buyers and sellers
(define-map trades
  { trade-id: uint }
  {
    buyer: principal,
    seller: principal,
    listing-id: uint,
    order-id: uint,
    quantity: uint,
    price-per-unit: uint,
    total-amount: uint,
    status: uint,
    created-at: uint,
    updated-at: uint,
    delivery-deadline: uint
  }
)

;; Escrow - stores funds held in escrow for ongoing trades
(define-map escrow-balances
  { trade-id: uint }
  { amount: uint }
)

;; Counters for IDs
(define-data-var next-listing-id uint u1)
(define-data-var next-order-id uint u1)
(define-data-var next-trade-id uint u1)

;; Private functions

;; Get the next listing ID and increment the counter
(define-private (get-next-listing-id)
  (let ((id (var-get next-listing-id)))
    (var-set next-listing-id (+ id u1))
    id
  )
)

;; Get the next order ID and increment the counter
(define-private (get-next-order-id)
  (let ((id (var-get next-order-id)))
    (var-set next-order-id (+ id u1))
    id
  )
)

;; Get the next trade ID and increment the counter
(define-private (get-next-trade-id)
  (let ((id (var-get next-trade-id)))
    (var-set next-trade-id (+ id u1))
    id
  )
)

;; Validate listing details
(define-private (validate-listing-details
                (quantity uint)
                (price-per-unit uint))
  (begin
    (asserts! (> quantity u0) err-invalid-quantity)
    (asserts! (> price-per-unit u0) err-invalid-price)
    (ok true)
  )
)

;; Process escrow for a trade
(define-private (process-escrow
                (trade-id uint)
                (amount uint)
                (sender principal))
  (begin
    ;; In a production contract, this would interact with a token contract for actual funds transfer
    ;; For demonstration, we just record the escrow amount
    (map-set escrow-balances
      { trade-id: trade-id }
      { amount: amount }
    )
    (ok true)
  )
)

;; Release escrow to seller
(define-private (release-escrow-to-seller
                (trade-id uint)
                (seller principal))
  (let (
    (escrow-amount (unwrap! (get-escrow-amount trade-id) err-escrow-failed))
  )
    ;; In a production contract, this would transfer tokens to the seller
    ;; For demonstration, we just delete the escrow record
    (map-delete escrow-balances { trade-id: trade-id })
    (ok true)
  )
)

;; Return escrow to buyer
(define-private (return-escrow-to-buyer
                (trade-id uint)
                (buyer principal))
  (let (
    (escrow-amount (unwrap! (get-escrow-amount trade-id) err-escrow-failed))
  )
    ;; In a production contract, this would return tokens to the buyer
    ;; For demonstration, we just delete the escrow record
    (map-delete escrow-balances { trade-id: trade-id })
    (ok true)
  )
)

;; Match a buy order with a sell listing
(define-private (match-order-with-listing
                (order-id uint)
                (buyer principal)
                (listing-id uint)
                (quantity uint)
                (price-per-unit uint))
  (let (
    (listing (unwrap! (map-get? commodity-listings { listing-id: listing-id }) err-listing-not-found))
    (trade-id (get-next-trade-id))
    (total-amount (* quantity price-per-unit))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    ;; Delivery deadline set to 30 days in the future (simplified for demo)
    (delivery-deadline (+ current-time (* u60 u60 u24 u30)))
  )
    ;; Check if listing is active and has sufficient quantity
    (asserts! (is-eq (get status listing) status-active) err-invalid-status)
    (asserts! (>= (get quantity listing) quantity) err-invalid-quantity)
    
    ;; Create a new trade
    (map-set trades
      { trade-id: trade-id }
      {
        buyer: buyer,
        seller: (get seller listing),
        listing-id: listing-id,
        order-id: order-id,
        quantity: quantity,
        price-per-unit: price-per-unit,
        total-amount: total-amount,
        status: trade-status-initiated,
        created-at: current-time,
        updated-at: current-time,
        delivery-deadline: delivery-deadline
      }
    )
    
    ;; Update listing quantity
    (map-set commodity-listings
      { listing-id: listing-id }
      (merge listing { quantity: (- (get quantity listing) quantity) })
    )
    
    ;; If listing quantity is now 0, mark it as completed
    (if (is-eq (- (get quantity listing) quantity) u0)
      (map-set commodity-listings
        { listing-id: listing-id }
        (merge listing { 
          quantity: u0,
          status: status-completed
        })
      )
      true
    )
    
    (ok trade-id)
  )
)

;; Get escrow amount for a trade
(define-private (get-escrow-amount (trade-id uint))
  (match (map-get? escrow-balances { trade-id: trade-id })
    escrow-data (ok (get amount escrow-data))
    (err err-escrow-failed)
  )
)

;; Read-only functions

;; Get listing details
(define-read-only (get-listing (listing-id uint))
  (map-get? commodity-listings { listing-id: listing-id })
)

;; Get order details
(define-read-only (get-order (order-id uint))
  (map-get? orders { order-id: order-id })
)

;; Get trade details
(define-read-only (get-trade (trade-id uint))
  (map-get? trades { trade-id: trade-id })
)

;; Check if a listing exists and is active
(define-read-only (is-listing-active (listing-id uint))
  (match (map-get? commodity-listings { listing-id: listing-id })
    listing (is-eq (get status listing) status-active)
    false
  )
)

;; Public functions

;; Create a new commodity listing
(define-public (create-listing
              (commodity-type (string-ascii 64))
              (quality-grade (string-ascii 16))
              (quantity uint)
              (unit (string-ascii 16))
              (price-per-unit uint)
              (location (string-ascii 64))
              (delivery-terms (string-ascii 256)))
  (let (
    (listing-id (get-next-listing-id))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Validate listing details
    (try! (validate-listing-details quantity price-per-unit))
    
    ;; Create the listing
    (map-set commodity-listings
      { listing-id: listing-id }
      {
        seller: tx-sender,
        commodity-type: commodity-type,
        quality-grade: quality-grade,
        quantity: quantity,
        unit: unit,
        price-per-unit: price-per-unit,
        location: location,
        delivery-terms: delivery-terms,
        status: status-active,
        created-at: current-time
      }
    )
    (ok listing-id)
  )
)

;; Update an existing listing
(define-public (update-listing
              (listing-id uint)
              (quantity uint)
              (price-per-unit uint)
              (delivery-terms (string-ascii 256)))
  (let (
    (listing (unwrap! (map-get? commodity-listings { listing-id: listing-id }) err-listing-not-found))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender (get seller listing)) err-not-authorized)
    
    ;; Check if listing is active
    (asserts! (is-eq (get status listing) status-active) err-invalid-status)
    
    ;; Validate updated details
    (try! (validate-listing-details quantity price-per-unit))
    
    ;; Update the listing
    (map-set commodity-listings
      { listing-id: listing-id }
      (merge listing {
        quantity: quantity,
        price-per-unit: price-per-unit,
        delivery-terms: delivery-terms
      })
    )
    (ok true)
  )
)

;; Cancel a listing
(define-public (cancel-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? commodity-listings { listing-id: listing-id }) err-listing-not-found))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender (get seller listing)) err-not-authorized)
    
    ;; Check if listing is active
    (asserts! (is-eq (get status listing) status-active) err-invalid-status)
    
    ;; Cancel the listing
    (map-set commodity-listings
      { listing-id: listing-id }
      (merge listing { status: status-cancelled })
    )
    (ok true)
  )
)

;; Place a buy order
(define-public (place-buy-order
              (listing-id uint)
              (quantity uint)
              (price-per-unit uint))
  (let (
    (listing (unwrap! (map-get? commodity-listings { listing-id: listing-id }) err-listing-not-found))
    (order-id (get-next-order-id))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Check if listing is active
    (asserts! (is-eq (get status listing) status-active) err-invalid-status)
    
    ;; Check if quantity is available
    (asserts! (>= (get quantity listing) quantity) err-invalid-quantity)
    
    ;; Check if price is valid
    (asserts! (>= price-per-unit (get price-per-unit listing)) err-invalid-price)
    
    ;; Create the order
    (map-set orders
      { order-id: order-id }
      {
        creator: tx-sender,
        order-type: order-type-buy,
        listing-id: listing-id,
        quantity: quantity,
        price-per-unit: price-per-unit,
        status: status-active,
        created-at: current-time
      }
    )
    
    ;; Match the order with the listing
    (match-order-with-listing order-id tx-sender listing-id quantity price-per-unit)
  )
)

;; Place funds in escrow for a trade
(define-public (place-in-escrow (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; Check if caller is the buyer
    (asserts! (is-eq tx-sender (get buyer trade)) err-not-authorized)
    
    ;; Check if trade is in initiated status
    (asserts! (is-eq (get status trade) trade-status-initiated) err-invalid-status)
    
    ;; Process escrow (in production, this would transfer tokens to escrow)
    (try! (process-escrow trade-id (get total-amount trade) tx-sender))
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-escrowed,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    (ok true)
  )
)

;; Confirm shipment (by seller)
(define-public (confirm-shipment (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; Check if caller is the seller
    (asserts! (is-eq tx-sender (get seller trade)) err-not-authorized)
    
    ;; Check if trade is in escrowed status
    (asserts! (is-eq (get status trade) trade-status-escrowed) err-invalid-status)
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-in-delivery,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    (ok true)
  )
)

;; Confirm delivery (by buyer)
(define-public (confirm-delivery (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; Check if caller is the buyer
    (asserts! (is-eq tx-sender (get buyer trade)) err-not-authorized)
    
    ;; Check if trade is in delivery status
    (asserts! (is-eq (get status trade) trade-status-in-delivery) err-invalid-status)
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-delivered,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    (ok true)
  )
)

;; Complete trade and release funds to seller
(define-public (complete-trade (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; This function could be called by either buyer or seller after delivery is confirmed
    (asserts! (or (is-eq tx-sender (get buyer trade)) (is-eq tx-sender (get seller trade))) err-not-authorized)
    
    ;; Check if delivery has been confirmed
    (asserts! (is-eq (get status trade) trade-status-delivered) err-delivery-not-confirmed)
    
    ;; Release funds to seller
    (try! (release-escrow-to-seller trade-id (get seller trade)))
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-completed,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    (ok true)
  )
)

;; Dispute a trade
(define-public (dispute-trade (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; Only buyer can dispute a trade
    (asserts! (is-eq tx-sender (get buyer trade)) err-not-authorized)
    
    ;; Trade must be in delivery or delivered status to be disputed
    (asserts! (or (is-eq (get status trade) trade-status-in-delivery)
                 (is-eq (get status trade) trade-status-delivered))
             err-invalid-status)
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-disputed,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    ;; In a production contract, this would trigger notification to an arbitration system
    
    (ok true)
  )
)

;; Cancel a trade - only possible before escrow
(define-public (cancel-trade (trade-id uint))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; Either buyer or seller can cancel before escrow
    (asserts! (or (is-eq tx-sender (get buyer trade)) (is-eq tx-sender (get seller trade))) err-not-authorized)
    
    ;; Trade must be in initiated status to be cancelled
    (asserts! (is-eq (get status trade) trade-status-initiated) err-invalid-status)
    
    ;; Update trade status
    (map-set trades
      { trade-id: trade-id }
      (merge trade { 
        status: trade-status-cancelled,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )
    
    ;; Return quantity to listing
    (let (
      (listing (unwrap! (map-get? commodity-listings { listing-id: (get listing-id trade) }) err-listing-not-found))
    )
      (map-set commodity-listings
        { listing-id: (get listing-id trade) }
        (merge listing { 
          quantity: (+ (get quantity listing) (get quantity trade)),
          status: status-active
        })
      )
    )
    
    (ok true)
  )
)

;; Resolve a dispute (would typically be called by an authorized arbitrator)
;; This is a simplified implementation - in production this would have more complex logic
(define-public (resolve-dispute (trade-id uint) (in-favor-of-buyer bool))
  (let (
    (trade (unwrap! (map-get? trades { trade-id: trade-id }) err-order-not-found))
  )
    ;; In a production contract, this would check if tx-sender is an authorized arbitrator
    ;; For demo, we allow seller to resolve disputes (this would be replaced with proper arbitration)
    (asserts! (is-eq tx-sender (get seller trade)) err-not-authorized)
    
    ;; Trade must be in disputed status
    (asserts! (is-eq (get status trade) trade-status-disputed) err-invalid-status)
    
    (if in-favor-of-buyer
      ;; Return funds to buyer
      (begin
        (try! (return-escrow-to-buyer trade-id (get buyer trade)))
        
        ;; Update trade status
        (map-set trades
          { trade-id: trade-id }
          (merge trade { 
            status: trade-status-cancelled,
            updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
          })
        )
      )
      ;; Release funds to seller
      (begin
        (try! (release-escrow-to-seller trade-id (get seller trade)))
        
        ;; Update trade status
        (map-set trades
          { trade-id: trade-id }
          (merge trade { 
            status: trade-status-completed,
            updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
          })
        )
      )
    )
    
    (ok true)
  )
)