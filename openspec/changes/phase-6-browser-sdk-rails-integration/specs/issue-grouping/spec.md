# issue-grouping Specification

## MODIFIED Requirements

### Requirement: Deterministic SHA-256 fingerprinting with explicit fingerprint support
Issue fingerprinting SHALL produce a deterministic 64-character SHA-256 hex digest using (1) explicit non-default Sentry `fingerprint` arrays, otherwise (2) exception class plus normalized frames (stripping deploy paths, URL origins/queries, and JS/TS asset content-digest hashes), otherwise (3) exception class and volatile-stripped message, excluding `environment`.

#### Scenario: Identical exceptions across staging and production produce the same fingerprint
- **WHEN** the same `NoMethodError` with identical application stack frames occurs in `staging` and in `production` (even under different release deploy paths such as `/releases/20261115/app/models/order.rb` vs `/releases/20261116/app/models/order.rb`)
- **THEN** both events compute the exact same SHA-256 fingerprint

#### Scenario: Browser exceptions across origins and hashed JS asset bundles produce the same fingerprint
- **WHEN** the same `TypeError` occurs at `https://staging.example.com/assets/checkout-a1b2c3d4.js?v=1` (`submitOrder`) and at `https://app.example.com/assets/checkout-9f8e7d6c.js` (`submitOrder`)
- **THEN** URL origins, query strings, and content-digest suffixes normalize to `assets/checkout.js:submitOrder` and both events share the exact same SHA-256 fingerprint

#### Scenario: Explicit custom Sentry fingerprint overrides default frame grouping
- **WHEN** two events with different stack frames carry `fingerprint: ["checkout-gateway-timeout"]`
- **THEN** both events compute the same SHA-256 fingerprint and group into a single issue

#### Scenario: Message-only events strip volatile IDs and UUIDs for stable grouping
- **WHEN** two message events without stack frames arrive with `"Order 12345 failed for request 550e8400-e29b-41d4-a716-446655440000"` and `"Order 98765 failed for request 6ba7b810-9dad-11d1-80b4-00c04fd430c8"`
- **THEN** volatile numeric IDs and UUIDs are normalized so both events share one fingerprint
