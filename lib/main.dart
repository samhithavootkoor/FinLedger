// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'database.dart';
import 'sms_importer.dart';
import 'transaction_detail_screen.dart';

const _ink = Color(0xFF172B27);
const _muted = Color(0xFF75827E);
const _green = Color(0xFF16745A);
const _canvas = Color(0xFFF4F7F5);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FinDatabase.instance.database;
  runApp(const FinLedgerApp());
}

class FinLedgerApp extends StatelessWidget {
  const FinLedgerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FinLedger',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.light),
      scaffoldBackgroundColor: _canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: _canvas, foregroundColor: _ink, elevation: 0,
        centerTitle: false, titleTextStyle: TextStyle(color: _ink, fontSize: 23, fontWeight: FontWeight.w800),
      ),
      cardTheme: CardThemeData(
        color: Colors.white, elevation: 0, margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _green, width: 1.2)),
      ),
    ),
    home: const TransactionsScreen(),
  );
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
  List<Map<String, Object?>> _all = [];
  bool _loading = true;
  bool _importing = false;
  String _bank = 'All banks';
  String _method = 'All types';
  String _direction = 'All';
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _search.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      await SmsImporter.importPending();
      final rows = await FinDatabase.instance.allTransactions();
      if (mounted) setState(() { _all = rows; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final permission = await Permission.sms.request();
      if (!permission.isGranted) {
        _notice('Allow SMS access to import bank messages.');
        return;
      }
      final count = await SmsImporter.importInbox();
      await _load();
      _notice(count == 0 ? 'You’re up to date. No new transactions found.' : '$count new transaction(s) imported.');
    } catch (e) {
      _notice('Import failed: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _notice(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message), behavior: SnackBarBehavior.floating,
    ));
  }

  String _bankFrom(Map<String, Object?> row) {
    final account = (row['account'] ?? '').toString();
    final separator = account.indexOf(' ••••');
    if (separator > 0) return account.substring(0, separator);
    return account.isEmpty ? '' : account.split(' ').first;
  }

  List<String> get _banks {
    final values = _all.map(_bankFrom).where((v) => v.isNotEmpty).toSet().toList()..sort();
    return ['All banks', ...values];
  }

  List<String> get _methods {
    final values = _all.map((r) {
      final kind = (r['transaction_kind'] ?? '').toString().toUpperCase();
      if (kind.startsWith('CARD_')) return 'Credit card';
      final mode = (r['mode'] ?? '').toString().trim();
      return mode.isEmpty ? 'Other' : mode.toUpperCase();
    }).toSet().toList()..sort();
    return ['All types', ...values];
  }

  List<Map<String, Object?>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _all.where((r) {
      final bank = _bankFrom(r);
      final kind = (r['transaction_kind'] ?? '').toString().toUpperCase();
      final method = kind.startsWith('CARD_') ? 'Credit card' :
          ((r['mode'] ?? '').toString().trim().isEmpty ? 'Other' : (r['mode'] ?? '').toString().toUpperCase());
      final direction = (r['financial_direction'] ?? '').toString().toUpperCase();
      final type = (r['type'] ?? '').toString().toUpperCase();
      final rawDate = r['date'];
      final date = DateTime.fromMillisecondsSinceEpoch(rawDate is num ? rawDate.toInt() : 0);
      if (_bank != 'All banks' && bank != _bank) return false;
      if (_method != 'All types' && method != _method) return false;
      if (_direction == 'Received' && direction != 'INCOMING' && type != 'CREDIT') return false;
      if (_direction == 'Sent' && direction != 'OUTGOING' && type != 'DEBIT') return false;
      if (_from != null && date.isBefore(DateTime(_from!.year, _from!.month, _from!.day))) return false;
      if (_to != null && date.isAfter(DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59))) return false;
      if (q.isNotEmpty) {
        final haystack = [r['merchant'], r['account'], r['description'], r['category'], r['mode'], r['fingerprint']]
          .join(' ').toLowerCase();
        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  double _totalWhere(bool Function(Map<String, Object?>) test) =>
      _all.where(test).fold<double>(0, (sum, r) => sum + ((r['amount'] as num?)?.toDouble() ?? 0));

  Future<void> _pickDate(bool start) async {
    final selected = await showDatePicker(
      context: context, initialDate: (start ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (selected != null) setState(() { if (start) { _from = selected; } else { _to = selected; } });
  }

  Future<void> _showFilters() async {
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      backgroundColor: _canvas,
      builder: (sheetContext) => StatefulBuilder(builder: (context, setSheet) {
        Widget select(String title, String value, List<String> values, ValueChanged<String> update) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: _ink)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: values.map((v) => ChoiceChip(
              label: Text(v), selected: value == v,
              onSelected: (_) { setSheet(() => update(v)); setState(() {}); },
            )).toList()),
            const SizedBox(height: 18),
          ]);
        }
        return SafeArea(child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Filter transactions', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 20),
            select('Bank', _bank, _banks, (v) => _bank = v),
            select('Transaction type', _method, _methods, (v) => _method = v),
            select('Direction', _direction, const ['All', 'Received', 'Sent'], (v) => _direction = v),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () async { await _pickDate(true); setSheet(() {}); },
                icon: const Icon(Icons.calendar_month), label: Text(_from == null ? 'Start date' : DateFormat('dd MMM yyyy').format(_from!)))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () async { await _pickDate(false); setSheet(() {}); },
                icon: const Icon(Icons.event), label: Text(_to == null ? 'End date' : DateFormat('dd MMM yyyy').format(_to!)))),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(onPressed: () { setSheet(() { _bank='All banks'; _method='All types'; _direction='All'; _from=null; _to=null; }); setState(() {}); },
                child: const Text('Reset')),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Show results')),
            ]),
          ]),
        ));
      }),
    );
  }

  bool get _hasFilters => _bank != 'All banks' || _method != 'All types' ||
      _direction != 'All' || _from != null || _to != null;

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final incoming = _totalWhere((r) => (r['financial_direction'] ?? '').toString().toUpperCase() == 'INCOMING' ||
        (r['type'] ?? '').toString().toUpperCase() == 'CREDIT');
    final outgoing = _totalWhere((r) => (r['financial_direction'] ?? '').toString().toUpperCase() == 'OUTGOING' ||
        (r['type'] ?? '').toString().toUpperCase() == 'DEBIT');
    return Scaffold(
      appBar: AppBar(
        title: const Text('FinLedger'),
        actions: [
          IconButton(
            tooltip: 'Import bank SMS', onPressed: _importing ? null : _import,
            icon: _importing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) :
        RefreshIndicator(onRefresh: _load, child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 110),
          children: [
            _summary(incoming, outgoing),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: 'Search name, bank, account or ref',
                  prefixIcon: const Icon(Icons.search_rounded, color: _muted),
                  suffixIcon: _search.text.isEmpty ? null : IconButton(onPressed: _search.clear, icon: const Icon(Icons.close)),
                ),
              )),
              const SizedBox(width: 9),
              Material(
                color: _hasFilters ? _green : Colors.white,
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15), onTap: _showFilters,
                  child: Padding(padding: const EdgeInsets.all(15), child: Icon(Icons.tune_rounded, color: _hasFilters ? Colors.white : _ink)),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              _quickChip('All', _direction == 'All', () => setState(() => _direction='All')),
              const SizedBox(width: 8),
              _quickChip('Received', _direction == 'Received', () => setState(() => _direction='Received')),
              const SizedBox(width: 8),
              _quickChip('Sent', _direction == 'Sent', () => setState(() => _direction='Sent')),
              const SizedBox(width: 8),
              _quickChip('Credit card', _method == 'Credit card', () => setState(() => _method = _method == 'Credit card' ? 'All types' : 'Credit card')),
            ])),
            const SizedBox(height: 22),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Expanded(child: Text('Transactions', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink))),
              Text('${rows.length} records', style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            if (rows.isEmpty) _emptyState()
            else ..._groupedRows(rows),
          ],
        )),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        backgroundColor: _green, foregroundColor: Colors.white,
        icon: _importing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.sms_rounded),
        label: Text(_importing ? 'Importing' : 'Import SMS'),
      ),
    );
  }

  Widget _summary(double incoming, double outgoing) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Color(0xFF123F34), Color(0xFF19745B)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.white.withValues(alpha:.14), borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 19)),
        const SizedBox(width: 10),
        const Text('YOUR TRANSACTION OVERVIEW', style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('${_all.length} SMS', style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
      const SizedBox(height: 22),
      const Text('Money received', style: TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 4),
      Text(_money.format(incoming), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: _summaryMini('Money sent', _money.format(outgoing), Icons.arrow_upward_rounded)),
        Container(width: 1, height: 34, color: Colors.white24),
        Expanded(child: _summaryMini('All transactions', '${_all.length}', Icons.receipt_long_rounded)),
      ]),
    ]),
  );

  Widget _summaryMini(String label, String value, IconData icon) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Row(children: [
      Icon(icon, color: Colors.white70, size: 17), const SizedBox(width: 7),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
      ])),
    ]),
  );

  Widget _quickChip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
    label: Text(label), selected: selected, onSelected: (_) => onTap(),
    showCheckmark: false, labelStyle: TextStyle(fontWeight: FontWeight.w600, color: selected ? Colors.white : _ink),
    backgroundColor: Colors.white, selectedColor: _green,
    side: BorderSide(color: selected ? _green : const Color(0xFFE5EBE7)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
  );

  List<Widget> _groupedRows(List<Map<String, Object?>> rows) {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final raw = row['date'];
      final date = DateTime.fromMillisecondsSinceEpoch(raw is num ? raw.toInt() : 0);
      final key = DateFormat('yyyy-MM-dd').format(date);
      grouped.putIfAbsent(key, () => []).add(row);
    }
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      final date = DateTime.parse(entry.key);
      final label = DateUtils.isSameDay(date, DateTime.now()) ? 'TODAY' :
        DateUtils.isSameDay(date, DateTime.now().subtract(const Duration(days:1))) ? 'YESTERDAY' :
        DateFormat('EEEE, dd MMM yyyy').format(date).toUpperCase();
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 2, 9),
        child: Row(children: [
          Text(label, style: const TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w800, letterSpacing: .8)),
          const SizedBox(width: 8), Expanded(child: Divider(color: Colors.grey.shade300)),
        ]),
      ));
      widgets.addAll(entry.value.map(_transactionTile));
    }
    return widgets;
  }

  Widget _transactionTile(Map<String, Object?> row) {
    final type = (row['type'] ?? 'UNKNOWN').toString().toUpperCase();
    final kind = (row['transaction_kind'] ?? '').toString().toUpperCase();
    final direction = (row['financial_direction'] ?? '').toString().toUpperCase();
    final incoming = direction == 'INCOMING' || type == 'CREDIT';
    final card = kind.startsWith('CARD_');
    final cardNonCash = kind == 'CARD_PURCHASE' || kind == 'CARD_REFUND' || kind == 'CARD_PAYMENT_CONFIRMATION';
    final transfer = type == 'TRANSFER' || direction == 'INTERNAL';
    final color = card ? const Color(0xFF6755A5) : incoming ? _green : transfer ? const Color(0xFF65747E) : const Color(0xFFC15D36);
    final amount = (row['amount'] as num?)?.toDouble() ?? 0;
    final rawDate = row['date'];
    final date = DateTime.fromMillisecondsSinceEpoch(rawDate is num ? rawDate.toInt() : 0);
    final person = (row['merchant'] ?? '').toString().trim();
    final account = (row['account'] ?? '').toString();
    final method = (row['mode'] ?? '').toString();
    final category = (row['category'] ?? '').toString();
    final heading = person.isNotEmpty ? person : card
      ? (category.isNotEmpty ? category : 'Credit card transaction')
      : incoming ? 'Money received' : transfer ? 'Account transfer' : 'Money sent';
    final subtitle = [
      _bankFrom(row).isEmpty ? 'Bank message' : _bankFrom(row),
      method.isEmpty ? (card ? 'Credit card' : 'Bank transfer') : method,
      DateFormat('hh:mm a').format(date),
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white, borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TransactionDetailScreen(transaction: row))),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14), child: Row(children: [
            Container(width: 43, height: 43, decoration: BoxDecoration(color: color.withValues(alpha:.10), borderRadius: BorderRadius.circular(14)),
              child: Icon(card ? Icons.credit_card_rounded : incoming ? Icons.south_west_rounded : transfer ? Icons.swap_horiz_rounded : Icons.north_east_rounded, color: color, size: 21)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ink, fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 4),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11)),
              if (account.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(account, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ])),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${cardNonCash ? '' : incoming ? '+' : transfer ? '' : '−'}${_money.format(amount)}',
                style: TextStyle(color: card ? color : incoming ? _green : _ink, fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              if (card) _tinyTag('CARD', color)
              else _tinyTag(incoming ? 'RECEIVED' : transfer ? 'TRANSFER' : 'SENT', color),
            ]),
          ])),
        ),
      ),
    );
  }

  Widget _tinyTag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha:.09), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(color: color, fontSize: 8, letterSpacing: .4, fontWeight: FontWeight.w800)),
  );

  Widget _emptyState() => Container(
    padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 20),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
    child: Column(children: [
      Container(width: 62, height: 62, decoration: const BoxDecoration(color: Color(0xFFEAF2EE), shape: BoxShape.circle),
        child: const Icon(Icons.receipt_long_outlined, color: _green, size: 29)),
      const SizedBox(height: 14),
      const Text('No transactions found', style: TextStyle(color: _ink, fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: 6),
      const Text('Import your bank SMS or adjust the filters to see your activity.',
        textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 12, height: 1.4)),
    ]),
  );
}
