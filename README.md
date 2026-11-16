# FinLedger

FinLedger is an offline-first Android bank-SMS transaction viewer.

## Scope
- Imports bank transaction SMS from the Android inbox and receives new SMS through the Android receiver.
- Extracts transaction amount, incoming/outgoing direction, bank, masked source account, transfer method, counterparty identifier and reference where present.
- Shows a chronological transaction feed.
- Filters by bank, payment type (UPI, IMPS, NEFT, RTGS, card, etc.), direction and date range.
- Searches transaction descriptions, account identifiers and references.
- Opens a detail view with extracted fields and the stored SMS text.
- Stores data locally in SQLite. No backend or cloud account.

Loans, settlements, relationship management and financial-planning dashboards are intentionally outside the product scope.

## Build APK using GitHub Actions
1. Extract this ZIP.
2. In your existing GitHub repository, replace the project files with the contents of the `FinLedger` folder (including `.github` and `android_overrides`).
3. Commit and push to `main`.
4. Open GitHub → Actions → Build FinLedger APK.
5. When the workflow succeeds, download the `FinLedger-Android-APK` artifact and install the APK as an update over the existing app. Do not uninstall the existing app; its local SQLite data is stored on the device.

## Notes
- SMS parsing depends on the wording used by each bank. Validate sample messages from your banks.
- Names are shown only when present in the SMS; otherwise the available UPI ID/account identifier is used.
- Imported transactions are not guaranteed to represent a verified bank balance.


## UI refresh
The transaction home now has a compact overview, search, quick direction chips, a filter sheet, date-grouped transaction rows, and a redesigned detail view. Transaction parsing and local storage remain unchanged in this UI-only refresh.


### SMS classification corrections (November 2026)
- Merchant/service payment receipts such as Airtel's “we have received a payment … for your plan” are classified as outgoing bill payments, not incoming credits.
- Promotional SMS containing payment/cashback offers and a call to action (for example POP UPI cashback advertisements) are ignored and do not create ledger or review entries.

### SMS classification updates
- Credit-card EMI-conversion promotions and bill-due reminders are ignored; they do not create transactions or review-required records.
- Promotional/payment-call-to-action messages remain excluded from the transaction ledger.
- Merchant payment receipts are classified from the customer's perspective (for example, a merchant confirming receipt of a bill payment is treated as an outgoing payment).

## SMS source-of-truth rule

Only SMS originating from a recognized bank sender ID can create incoming, outgoing, or transfer ledger entries. Financial messages from merchants, wallets, and other non-bank senders are retained as supporting SMS only; when amount and timestamp match exactly one bank-confirmed transaction, the SMS is linked as supporting evidence. Non-bank messages never create or change ledger cash totals. This rule applies to newly imported messages; it does not automatically rewrite historical transactions already stored on a device.


## Clean testing build (schema v7)

On the first launch after upgrading an existing v6 installation, this testing build clears FinLedger's previously imported ledger/database records (transactions, parsed SMS records, accounts, parties, links, and derived intelligence) once. This is intentional so the new bank-confirmation-first parser can be tested from a clean state. It does **not** delete SMS from the Android Messages inbox, change SMS permissions, or uninstall the app. After the upgrade, open FinLedger and tap **Import SMS** to scan the inbox again using the new rules. Do not expect the old in-app transaction history to remain in this test build.
