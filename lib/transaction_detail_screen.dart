// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const _detailInk = Color(0xFF172B27);
const _detailGreen = Color(0xFF16745A);
const _detailMuted = Color(0xFF75827E);

class TransactionDetailScreen extends StatelessWidget {
  final Map<String, Object?> transaction;
  const TransactionDetailScreen({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
    final amount = (transaction['amount'] as num?)?.toDouble() ?? 0;
    final type = (transaction['type'] ?? 'UNKNOWN').toString().toUpperCase();
    final kind = (transaction['transaction_kind'] ?? '').toString().toUpperCase();
    final direction = (transaction['financial_direction'] ?? '').toString().toUpperCase();
    final incoming = direction == 'INCOMING' || type == 'CREDIT';
    final cardEvent = kind.startsWith('CARD_');
    final date = (transaction['date'] as num?)?.toInt();
    final dateText = date == null ? 'Date unavailable' :
      DateFormat('EEEE, dd MMMM yyyy · hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(date));
    final category = (transaction['category'] ?? '').toString();
    final account = (transaction['account'] ?? '').toString();
    final description = (transaction['description'] ?? '').toString();
    final merchant = (transaction['merchant'] ?? '').toString();
    final heading = cardEvent ? (category.isEmpty ? 'Credit card activity' : category)
      : incoming ? 'Money received' : type == 'TRANSFER' ? 'Account transfer' : 'Money sent';

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F5),
      appBar: AppBar(
        title: const Text('Transaction details', style: TextStyle(color: _detailInk, fontWeight: FontWeight.w800)),
        backgroundColor: const Color(0xFFF4F7F5),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFF123F34), borderRadius: BorderRadius.circular(22),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 38, height: 38, decoration: BoxDecoration(color: Colors.white.withValues(alpha:.13), borderRadius: BorderRadius.circular(12)),
                  child: Icon(cardEvent ? Icons.credit_card_rounded : incoming ? Icons.south_west_rounded : Icons.north_east_rounded, color: Colors.white)),
                const SizedBox(width: 10),
                Expanded(child: Text(heading.toUpperCase(), style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7))),
              ]),
              const SizedBox(height: 22),
              Text(money.format(amount), style: const TextStyle(color: Colors.white, fontSize: 31, fontWeight: FontWeight.w800)),
              const SizedBox(height: 7),
              Text(dateText, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 18),
          const Padding(padding: EdgeInsets.only(left: 3, bottom: 9), child: Text('TRANSACTION INFORMATION',
            style: TextStyle(color: _detailMuted, fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800))),
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
            child: Column(children: [
              _info('Sender / recipient', merchant.isEmpty ? 'Not identified in SMS' : merchant, Icons.person_outline_rounded),
              _separator(),
              _info('Bank / source account', account.isEmpty ? 'Not identified in SMS' : account, Icons.account_balance_outlined),
              _separator(),
              _info('Transfer method', transaction['mode'] ?? 'Not specified', Icons.swap_horiz_rounded),
              _separator(),
              _info('Direction', cardEvent ? 'Credit card activity (not bank income)' :
                incoming ? 'Money received' : direction == 'INTERNAL' ? 'Internal transfer' : 'Money sent',
                Icons.compare_arrows_rounded),
              if (category.isNotEmpty) ...[
                _separator(),
                _info('Category', category, Icons.label_outline_rounded),
              ],
              if ((transaction['fingerprint'] ?? '').toString().isNotEmpty) ...[
                _separator(),
                _info('Reference / transaction ID', transaction['fingerprint'], Icons.tag_rounded),
              ],
            ]),
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Padding(padding: EdgeInsets.only(left: 3, bottom: 9), child: Text('ORIGINAL SMS',
              style: TextStyle(color: _detailMuted, fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800))),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: SelectableText(description, style: const TextStyle(color: _detailInk, fontSize: 13, height: 1.55)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _separator() => const Divider(height: 1, indent: 54, endIndent: 14, color: Color(0xFFEEF1EF));

  Widget _info(String label, Object? value, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 19, color: _detailMuted),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _detailMuted, fontSize: 11)),
        const SizedBox(height: 4),
        SelectableText(value.toString(), style: const TextStyle(color: _detailInk, fontSize: 13, fontWeight: FontWeight.w600)),
      ])),
    ]),
  );
}
