import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'database.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  bool loading = true;
  Map<String, Object?> summary = {};
  List<Map<String, Object?>> categories = [];
  List<Map<String, Object?>> months = [];
  List<Map<String, Object?>> methods = [];
  List<Map<String, Object?>> parties = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final db = await FinDatabase.instance.database;
    final start = DateTime(month.year, month.month).millisecondsSinceEpoch;
    final end = DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
    final s = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN direction='INCOMING' THEN amount_minor ELSE 0 END),0) AS income,
        COALESCE(SUM(CASE WHEN direction='OUTGOING' THEN amount_minor ELSE 0 END),0) AS expense,
        COALESCE(SUM(CASE WHEN direction='TRANSFER' THEN amount_minor ELSE 0 END),0) AS transfers,
        COUNT(*) AS count
      FROM financial_transactions
      WHERE transaction_date >= ? AND transaction_date < ?
        AND status NOT IN ('DELETED','DUPLICATE')
    ''', [start, end]);
    final c = await db.rawQuery('''
      SELECT COALESCE(category,'Uncategorized') AS label,
        SUM(amount_minor) AS total, COUNT(*) AS count
      FROM financial_transactions
      WHERE direction='OUTGOING' AND transaction_date >= ? AND transaction_date < ?
      GROUP BY COALESCE(category,'Uncategorized')
      ORDER BY total DESC
    ''', [start, end]);
    final m = await db.rawQuery('''
      SELECT strftime('%Y-%m', transaction_date/1000, 'unixepoch','localtime') AS period,
        SUM(CASE WHEN direction='INCOMING' THEN amount_minor ELSE 0 END) AS income,
        SUM(CASE WHEN direction='OUTGOING' THEN amount_minor ELSE 0 END) AS expense
      FROM financial_transactions
      WHERE transaction_date >= ? AND transaction_date < ?
      GROUP BY period ORDER BY period
    ''', [DateTime(month.year, month.month-5).millisecondsSinceEpoch, end]);
    final pm = await db.rawQuery('''
      SELECT payment_method AS label, COUNT(*) AS count, SUM(amount_minor) AS total
      FROM financial_transactions
      WHERE transaction_date >= ? AND transaction_date < ?
      GROUP BY payment_method ORDER BY total DESC
    ''', [start, end]);
    final p = await db.rawQuery('''
      SELECT pa.display_name AS name,
        SUM(CASE WHEN tl.direction='OUTGOING' THEN tl.amount_minor ELSE 0 END) AS sent,
        SUM(CASE WHEN tl.direction='INCOMING' THEN tl.amount_minor ELSE 0 END) AS received
      FROM transaction_legs tl JOIN parties pa ON pa.id=tl.party_id
      JOIN financial_transactions ft ON ft.id=tl.transaction_id
      WHERE ft.transaction_date >= ? AND ft.transaction_date < ?
      GROUP BY pa.id ORDER BY (COALESCE(sent,0)+COALESCE(received,0)) DESC LIMIT 8
    ''', [start, end]);
    if (!mounted) return;
    setState(() {
      summary = s.isEmpty ? {} : s.first;
      categories = c;
      months = m;
      methods = pm;
      parties = p;
      loading = false;
    });
  }

  double _rupees(Object? value) => ((value as num?)?.toDouble() ?? 0) / 100;
  Widget _metric(String title, Object? value, Color color) => Expanded(
    child: Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.black54, fontSize: 12)),
        const SizedBox(height: 6),
        Text(money.format(_rupees(value)), style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
      ]),
    )),
  );

  @override
  Widget build(BuildContext context) {
    final income = _rupees(summary['income']);
    final expense = _rupees(summary['expense']);
    final transfers = _rupees(summary['transfers']);
    return Scaffold(
      appBar: AppBar(title: const Text('Financial reports')),
      body: loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(14), children: [
          Row(children: [
            IconButton(onPressed: () { month = DateTime(month.year, month.month-1); _load(); }, icon: const Icon(Icons.chevron_left)),
            Expanded(child: Text(DateFormat('MMMM yyyy').format(month), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
            IconButton(onPressed: () { month = DateTime(month.year, month.month+1); _load(); }, icon: const Icon(Icons.chevron_right)),
          ]),
          Row(children: [
            _metric('Income', summary['income'], Colors.green.shade700),
            _metric('Expenses', summary['expense'], Colors.deepOrange),
          ]),
          Row(children: [
            _metric('Net cash flow', (income-expense)*100, income >= expense ? Colors.green.shade700 : Colors.red),
            _metric('Transfers', summary['transfers'], Colors.blueGrey),
          ]),
          Card(child: ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Transactions in period'),
            trailing: Text('${summary['count'] ?? 0}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          )),
          const SizedBox(height: 12),
          const Text('Spending by category', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          if (categories.isEmpty) const ListTile(title: Text('No outgoing transactions for this month.')),
          ...categories.map((r) {
            final total = _rupees(r['total']);
            final share = expense <= 0 ? 0.0 : (total/expense).clamp(0.0, 1.0).toDouble();
            return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text('${r['label']}')), Text(money.format(total), style: const TextStyle(fontWeight: FontWeight.w700))]),
              const SizedBox(height: 7),
              LinearProgressIndicator(value: share),
              const SizedBox(height: 4),
              Text('${r['count']} transactions · ${(share*100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ])));
          }),
          const SizedBox(height: 12),
          const Text('Monthly cash flow · last 6 months', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          if (months.isEmpty) const ListTile(title: Text('No monthly history available.')),
          ...months.map((r) {
            final inc = _rupees(r['income']);
            final exp = _rupees(r['expense']);
            return Card(child: ListTile(
              title: Text((r['period'] ?? '').toString()),
              subtitle: Text('Income ${money.format(inc)} · Expenses ${money.format(exp)}'),
              trailing: Text(money.format(inc-exp), style: TextStyle(fontWeight: FontWeight.bold, color: inc >= exp ? Colors.green : Colors.red)),
            ));
          }),
          const SizedBox(height: 12),
          const Text('Payment methods', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ...methods.map((r) => Card(child: ListTile(
            title: Text((r['label'] ?? 'UNKNOWN').toString()),
            subtitle: Text('${r['count']} transactions'),
            trailing: Text(money.format(_rupees(r['total']))),
          ))),
          const SizedBox(height: 12),
          const Text('People activity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          if (parties.isEmpty) const ListTile(title: Text('No mapped people activity for this month.')),
          ...parties.map((r) => Card(child: ListTile(
            title: Text((r['name'] ?? '').toString()),
            subtitle: Text('Sent ${money.format(_rupees(r['sent']))} · Received ${money.format(_rupees(r['received']))}'),
          ))),
          const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text(
            'Reports are calculated from imported and manually entered records stored on this device. They are not a bank statement or verified bank balance.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          )),
        ]),
      ),
    );
  }
}
