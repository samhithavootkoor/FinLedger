import 'package:sqflite/sqflite.dart';

/// Conservative matching: only exact bank-reference matches are high confidence.
/// Same-amount/time matches are review suggestions, never auto-merged.
class TransactionIntelligence {
  static Future<void> evaluate({
    required DatabaseExecutor db,
    required int transactionId,
    required int amountMinor,
    required String direction,
    required int date,
    required int? ownAccountId,
    required String? reference,
    required String? counterpartyIdentifier,
  }) async {
    await resolveCounterparty(db: db, transactionId: transactionId, identifier: counterpartyIdentifier);
    if (direction != 'INCOMING' && direction != 'OUTGOING') return;
    final opposite = direction == 'INCOMING' ? 'OUTGOING' : 'INCOMING';
    final window = const Duration(hours: 24).inMilliseconds;
    final candidates = await db.rawQuery('''
      SELECT ft.id,
        (SELECT tl.account_id FROM transaction_legs tl WHERE tl.transaction_id=ft.id AND tl.account_id IS NOT NULL LIMIT 1) AS account_id
      FROM financial_transactions ft
      WHERE ft.id != ? AND ft.amount_minor = ? AND ft.direction = ?
        AND ft.transaction_date BETWEEN ? AND ?
      ORDER BY ABS(ft.transaction_date - ?) ASC LIMIT 10
    ''', [transactionId, amountMinor, opposite, date-window, date+window, date]);
    for (final row in candidates) {
      final otherAccount = (row['account_id'] as num?)?.toInt();
      final strongAccountEvidence = ownAccountId != null && otherAccount != null && ownAccountId != otherAccount;
      await _saveCandidate(db, transactionId, (row['id'] as num).toInt(),
        strongAccountEvidence ? 'POSSIBLE_OWN_ACCOUNT_TRANSFER' : 'SIMILAR_AMOUNT_TIME',
        strongAccountEvidence ? 'MEDIUM' : 'LOW',
        strongAccountEvidence
          ? 'Opposite directions, same amount, within 24 hours, and different linked accounts. Confirm manually.'
          : 'Opposite directions and same amount within 24 hours; not enough evidence to merge automatically.');
    }
  }

  static Future<void> _saveCandidate(DatabaseExecutor db, int a, int b,
      String type, String confidence, String reason) async {
    if (a == b) return;
    final first = a < b ? a : b;
    final second = a < b ? b : a;
    await db.insert('transaction_match_candidates', {
      'transaction_id': first, 'candidate_transaction_id': second,
      'match_type': type, 'confidence': confidence, 'reason': reason,
      'status': 'NEEDS_REVIEW', 'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> resolveCounterparty({
    required DatabaseExecutor db,
    required int transactionId,
    required String? identifier,
  }) async {
    if (identifier == null || identifier.trim().isEmpty) return;
    final normalized = identifier.trim().toLowerCase();
    final matches = await db.query('party_identifiers', columns: ['party_id'],
      where: 'normalized_value = ?', whereArgs: [normalized], limit: 1);
    if (matches.isEmpty) return;
    final partyId = (matches.first['party_id'] as num).toInt();
    await db.update('transaction_legs', {'party_id': partyId},
      where: 'transaction_id = ? AND leg_role = ?', whereArgs: [transactionId, 'COUNTERPARTY']);
  }
}
