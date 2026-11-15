// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TransactionDetailScreen extends StatelessWidget {
  final Map<String, Object?> transaction;
  const TransactionDetailScreen({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
    final amount = (transaction['amount'] as num?)?.toDouble() ?? 0;
    final type = (transaction['type'] ?? 'UNKNOWN').toString().toUpperCase();
    final kind = (transaction['transaction_kind'] ?? '').toString().toUpperCase();
    final incoming = (transaction['financial_direction'] ?? '').toString().toUpperCase() == 'INCOMING' || type == 'CREDIT';
    final cardEvent = kind.startsWith('CARD_');
    final date = (transaction['date'] as num?)?.toInt();
    final dateText = date == null ? 'Date unavailable' :
      DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(date));
    final account = (transaction['account'] ?? '').toString();
    final description = (transaction['description'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: const Text('Transaction details')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cardEvent
                ? (transaction['category'] ?? 'CREDIT CARD TRANSACTION').toString().toUpperCase()
                : incoming ? 'MONEY RECEIVED' : type == 'TRANSFER' ? 'TRANSFER' : 'MONEY SENT',
              style: const TextStyle(color: Colors.black54, letterSpacing: 1)),
            const SizedBox(height: 8),
            Text(money.format(amount), style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold,
              color: incoming ? Colors.green.shade700 : Colors.deepOrange.shade700)),
            const SizedBox(height: 8),
            Text(dateText),
          ],
        ))),
        _field('Sender / recipient', transaction['merchant']),
        _field('Bank and source account', account),
        _field('Transfer type', transaction['mode']),
        _field('Direction', incoming ? 'Received' : type == 'TRANSFER' ? 'Transfer' : 'Sent'),
        _field('Transaction category', transaction['category']),
        _field('Reference / fingerprint', transaction['fingerprint']),
        if (description.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 6), child: Text('Original SMS',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: SelectableText(description))),
        ],
      ]),
    );
  }

  Widget _field(String label, Object? value) {
    final text = (value ?? '').toString().trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Card(child: ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
      subtitle: SelectableText(text),
    ));
  }
}
