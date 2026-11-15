import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'database.dart';
import 'transaction_intelligence.dart';

/// Phase 2: preserves each financial SMS and writes parsed financial events
/// into the canonical ledger while maintaining the legacy table for the UI.
class SmsImporter {
  static const MethodChannel _channel = MethodChannel('com.finledger.app/sms');

  static final RegExp _money = RegExp(
    r'(?:INR|Rs\.?|₹)\s*([0-9,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final RegExp _upiId = RegExp(
    r'\b[a-zA-Z0-9._-]{2,}@[a-zA-Z][a-zA-Z0-9._-]{1,}\b',
  );
  static final RegExp _reference = RegExp(
    r'(?:UPI\s*)?(?:Ref(?:erence)?(?:\s*(?:No|ID))?|UTR|RRN|IMPS\s*Ref)\s*[:#-]?\s*([A-Za-z0-9-]{6,35})',
    caseSensitive: false,
  );
  static final RegExp _accountToken = RegExp(
    r'(?:\bA/c\b|\baccount\b|\bacct\b|\bcard\b)\s*(?:no\.?\s*)?(?:ending\s*(?:with\s*)?)?(?:XX|X{2,}|\*{2,})?\s*([0-9]{3,6})\b',
    caseSensitive: false,
  );
  static final RegExp _maskedAccount = RegExp(r'(?:XX|X{2,}|\*{2,})([0-9]{3,6})\b', caseSensitive: false);

  /// Returns the number of new financial events created (not SMS count).
  static Future<int> importInbox() async {
    final messages = await _channel.invokeListMethod<Map<dynamic, dynamic>>('importInbox') ?? [];
    return _saveMessages(messages);
  }

  /// Imports queued real-time messages. Queue rows are acknowledged only after
  /// their contents have been safely persisted locally.
  static Future<int> importPending() async {
    final messages = await _channel.invokeListMethod<Map<dynamic, dynamic>>('getPendingSms') ?? [];
    final created = await _saveMessages(messages);
    final ids = messages
        .map((m) => m['id'])
        .where((id) => id != null)
        .map((id) => (id as num).toInt())
        .toList();
    if (ids.isNotEmpty) {
      await _channel.invokeMethod<void>('ackPendingSms', {'ids': ids});
    }
    return created;
  }

  static Future<int> _saveMessages(List<Map<dynamic, dynamic>> messages) async {
    final db = await FinDatabase.instance.database;
    var createdEvents = 0;

    for (final raw in messages) {
      final body = (raw['body'] ?? '').toString().trim();
      final sender = (raw['sender'] ?? '').toString().trim();
      final receivedAt = (raw['date'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
      final inboxId = raw['inboxId']?.toString();
      if (body.isEmpty || _isOtp(body)) continue;

      final parsed = _parse(body, sender, receivedAt);
      if (parsed == null) {
        if (_looksFinancial(body)) {
          await _saveUnparsedFinancialSms(db, sender, body, receivedAt, inboxId);
        }
        continue;
      }

      final smsFingerprint = _smsFingerprint(sender, body, receivedAt);
      final now = DateTime.now().millisecondsSinceEpoch;

      final result = await db.transaction<int>((txn) async {
        final insertedSmsId = await txn.insert(
          'sms_messages',
          {
            'sender_address': sender,
            'sender_name': null,
            'body': body,
            'received_at': receivedAt,
            'inbox_message_id': inboxId,
            'sms_fingerprint': smsFingerprint,
            'is_financial': 1,
            'processing_status': 'PENDING',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );

        int smsId = insertedSmsId;
        if (smsId <= 0) {
          final existingSms = await txn.query(
            'sms_messages',
            columns: ['id', 'processing_status'],
            where: 'sms_fingerprint = ?',
            whereArgs: [smsFingerprint],
            limit: 1,
          );
          if (existingSms.isEmpty) return 0;
          smsId = (existingSms.first['id'] as num).toInt();
          // Already handled from inbox or receiver queue; don't create another event.
          if ((existingSms.first['processing_status'] ?? 'PENDING') != 'PENDING') return 0;
        }

        if (parsed.isCardSideConfirmation) {
          final linked = await _linkCardConfirmation(txn, parsed, smsId, now);
          await txn.update(
            'sms_messages',
            {'processing_status': linked ? 'CARD_CONFIRMATION_LINKED' : 'CARD_CONFIRMATION_PENDING'},
            where: 'id = ?',
            whereArgs: [smsId],
          );
          return 0;
        }

        if (!parsed.isTransaction) {
          await txn.update('sms_messages', {'processing_status': 'REVIEW_REQUIRED'}, where: 'id = ?', whereArgs: [smsId]);
          return 0;
        }

        final transactionId = await _upsertFinancialEvent(txn, parsed, now);
        await txn.insert(
          'transaction_sms_links',
          {
            'transaction_id': transactionId,
            'sms_message_id': smsId,
            'message_role': 'PRIMARY',
            'linked_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await _writeTransactionLegs(txn, transactionId, parsed);
        final accountRows = await txn.query('transaction_legs', columns: ['account_id'],
          where: 'transaction_id = ? AND account_id IS NOT NULL', whereArgs: [transactionId], limit: 1);
        await TransactionIntelligence.evaluate(
          db: txn,
          transactionId: transactionId,
          amountMinor: (parsed.amount * 100).round(),
          direction: parsed.direction,
          date: parsed.date,
          ownAccountId: accountRows.isEmpty ? null : (accountRows.first['account_id'] as num).toInt(),
          reference: parsed.reference,
          counterpartyIdentifier: parsed.upiId ?? (parsed.destinationAccountSuffix == null ? null : 'account:${parsed.destinationAccountSuffix}'),
        );
        await _upsertLegacyTransaction(txn, parsed);
        if (parsed.isCardBill) {
          await _linkPendingCardConfirmations(txn, transactionId, parsed, now);
        }
        await txn.update('sms_messages', {'processing_status': 'PROCESSED'}, where: 'id = ?', whereArgs: [smsId]);
        return 1;
      });
      createdEvents += result;
    }
    return createdEvents;
  }

  static ParsedBankSms? _parse(String body, String sender, int date) {
    final lower = body.toLowerCase();
    final hasTransactionLanguage = RegExp(
      r'\b(debited|credited|withdrawn|deposited|spent|received|transferred|transfer|purchase|paid|payment|refund|reversed|cashback)\b',
    ).hasMatch(lower);
    final amountMatch = _money.firstMatch(body);
    if (!hasTransactionLanguage || amountMatch == null) return null;
    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));
    if (amount == null || amount <= 0) return null;

    final isCardBill = RegExp(
      r'(credit\s*card|card\s*(?:bill|payment|account)).{0,100}(payment|bill|paid|received|credited)|'
      r'(payment|bill|paid|received|credited).{0,100}(credit\s*card|card\s*(?:bill|account))',
    ).hasMatch(lower);
    final debit = RegExp(r'\b(debited|withdrawn|spent|purchase|paid)\b').hasMatch(lower);
    final credit = RegExp(r'\b(credited|deposited|received|refund|cashback)\b').hasMatch(lower);
    final reversal = RegExp(r'\b(refund|reversed|reversal|cashback)\b').hasMatch(lower);

    final isCardSideReceipt = isCardBill && !debit &&
        RegExp(r'\b(received|credited|posted|thank you|payment successful)\b').hasMatch(lower);

    String direction;
    String legacyType;
    String category;
    if (isCardBill) {
      direction = 'TRANSFER';
      legacyType = 'TRANSFER';
      category = 'Credit Card Payment';
    } else if (reversal || (credit && !debit)) {
      direction = 'INCOMING';
      legacyType = 'CREDIT';
      category = reversal ? 'Refund' : _category(body);
    } else if (debit && !credit) {
      direction = 'OUTGOING';
      legacyType = 'DEBIT';
      category = _category(body);
    } else if (RegExp(r'\b(transferred|transfer)\b').hasMatch(lower)) {
      direction = 'TRANSFER';
      legacyType = 'TRANSFER';
      category = 'Transfer';
    } else {
      return ParsedBankSms.unclassified(body, sender, date, amount, isCardSideReceipt);
    }

    final bank = _bankName('$body $sender');
    final accountMatches = _accountToken.allMatches(body).toList();
    final maskedMatches = _maskedAccount.allMatches(body).toList();
    final sourceSuffix = _extractAccountNear(body, r'(?:from|debited\s+from|sent\s+from|withdrawn\s+from)');
    final fallbackSuffix = accountMatches.isNotEmpty
        ? accountMatches.first.group(1)
        : (maskedMatches.isNotEmpty ? maskedMatches.first.group(1) : null);
    final ownSuffix = sourceSuffix ?? fallbackSuffix;
    final destinationSuffix = _extractAccountNear(body, r'(?:to|towards|beneficiary|credited\s+to)');
    final upi = _upiId.firstMatch(body)?.group(0);
    final reference = _reference.firstMatch(body)?.group(1);
    final method = _paymentMethod(lower);
    final merchant = _counterpartyName(body, upi);
    final accountDisplay = [
      if (bank != null) bank else 'Bank account',
      if (ownSuffix != null) '••••$ownSuffix',
    ].join(' ');

    final fingerprint = reference != null
        ? 'ref-${reference.toUpperCase()}'
        : 'evt-$direction-${amount.toStringAsFixed(2)}-${date ~/ 60000}-${(ownSuffix ?? 'na')}-${(destinationSuffix ?? upi ?? sender).toLowerCase()}';

    return ParsedBankSms(
      body: body,
      sender: sender,
      date: date,
      amount: amount,
      direction: direction,
      legacyType: legacyType,
      category: category,
      bankName: bank,
      ownAccountSuffix: ownSuffix,
      destinationAccountSuffix: destinationSuffix,
      upiId: upi,
      reference: reference,
      paymentMethod: method,
      merchant: merchant,
      accountDisplay: accountDisplay,
      fingerprint: fingerprint,
      isCardBill: isCardBill,
      isCardSideConfirmation: isCardSideReceipt,
      isTransaction: !isCardSideReceipt,
    );
  }

  static Future<int> _upsertFinancialEvent(Transaction txn, ParsedBankSms sms, int now) async {
    final existing = await txn.query(
      'financial_transactions',
      columns: ['id'],
      where: 'fingerprint = ?',
      whereArgs: [sms.fingerprint],
      limit: 1,
    );
    if (existing.isNotEmpty) return (existing.first['id'] as num).toInt();

    // A reference number is the strongest bank-provided transaction key.
    if (sms.reference != null) {
      final byReference = await txn.query(
        'financial_transactions',
        columns: ['id'],
        where: 'reference_number = ? AND amount_minor = ?',
        whereArgs: [sms.reference, (sms.amount * 100).round()],
        limit: 1,
      );
      if (byReference.isNotEmpty) {
        final matchedId = (byReference.first['id'] as num).toInt();
        final existingDirection = (await txn.query('financial_transactions', columns: ['direction'], where: 'id = ?', whereArgs: [matchedId], limit: 1)).first['direction']?.toString();
        if ((existingDirection == 'INCOMING' && sms.direction == 'OUTGOING') ||
            (existingDirection == 'OUTGOING' && sms.direction == 'INCOMING')) {
          await txn.update('financial_transactions', {'direction': 'TRANSFER', 'updated_at': now}, where: 'id = ?', whereArgs: [matchedId]);
        }
        return matchedId;
      }
    }

    return await txn.insert('financial_transactions', {
      'amount_minor': (sms.amount * 100).round(),
      'currency': 'INR',
      'direction': sms.direction,
      'payment_method': sms.paymentMethod,
      'transaction_date': sms.date,
      'description': sms.merchant.isNotEmpty ? sms.merchant : _defaultDescription(sms),
      'narration': sms.body,
      'reference_number': sms.reference,
      'category': sms.category,
      'status': 'POSTED',
      'source': 'SMS',
      'fingerprint': sms.fingerprint,
      'legacy_transaction_id': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _writeTransactionLegs(Transaction txn, int transactionId, ParsedBankSms sms) async {
    final existingLegs = await txn.query(
      'transaction_legs',
      columns: ['id'],
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
      limit: 1,
    );
    if (existingLegs.isNotEmpty) return;

    int? accountId;
    if (sms.bankName != null && sms.ownAccountSuffix != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.insert(
        'bank_accounts',
        {
          'bank_name': sms.bankName,
          'account_suffix': sms.ownAccountSuffix,
          'account_type': 'UNKNOWN',
          'display_name': '${sms.bankName} ••••${sms.ownAccountSuffix}',
          'currency': 'INR',
          'is_own_account': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final account = await txn.query(
        'bank_accounts',
        columns: ['id'],
        where: 'bank_name = ? AND account_suffix = ? AND account_type = ?',
        whereArgs: [sms.bankName, sms.ownAccountSuffix, 'UNKNOWN'],
        limit: 1,
      );
      if (account.isNotEmpty) accountId = (account.first['id'] as num).toInt();
    }

    final ownLegDirection = sms.direction == 'INCOMING' ? 'INCOMING' : 'OUTGOING';
    await txn.insert(
      'transaction_legs',
      {
        'transaction_id': transactionId,
        'account_id': accountId,
        'party_id': null,
        'leg_role': sms.direction == 'INCOMING' ? 'DESTINATION_ACCOUNT' : 'SOURCE_ACCOUNT',
        'direction': ownLegDirection,
        'amount_minor': (sms.amount * 100).round(),
        'notes': accountId == null ? sms.accountDisplay : null,
      },
    );

    final counterparty = sms.destinationAccountSuffix != null
        ? 'Account XXX${sms.destinationAccountSuffix}'
        : sms.upiId;
    if (counterparty != null && counterparty.isNotEmpty) {
      await txn.insert(
        'transaction_legs',
        {
          'transaction_id': transactionId,
          'account_id': null,
          'party_id': null,
          'leg_role': 'COUNTERPARTY',
          'direction': sms.direction == 'INCOMING' ? 'OUTGOING' : 'INCOMING',
          'amount_minor': (sms.amount * 100).round(),
          'notes': counterparty,
        },
      );
    }
  }

  static Future<void> _upsertLegacyTransaction(Transaction txn, ParsedBankSms sms) async {
    final legacyFingerprint = sms.reference != null
        ? 'sms-${sms.reference}'
        : 'sms-${sms.sender.toLowerCase()}-${sms.date ~/ 60000}-${sms.amount.toStringAsFixed(2)}-${sms.direction}';
    final existing = await txn.query('transactions', columns: ['id'], where: 'fingerprint = ?', whereArgs: [legacyFingerprint], limit: 1);
    final row = <String, Object?>{
      'amount': sms.amount,
      'type': sms.legacyType,
      'category': sms.category,
      'merchant': sms.merchant,
      'description': sms.body.length > 240 ? sms.body.substring(0, 240) : sms.body,
      'date': sms.date,
      'mode': sms.paymentMethod,
      'account': sms.accountDisplay,
      'fingerprint': legacyFingerprint,
      'source': 'SMS',
    };
    int legacyId;
    if (existing.isEmpty) {
      legacyId = await txn.insert('transactions', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (legacyId <= 0) {
        final inserted = await txn.query('transactions', columns: ['id'],
          where: 'fingerprint = ?', whereArgs: [legacyFingerprint], limit: 1);
        if (inserted.isEmpty) return;
        legacyId = (inserted.first['id'] as num).toInt();
      }
    } else {
      legacyId = (existing.first['id'] as num).toInt();
      await txn.update('transactions', row, where: 'id = ?', whereArgs: [legacyId]);
    }
    await txn.update(
      'financial_transactions',
      {'legacy_transaction_id': legacyId, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'fingerprint = ? OR (reference_number = ? AND amount_minor = ?)',
      whereArgs: [sms.fingerprint, sms.reference, (sms.amount * 100).round()],
    );
  }

  static Future<void> _linkPendingCardConfirmations(
    Transaction txn,
    int transactionId,
    ParsedBankSms primary,
    int now,
  ) async {
    final start = primary.date - const Duration(hours: 48).inMilliseconds;
    final end = primary.date + const Duration(hours: 48).inMilliseconds;
    final pending = await txn.query(
      'sms_messages',
      columns: ['id', 'sender_address', 'body', 'received_at'],
      where: "processing_status = 'CARD_CONFIRMATION_PENDING' AND received_at BETWEEN ? AND ?",
      whereArgs: [start, end],
    );
    for (final message in pending) {
      final confirmation = _parse(
        (message['body'] ?? '').toString(),
        (message['sender_address'] ?? '').toString(),
        (message['received_at'] as num).toInt(),
      );
      if (confirmation == null || !confirmation.isCardSideConfirmation) continue;
      if ((confirmation.amount * 100).round() != (primary.amount * 100).round()) continue;
      await txn.insert(
        'transaction_sms_links',
        {
          'transaction_id': transactionId,
          'sms_message_id': message['id'],
          'message_role': 'CARD_SIDE_CONFIRMATION',
          'linked_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await txn.update(
        'sms_messages',
        {'processing_status': 'CARD_CONFIRMATION_LINKED'},
        where: 'id = ?',
        whereArgs: [message['id']],
      );
    }
  }

  static Future<bool> _linkCardConfirmation(Transaction txn, ParsedBankSms sms, int smsId, int now) async {
    final start = sms.date - const Duration(hours: 48).inMilliseconds;
    final end = sms.date + const Duration(hours: 48).inMilliseconds;
    final candidates = await txn.query(
      'financial_transactions',
      columns: ['id'],
      where: "direction = 'TRANSFER' AND category = 'Credit Card Payment' AND amount_minor = ? AND transaction_date BETWEEN ? AND ?",
      whereArgs: [(sms.amount * 100).round(), start, end],
      orderBy: 'ABS(transaction_date - ${sms.date}) ASC',
      limit: 1,
    );
    if (candidates.isEmpty) return false;
    await txn.insert(
      'transaction_sms_links',
      {
        'transaction_id': candidates.first['id'],
        'sms_message_id': smsId,
        'message_role': 'CARD_SIDE_CONFIRMATION',
        'linked_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return true;
  }

  static Future<void> _saveUnparsedFinancialSms(
    Database db,
    String sender,
    String body,
    int receivedAt,
    String? inboxId,
  ) async {
    final fingerprint = _smsFingerprint(sender, body, receivedAt);
    await db.insert(
      'sms_messages',
      {
        'sender_address': sender,
        'sender_name': null,
        'body': body,
        'received_at': receivedAt,
        'inbox_message_id': inboxId,
        'sms_fingerprint': fingerprint,
        'is_financial': 1,
        'processing_status': 'REVIEW_REQUIRED',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static bool _looksFinancial(String body) => RegExp(
    r'\b(debited|credited|withdrawn|deposited|spent|received|transferred|transfer|purchase|paid|payment|refund|reversed|cashback)\b',
    caseSensitive: false,
  ).hasMatch(body);

  static String _smsFingerprint(String sender, String body, int date) {
    final normalized = '${sender.toLowerCase()}|${date ~/ 60000}|${body.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()}';
    // Stable FNV-1a hash: unlike String.hashCode, this remains consistent
    // across app launches so inbox scans and receiver-queue imports deduplicate.
    var hash = 0x811c9dc5;
    for (final unit in normalized.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 'sms-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  static bool _isOtp(String body) => RegExp(r'\b(otp|one[- ]time password|verification code)\b', caseSensitive: false).hasMatch(body);

  static String? _extractAccountNear(String body, String cuePattern) {
    final cue = RegExp('\\b(?:$cuePattern)\\b.{0,55}?(?:A/c|account|acct)?\\s*(?:no\\.?\\s*)?(?:XX|X{2,}|\\*{2,})?\\s*([0-9]{3,6})', caseSensitive: false).firstMatch(body);
    return cue?.group(1);
  }

  static String? _bankName(String text) {
    final s = text.toLowerCase();
    const banks = <String, List<String>>{
      'HDFC Bank': ['hdfc', 'hdfcbk', 'hdfcbank'],
      'State Bank of India': ['sbi', 'sbin', 'state bank of india'],
      'ICICI Bank': ['icici', 'icicib'],
      'Axis Bank': ['axis', 'axisbk'],
      'Kotak Mahindra Bank': ['kotak', 'kotakb'],
      'IDFC FIRST Bank': ['idfc', 'idfcbank'],
      'IndusInd Bank': ['indusind'],
      'Yes Bank': ['yesbank', 'yesb'],
      'Bank of Baroda': ['bob', 'bank of baroda'],
      'Canara Bank': ['canara'],
      'Union Bank of India': ['union bank'],
      'Punjab National Bank': ['pnb', 'punjab national'],
      'Federal Bank': ['federal'],
      'AU Small Finance Bank': ['aubank', 'au small finance'],
      'Paytm Payments Bank': ['paytm'],
    };
    for (final entry in banks.entries) {
      if (entry.value.any(s.contains)) return entry.key;
    }
    return null;
  }

  static String _paymentMethod(String text) {
    if (text.contains('upi')) return 'UPI';
    if (text.contains('imps')) return 'IMPS';
    if (text.contains('neft')) return 'NEFT';
    if (text.contains('rtgs')) return 'RTGS';
    if (text.contains('nach') || text.contains('ecs')) return 'NACH';
    if (text.contains('atm')) return 'ATM';
    if (text.contains('pos') || text.contains('debit card') || text.contains('credit card')) return 'CARD';
    if (text.contains('cheque') || text.contains('check')) return 'CHEQUE';
    return 'BANK';
  }

  static String _counterpartyName(String body, String? upi) {
    // A UPI ID is a stable identifier. Do not guess a person's name from
    // free-form narration; person resolution is handled through explicit mappings.
    return upi ?? '';
  }

  static String _category(String text) {
    final s = text.toLowerCase();
    if (RegExp(r'swiggy|zomato|restaurant|food').hasMatch(s)) return 'Food';
    if (RegExp(r'grocery|bigbasket|blinkit|zepto').hasMatch(s)) return 'Groceries';
    if (RegExp(r'amazon|flipkart|myntra|shopping').hasMatch(s)) return 'Shopping';
    if (RegExp(r'uber|ola|irctc|flight|fuel|petrol').hasMatch(s)) return 'Travel';
    if (RegExp(r'electricity|water|bill|recharge').hasMatch(s)) return 'Bills';
    if (RegExp(r'salary|payroll').hasMatch(s)) return 'Salary';
    if (RegExp(r'transfer|imps|neft|rtgs').hasMatch(s)) return 'Transfer';
    return 'Other';
  }

  static String _defaultDescription(ParsedBankSms sms) {
    if (sms.direction == 'INCOMING') return 'Money received';
    if (sms.direction == 'TRANSFER') return sms.category;
    return 'Bank transaction';
  }
}

class ParsedBankSms {
  ParsedBankSms({
    required this.body,
    required this.sender,
    required this.date,
    required this.amount,
    required this.direction,
    required this.legacyType,
    required this.category,
    required this.bankName,
    required this.ownAccountSuffix,
    required this.destinationAccountSuffix,
    required this.upiId,
    required this.reference,
    required this.paymentMethod,
    required this.merchant,
    required this.accountDisplay,
    required this.fingerprint,
    required this.isCardBill,
    required this.isCardSideConfirmation,
    required this.isTransaction,
  });

  factory ParsedBankSms.unclassified(String body, String sender, int date, double amount, bool cardSide) => ParsedBankSms(
    body: body, sender: sender, date: date, amount: amount,
    direction: 'UNKNOWN', legacyType: 'TRANSFER', category: 'Review',
    bankName: null, ownAccountSuffix: null, destinationAccountSuffix: null,
    upiId: null, reference: null, paymentMethod: 'BANK', merchant: '',
    accountDisplay: 'Bank account', fingerprint: 'review-${date ~/ 60000}-${amount.toStringAsFixed(2)}',
    isCardBill: false, isCardSideConfirmation: cardSide, isTransaction: false,
  );

  final String body;
  final String sender;
  final int date;
  final double amount;
  final String direction;
  final String legacyType;
  final String category;
  final String? bankName;
  final String? ownAccountSuffix;
  final String? destinationAccountSuffix;
  final String? upiId;
  final String? reference;
  final String paymentMethod;
  final String merchant;
  final String accountDisplay;
  final String fingerprint;
  final bool isCardBill;
  final bool isCardSideConfirmation;
  final bool isTransaction;
}
