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

## Dashboard date range update
- Defaults the transaction list and dashboard totals to the most recent 30 days.
- Dashboard received/sent totals and transaction count follow the selected date range.
- Resetting filters returns to the default 30-day range.
- Restores the earlier transaction-language parser (including spent, paid, payment, and received patterns); it does not require only the words credited/debited.
- Excludes credit-card application acknowledgements such as SBI Card application status messages so the word "received" in an application acknowledgement is not treated as incoming money.
