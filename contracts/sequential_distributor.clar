;; Sequential Distribution Authorizer
;; This contract manages sequential distribution of tokenized assets with strict authorization controls.
;; It enables controlled, auditable asset allocation with granular access management.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ASSET-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-REGISTERED (err u102))
(define-constant ERR-INVALID-VERIFIER (err u103))
(define-constant ERR-NOT-VERIFIED (err u104))
(define-constant ERR-INSUFFICIENT-SHARES (err u105))
(define-constant ERR-ASSET-LOCKED (err u106))
(define-constant ERR-ESCROW-NOT-FOUND (err u107))
(define-constant ERR-PAYMENT-FAILED (err u108))
(define-constant ERR-INVALID-PARAMS (err u109))
(define-constant ERR-NOT-OWNER (err u110))
(define-constant ERR-SHARES-OUTSTANDING (err u111))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENT u5) ;; 5% platform fee
(define-constant MAX-SHARES-PER-ASSET u1000000) ;; Maximum number of shares per asset

;; Data Maps

;; Tracks all registered physical assets
(define-map assets
  { asset-id: uint }
  {
    owner: principal,           ;; Current owner for non-fractional assets or issuer for fractional assets
    description: (string-ascii 256),
    asset-type: (string-ascii 50),
    location: (string-ascii 100),
    valuation: uint,            ;; In STX
    creation-time: uint,        ;; Block height when created
    verified: bool,             ;; Whether the asset is verified by an authorized verifier
    verifier: (optional principal),
    verification-time: (optional uint),
    is-fractional: bool,        ;; Whether the asset has fractional ownership
    total-shares: uint,         ;; Total number of shares if fractional
    royalty-percent: uint,      ;; Royalty percentage for secondary sales
    metadata-url: (string-ascii 256),  ;; URL to additional metadata (could be IPFS)
    locked: bool                ;; Whether the asset is currently locked (e.g., in escrow)
  }
)

;; Tracks fractional ownership of assets
(define-map share-ownership
  { asset-id: uint, owner: principal }
  { shares: uint }
)

;; Tracks total outstanding shares per asset
(define-map asset-shares
  { asset-id: uint }
  { outstanding-shares: uint }
)

;; Registry of authorized verifiers
(define-map authorized-verifiers
  { verifier: principal }
  {
    name: (string-ascii 100),
    specialty: (string-ascii 100),  ;; e.g., "Real Estate", "Art", "Collectibles"
    approved-at: uint,              ;; Block height when approved
    active: bool
  }
)

;; Ownership history for each asset
(define-map ownership-history
  { asset-id: uint, index: uint }
  {
    previous-owner: principal,
    new-owner: principal,
    transaction-time: uint,    ;; Block height
    transaction-type: (string-ascii 20),  ;; "Creation", "Transfer", "Fractional"
    amount: uint               ;; Price in STX or 0 for initial creation
  }
)

;; Escrow for asset transfers
(define-map escrow-records
  { escrow-id: uint }
  {
    asset-id: uint,
    seller: principal,
    buyer: principal,
    price: uint,                ;; In STX
    is-fractional: bool,        ;; Whether this is a fractional transfer
    shares: uint,               ;; Number of shares if fractional
    creation-time: uint,        ;; Block height
    expiration-time: uint,      ;; Block height when escrow expires
    status: (string-ascii 20)   ;; "Active", "Completed", "Cancelled", "Expired"
  }
)

;; Data Variables
(define-data-var asset-id-nonce uint u0)
(define-data-var escrow-id-nonce uint u0)
(define-data-var history-index-nonce uint u0)

;; Private Functions

;; Generate a new unique asset ID
(define-private (generate-asset-id)
  (let ((new-id (+ (var-get asset-id-nonce) u1)))
    (var-set asset-id-nonce new-id)
    new-id
  )
)

;; Generate a new unique escrow ID
(define-private (generate-escrow-id)
  (let ((new-id (+ (var-get escrow-id-nonce) u1)))
    (var-set escrow-id-nonce new-id)
    new-id
  )
)

;; Generate a new history index for an asset
(define-private (generate-history-index)
  (let ((new-id (+ (var-get history-index-nonce) u1)))
    (var-set history-index-nonce new-id)
    new-id
  )
)

;; Check if caller is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; Check if caller is an authorized verifier
(define-private (is-authorized-verifier (verifier principal))
  (match (map-get? authorized-verifiers { verifier: verifier })
    verifier-info (and (get active verifier-info) true)
    false
  )
)

;; Check if caller is the asset owner
(define-private (is-asset-owner (asset-id uint))
  (match (map-get? assets { asset-id: asset-id })
    asset (is-eq tx-sender (get owner asset))
    false
  )
)

;; Add an entry to the ownership history
(define-private (add-ownership-history 
  (asset-id uint) 
  (previous-owner principal) 
  (new-owner principal)
  (transaction-type (string-ascii 20))
  (amount uint))
  
  (let ((history-index (generate-history-index)))
    (map-set ownership-history
      { asset-id: asset-id, index: history-index }
      {
        previous-owner: previous-owner,
        new-owner: new-owner,
        transaction-time: block-height,
        transaction-type: transaction-type,
        amount: amount
      }
    )
  )
)

;; Calculate platform fee
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENT) u100)
)

;; Calculate royalty fee
(define-private (calculate-royalty-fee (amount uint) (royalty-percent uint))
  (/ (* amount royalty-percent) u100)
)

;; Transfer STX with royalty and platform fee calculation
(define-private (transfer-stx-with-fees (receiver principal) (amount uint) (asset-id uint))
  (let
    (
      (asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (platform-fee (calculate-platform-fee amount))
      (royalty-fee (calculate-royalty-fee amount (get royalty-percent asset)))
      (seller-amount (- amount (+ platform-fee royalty-fee)))
    )
    (begin
      ;; Send platform fee to contract owner
      (unwrap! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER) ERR-PAYMENT-FAILED)
      
      ;; Send royalty to original asset issuer if not the current seller
      (if (not (is-eq (get owner asset) tx-sender))
          (unwrap! (stx-transfer? royalty-fee tx-sender (get owner asset)) ERR-PAYMENT-FAILED)
          true)
      
      ;; Send remaining amount to receiver
      (unwrap! (stx-transfer? seller-amount tx-sender receiver) ERR-PAYMENT-FAILED)
      (ok true)
    )
  )
)

;; Read-only Functions

;; Get asset details
(define-read-only (get-asset (asset-id uint))
  (map-get? assets { asset-id: asset-id })
)

;; Get share ownership for a specific owner and asset
(define-read-only (get-share-ownership (asset-id uint) (owner principal))
  (map-get? share-ownership { asset-id: asset-id, owner: owner })
)

;; Get total outstanding shares for an asset
(define-read-only (get-outstanding-shares (asset-id uint))
  (default-to { outstanding-shares: u0 }
    (map-get? asset-shares { asset-id: asset-id }))
)

;; Check if a principal is an authorized verifier
(define-read-only (is-verifier (verifier principal))
  (is-some (map-get? authorized-verifiers { verifier: verifier }))
)

;; Get verifier details
(define-read-only (get-verifier-info (verifier principal))
  (map-get? authorized-verifiers { verifier: verifier })
)

;; Get escrow details
(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrow-records { escrow-id: escrow-id })
)

;; Public Functions

;; Register a new asset
(define-public (register-asset
  (description (string-ascii 256))
  (asset-type (string-ascii 50))
  (location (string-ascii 100))
  (valuation uint)
  (is-fractional bool)
  (total-shares uint)
  (royalty-percent uint)
  (metadata-url (string-ascii 256)))
  
  (let ((asset-id (generate-asset-id)))
    (asserts! (or (not is-fractional) (<= total-shares MAX-SHARES-PER-ASSET)) ERR-INVALID-PARAMS)
    (asserts! (<= royalty-percent u50) ERR-INVALID-PARAMS) ;; Limit royalty to 50%
    
    ;; Create the asset record
    (map-set assets
      { asset-id: asset-id }
      {
        owner: tx-sender,
        description: description,
        asset-type: asset-type,
        location: location,
        valuation: valuation,
        creation-time: block-height,
        verified: false,
        verifier: none,
        verification-time: none,
        is-fractional: is-fractional,
        total-shares: (if is-fractional total-shares u1),
        royalty-percent: royalty-percent,
        metadata-url: metadata-url,
        locked: false
      }
    )
    
    ;; Set up share ownership if fractional
    (if is-fractional
      (begin
        ;; Initialize share ownership for the creator
        (map-set share-ownership
          { asset-id: asset-id, owner: tx-sender }
          { shares: total-shares }
        )
        
        ;; Track total outstanding shares
        (map-set asset-shares
          { asset-id: asset-id }
          { outstanding-shares: total-shares }
        )
      )
      true
    )
    
    ;; Record initial ownership
    (add-ownership-history asset-id tx-sender tx-sender "Creation" u0)
    
    (ok asset-id)
  )
)

;; Add a new authorized verifier (contract owner only)
(define-public (add-authorized-verifier
  (verifier principal)
  (name (string-ascii 100))
  (specialty (string-ascii 100)))
  
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-verifier verifier)) ERR-ALREADY-REGISTERED)
    
    (map-set authorized-verifiers
      { verifier: verifier }
      {
        name: name,
        specialty: specialty,
        approved-at: block-height,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Deactivate a verifier (contract owner only)
(define-public (deactivate-verifier (verifier principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-verifier verifier) ERR-INVALID-VERIFIER)

    ;; Get the verifier info, unwrap will succeed because of the assert above
    (let ((verifier-info (unwrap! (map-get? authorized-verifiers { verifier: verifier }) ERR-INVALID-VERIFIER)))
        ;; Deactivate the verifier by setting active to false
        (map-set authorized-verifiers
          { verifier: verifier }
          (merge verifier-info { active: false })
        )
        ;; The map-set returns (ok true), but we ignore it here.
    )
    
    (ok true) ;; Return success for the function call
  )
)

;; Verify an asset (authorized verifiers only)
(define-public (verify-asset (asset-id uint))
  (let ((asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND)))
    (asserts! (is-authorized-verifier tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get verified asset)) ERR-ALREADY-REGISTERED)
    
    (map-set assets
      { asset-id: asset-id }
      (merge asset 
        { 
          verified: true,
          verifier: (some tx-sender),
          verification-time: (some block-height)
        }
      )
    )
    
    (ok true)
  )
)

;; Transfer a non-fractional asset
(define-public (transfer-asset (asset-id uint) (recipient principal))
  (let ((asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get owner asset)) ERR-NOT-OWNER)
    (asserts! (not (get is-fractional asset)) ERR-INVALID-PARAMS)
    (asserts! (not (get locked asset)) ERR-ASSET-LOCKED)
    
    ;; Update asset ownership
    (map-set assets
      { asset-id: asset-id }
      (merge asset { owner: recipient })
    )
    
    ;; Record ownership history
    (add-ownership-history asset-id tx-sender recipient "Transfer" u0)
    
    (ok true)
  )
)

;; Transfer fractional shares of an asset
(define-public (transfer-shares (asset-id uint) (recipient principal) (share-count uint))
  (let
    (
      (asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (sender-shares (default-to { shares: u0 } 
                     (map-get? share-ownership { asset-id: asset-id, owner: tx-sender })))
      (recipient-shares (default-to { shares: u0 } 
                        (map-get? share-ownership { asset-id: asset-id, owner: recipient })))
    )
    (asserts! (get is-fractional asset) ERR-INVALID-PARAMS)
    (asserts! (not (get locked asset)) ERR-ASSET-LOCKED)
    (asserts! (>= (get shares sender-shares) share-count) ERR-INSUFFICIENT-SHARES)
    
    ;; Update sender's shares
    (map-set share-ownership
      { asset-id: asset-id, owner: tx-sender }
      { shares: (- (get shares sender-shares) share-count) }
    )
    
    ;; Update recipient's shares
    (map-set share-ownership
      { asset-id: asset-id, owner: recipient }
      { shares: (+ (get shares recipient-shares) share-count) }
    )
    
    ;; Record ownership history
    (add-ownership-history asset-id tx-sender recipient "Fractional" u0)
    
    (ok true)
  )
)

;; Create an escrow to sell a non-fractional asset
(define-public (create-asset-escrow (asset-id uint) (buyer principal) (price uint) (expiration-blocks uint))
  (let
    (
      (asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (escrow-id (generate-escrow-id))
    )
    (asserts! (is-eq tx-sender (get owner asset)) ERR-NOT-OWNER)
    (asserts! (not (get is-fractional asset)) ERR-INVALID-PARAMS)
    (asserts! (not (get locked asset)) ERR-ASSET-LOCKED)
    
    ;; Lock the asset
    (map-set assets
      { asset-id: asset-id }
      (merge asset { locked: true })
    )
    
    ;; Create escrow record
    (map-set escrow-records
      { escrow-id: escrow-id }
      {
        asset-id: asset-id,
        seller: tx-sender,
        buyer: buyer,
        price: price,
        is-fractional: false,
        shares: u0,
        creation-time: block-height,
        expiration-time: (+ block-height expiration-blocks),
        status: "Active"
      }
    )
    
    (ok escrow-id)
  )
)

;; Create an escrow to sell fractional shares
(define-public (create-shares-escrow (asset-id uint) (buyer principal) (shares uint) (price uint) (expiration-blocks uint))
  (let
    (
      (asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (sender-shares (default-to { shares: u0 } 
                     (map-get? share-ownership { asset-id: asset-id, owner: tx-sender })))
      (escrow-id (generate-escrow-id))
    )
    (asserts! (get is-fractional asset) ERR-INVALID-PARAMS)
    (asserts! (>= (get shares sender-shares) shares) ERR-INSUFFICIENT-SHARES)
    
    ;; Create escrow record
    (map-set escrow-records
      { escrow-id: escrow-id }
      {
        asset-id: asset-id,
        seller: tx-sender,
        buyer: buyer,
        price: price,
        is-fractional: true,
        shares: shares,
        creation-time: block-height,
        expiration-time: (+ block-height expiration-blocks),
        status: "Active"
      }
    )
    
    (ok escrow-id)
  )
)

;; Complete an escrow as the buyer
(define-public (complete-escrow (escrow-id uint))
  (let
    (
      (escrow (unwrap! (map-get? escrow-records { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
      (asset (unwrap! (map-get? assets { asset-id: (get asset-id escrow) }) ERR-ASSET-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get buyer escrow)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) "Active") ERR-ESCROW-NOT-FOUND)
    (asserts! (< block-height (get expiration-time escrow)) ERR-ESCROW-NOT-FOUND)
    
    ;; Process payment with fees
    (unwrap! (transfer-stx-with-fees (get seller escrow) (get price escrow) (get asset-id escrow)) ERR-PAYMENT-FAILED)
    
    ;; Update escrow status
    (map-set escrow-records
      { escrow-id: escrow-id }
      (merge escrow { status: "Completed" })
    )
    
    ;; If non-fractional, transfer the asset ownership
    (if (not (get is-fractional escrow))
      (begin
        ;; Update asset ownership
        (map-set assets
          { asset-id: (get asset-id escrow) }
          (merge asset { owner: tx-sender, locked: false })
        )
        
        ;; Record ownership history
        (add-ownership-history (get asset-id escrow) (get seller escrow) tx-sender "Transfer" (get price escrow))
        
        (ok true)
      )
      ;; If fractional, transfer the shares
      (let
        (
          (seller-shares (default-to { shares: u0 } 
                        (map-get? share-ownership { asset-id: (get asset-id escrow), owner: (get seller escrow) })))
          (buyer-shares (default-to { shares: u0 } 
                        (map-get? share-ownership { asset-id: (get asset-id escrow), owner: tx-sender })))
        )
        (begin
          ;; Update seller's shares
          (map-set share-ownership
            { asset-id: (get asset-id escrow), owner: (get seller escrow) }
            { shares: (- (get shares seller-shares) (get shares escrow)) }
          )
          
          ;; Update buyer's shares
          (map-set share-ownership
            { asset-id: (get asset-id escrow), owner: tx-sender }
            { shares: (+ (get shares buyer-shares) (get shares escrow)) }
          )
          
          ;; Record ownership history
          (add-ownership-history (get asset-id escrow) (get seller escrow) tx-sender "Fractional" (get price escrow))
          
          (ok true)
        )
      )
    )
  )
)

;; Cancel an escrow as the seller
(define-public (cancel-escrow (escrow-id uint))
  (let
    (
      (escrow (unwrap! (map-get? escrow-records { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
      (asset (unwrap! (map-get? assets { asset-id: (get asset-id escrow) }) ERR-ASSET-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get seller escrow)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) "Active") ERR-ESCROW-NOT-FOUND)
    
    ;; Update escrow status
    (map-set escrow-records
      { escrow-id: escrow-id }
      (merge escrow { status: "Cancelled" })
    )
    
    ;; If non-fractional, unlock the asset
    (if (not (get is-fractional escrow))
      (map-set assets
        { asset-id: (get asset-id escrow) }
        (merge asset { locked: false })
      )
      true
    )
    
    (ok true)
  )
)

;; Update asset metadata (owner only)
(define-public (update-asset-metadata 
  (asset-id uint)
  (description (string-ascii 256))
  (location (string-ascii 100))
  (valuation uint)
  (metadata-url (string-ascii 256)))
  
  (let ((asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get owner asset)) ERR-NOT-OWNER)
    (asserts! (not (get locked asset)) ERR-ASSET-LOCKED)
    
    (map-set assets
      { asset-id: asset-id }
      (merge asset 
        { 
          description: description,
          location: location,
          valuation: valuation,
          metadata-url: metadata-url
        }
      )
    )
    
    (ok true)
  )
)

;; Burn/retire an asset (owner only)
(define-public (retire-asset (asset-id uint))
  (let
    (
      (asset (unwrap! (map-get? assets { asset-id: asset-id }) ERR-ASSET-NOT-FOUND))
      (outstanding (get outstanding-shares (default-to { outstanding-shares: u0 }
                                          (map-get? asset-shares { asset-id: asset-id }))))
    )
    (asserts! (is-eq tx-sender (get owner asset)) ERR-NOT-OWNER)
    (asserts! (not (get locked asset)) ERR-ASSET-LOCKED)
    
    ;; If fractional, ensure all shares are owned by the owner before retiring
    (if (get is-fractional asset)
      (begin
        (asserts! (is-eq outstanding (get shares (default-to { shares: u0 }
                              (map-get? share-ownership { asset-id: asset-id, owner: tx-sender })))) 
                  ERR-SHARES-OUTSTANDING)
        
        ;; Clear share ownership
        (map-delete share-ownership { asset-id: asset-id, owner: tx-sender })
        (map-delete asset-shares { asset-id: asset-id })
      )
      true
    )
    
    ;; Mark the asset as locked to signify retirement
    (map-set assets
      { asset-id: asset-id }
      (merge asset 
        { 
          locked: true
        }
      )
    )
    
    (ok true)
  )
)