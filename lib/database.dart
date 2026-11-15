import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// FinLedger local database.
///
/// Version 2 introduces the canonical financial-ledger schema while retaining
/// the original `transactions` and `sms_queue` tables for backward compatibility.
/// No existing rows are deleted during migration.
class FinDatabase {
  FinDatabase._();

  static final instance = FinDatabase._();
  static const int schemaVersion = 3;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'finledger.db');
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, version) async {
        await _createLegacyTables(db);
        await _createLedgerTables(db);
        await _createIntelligenceTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createLegacyTables(db);
          await _createLedgerTables(db);
          await _migrateLegacyTransactions(db);
        }
        if (oldVersion < 3) {
          await _createIntelligenceTables(db);
        }
      },
    );
  }

  Future<void> _createLegacyTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount REAL NOT NULL,
        type TEXT NOT NULL,
        category TEXT,
        merchant TEXT,
        description TEXT,
        date INTEGER NOT NULL,
        mode TEXT,
        account TEXT,
        fingerprint TEXT UNIQUE,
        source TEXT
      )
    ''');

    // Android's BroadcastReceiver writes here directly. Keep this table and
    // its column names stable until the native receiver is migrated separately.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sms_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT,
        body TEXT,
        received_at INTEGER
      )
    ''');
  }

  Future<void> _createLedgerTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sms_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender_address TEXT NOT NULL,
        sender_name TEXT,
        body TEXT NOT NULL,
        received_at INTEGER NOT NULL,
        inbox_message_id TEXT,
        sms_fingerprint TEXT NOT NULL UNIQUE,
        is_financial INTEGER NOT NULL DEFAULT 1,
        processing_status TEXT NOT NULL DEFAULT 'PENDING',
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS bank_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bank_name TEXT,
        account_suffix TEXT,
        account_type TEXT NOT NULL DEFAULT 'UNKNOWN',
        display_name TEXT,
        currency TEXT NOT NULL DEFAULT 'INR',
        is_own_account INTEGER NOT NULL DEFAULT 1,
        opening_balance_minor INTEGER,
        opening_balance_date INTEGER,
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(bank_name, account_suffix, account_type)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS parties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        display_name TEXT NOT NULL,
        party_type TEXT NOT NULL DEFAULT 'PERSON',
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS party_identifiers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        party_id INTEGER NOT NULL,
        identifier_type TEXT NOT NULL,
        identifier_value TEXT NOT NULL,
        normalized_value TEXT NOT NULL,
        is_verified INTEGER NOT NULL DEFAULT 0,
        source TEXT NOT NULL DEFAULT 'MANUAL',
        created_at INTEGER NOT NULL,
        FOREIGN KEY(party_id) REFERENCES parties(id) ON DELETE CASCADE,
        UNIQUE(identifier_type, normalized_value)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount_minor INTEGER NOT NULL,
        currency TEXT NOT NULL DEFAULT 'INR',
        direction TEXT NOT NULL DEFAULT 'UNKNOWN',
        payment_method TEXT NOT NULL DEFAULT 'UNKNOWN',
        transaction_date INTEGER NOT NULL,
        description TEXT,
        narration TEXT,
        reference_number TEXT,
        category TEXT,
        status TEXT NOT NULL DEFAULT 'POSTED',
        source TEXT NOT NULL DEFAULT 'SMS',
        fingerprint TEXT UNIQUE,
        legacy_transaction_id INTEGER UNIQUE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_sms_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        sms_message_id INTEGER NOT NULL,
        message_role TEXT NOT NULL DEFAULT 'SUPPORTING',
        linked_at INTEGER NOT NULL,
        FOREIGN KEY(transaction_id) REFERENCES financial_transactions(id) ON DELETE CASCADE,
        FOREIGN KEY(sms_message_id) REFERENCES sms_messages(id) ON DELETE CASCADE,
        UNIQUE(transaction_id, sms_message_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_legs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        account_id INTEGER,
        party_id INTEGER,
        leg_role TEXT NOT NULL,
        direction TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        notes TEXT,
        FOREIGN KEY(transaction_id) REFERENCES financial_transactions(id) ON DELETE CASCADE,
        FOREIGN KEY(account_id) REFERENCES bank_accounts(id) ON DELETE SET NULL,
        FOREIGN KEY(party_id) REFERENCES parties(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS party_relationships (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        party_id INTEGER NOT NULL,
        related_party_id INTEGER,
        relationship_type TEXT NOT NULL,
        amount_minor INTEGER,
        currency TEXT NOT NULL DEFAULT 'INR',
        due_date INTEGER,
        status TEXT NOT NULL DEFAULT 'OPEN',
        notes TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(party_id) REFERENCES parties(id) ON DELETE CASCADE,
        FOREIGN KEY(related_party_id) REFERENCES parties(id) ON DELETE SET NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sms_messages_received_at ON sms_messages(received_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sms_messages_processing_status ON sms_messages(processing_status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_financial_transactions_date ON financial_transactions(transaction_date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_financial_transactions_reference ON financial_transactions(reference_number)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transaction_legs_account ON transaction_legs(account_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transaction_legs_party ON transaction_legs(party_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_party_identifiers_normalized ON party_identifiers(normalized_value)',
    );
  }

  Future<void> _createIntelligenceTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_match_candidates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        candidate_transaction_id INTEGER NOT NULL,
        match_type TEXT NOT NULL,
        confidence TEXT NOT NULL DEFAULT 'LOW',
        reason TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'NEEDS_REVIEW',
        created_at INTEGER NOT NULL,
        reviewed_at INTEGER,
        UNIQUE(transaction_id, candidate_transaction_id),
        FOREIGN KEY(transaction_id) REFERENCES financial_transactions(id) ON DELETE CASCADE,
        FOREIGN KEY(candidate_transaction_id) REFERENCES financial_transactions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_match_candidates_status ON transaction_match_candidates(status)');
  }

  /// Copies old app transactions into the new canonical table.
  /// The old table is deliberately retained so the currently installed UI
  /// continues to work while later phases migrate screens and repositories.
  Future<void> _migrateLegacyTransactions(DatabaseExecutor db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final oldRows = await db.query('transactions');

    for (final row in oldRows) {
      final oldId = row['id'] as int?;
      if (oldId == null) continue;

      final amount = (row['amount'] as num?)?.toDouble() ?? 0;
      final type = (row['type'] ?? 'UNKNOWN').toString().toUpperCase();
      final direction = switch (type) {
        'CREDIT' => 'INCOMING',
        'DEBIT' => 'OUTGOING',
        'TRANSFER' => 'TRANSFER',
        _ => 'UNKNOWN',
      };

      final date = (row['date'] as num?)?.toInt() ?? now;
      final category = row['category']?.toString();
      final description = (row['merchant']?.toString().trim().isNotEmpty ?? false)
          ? row['merchant'].toString()
          : row['description']?.toString();

      await db.insert(
        'financial_transactions',
        {
          'amount_minor': (amount * 100).round(),
          'currency': 'INR',
          'direction': direction,
          'payment_method': row['mode']?.toString() ?? 'UNKNOWN',
          'transaction_date': date,
          'description': description,
          'narration': row['description']?.toString(),
          'reference_number': null,
          'category': category,
          'status': 'POSTED',
          'source': row['source']?.toString() ?? 'LEGACY',
          'fingerprint': row['fingerprint']?.toString(),
          'legacy_transaction_id': oldId,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy API. Keep these methods until the UI and SMS importer are migrated.
  // ---------------------------------------------------------------------------

  Future<int> insert(Map<String, Object?> row) async {
    try {
      return await (await database).insert(
        'transactions',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {
      return 0;
    }
  }

  Future<int> upsertByFingerprint(Map<String, Object?> row) async {
    try {
      final db = await database;
      final fingerprint = row['fingerprint'];
      final existing = await db.query(
        'transactions',
        columns: ['id'],
        where: 'fingerprint = ?',
        whereArgs: [fingerprint],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return await db.update(
          'transactions',
          row,
          where: 'fingerprint = ?',
          whereArgs: [fingerprint],
        );
      }
      return await db.insert(
        'transactions',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (_) {
      return 0;
    }
  }

  Future<List<Map<String, Object?>>> transactions(DateTime month) async {
    final start = DateTime(month.year, month.month).millisecondsSinceEpoch;
    final end = DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
    return (await database).query(
      'transactions',
      where: 'date >= ? AND date < ?',
      whereArgs: [start, end],
      orderBy: 'date DESC',
    );
  }

  // ---------------------------------------------------------------------------
  // New ledger foundation API.
  // ---------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> financialTransactions(
    DateTime month,
  ) async {
    final start = DateTime(month.year, month.month).millisecondsSinceEpoch;
    final end = DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
    return (await database).query(
      'financial_transactions',
      where: 'transaction_date >= ? AND transaction_date < ?',
      whereArgs: [start, end],
      orderBy: 'transaction_date DESC',
    );
  }

  Future<int> saveSmsMessage({
    required String senderAddress,
    String? senderName,
    required String body,
    required int receivedAt,
    required String smsFingerprint,
    String? inboxMessageId,
  }) async {
    final db = await database;
    return db.insert(
      'sms_messages',
      {
        'sender_address': senderAddress,
        'sender_name': senderName,
        'body': body,
        'received_at': receivedAt,
        'inbox_message_id': inboxMessageId,
        'sms_fingerprint': smsFingerprint,
        'is_financial': 1,
        'processing_status': 'PENDING',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> createParty({
    required String displayName,
    String partyType = 'PERSON',
    String? notes,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (await database).insert('parties', {
      'display_name': displayName.trim(),
      'party_type': partyType,
      'notes': notes,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int> addPartyIdentifier({
    required int partyId,
    required String identifierType,
    required String identifierValue,
    required String normalizedValue,
    bool verified = false,
    String source = 'MANUAL',
  }) async {
    return (await database).insert(
      'party_identifiers',
      {
        'party_id': partyId,
        'identifier_type': identifierType,
        'identifier_value': identifierValue,
        'normalized_value': normalizedValue,
        'is_verified': verified ? 1 : 0,
        'source': source,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> createBankAccount({
    required String bankName,
    required String accountSuffix,
    String accountType = 'SAVINGS',
    String? displayName,
    bool isOwnAccount = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (await database).insert(
      'bank_accounts',
      {
        'bank_name': bankName,
        'account_suffix': accountSuffix,
        'account_type': accountType,
        'display_name': displayName,
        'is_own_account': isOwnAccount ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, Object?>>> allParties() async {
    return (await database).query('parties', orderBy: 'display_name COLLATE NOCASE');
  }

  Future<List<Map<String, Object?>>> allBankAccounts() async {
    return (await database).query('bank_accounts', orderBy: 'bank_name, account_suffix');
  }

  /// Read-only counts useful for the migration verification screen/log.
  Future<Map<String, int>> migrationCounts() async {
    final db = await database;
    Future<int> count(String table) async {
      final result = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (result.first['c'] as int?) ?? 0;
    }

    return {
      'legacy_transactions': await count('transactions'),
      'financial_transactions': await count('financial_transactions'),
      'sms_messages': await count('sms_messages'),
      'bank_accounts': await count('bank_accounts'),
      'parties': await count('parties'),
    };
  }
}
