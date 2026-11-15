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
