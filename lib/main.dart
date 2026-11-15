// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'database.dart';
import 'sms_importer.dart';
import 'transaction_detail_screen.dart';

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
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B55)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF6F8F7),
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
  final _money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
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
    _search.addListener(() => setState(() {}));
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
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final permission = await Permission.sms.request();
      if (!permission.isGranted) {
        _notice('SMS permission is needed to scan bank messages.');
        return;
      }
      final count = await SmsImporter.importInbox();
      await _load();
      _notice(count == 0 ? 'No new bank transactions found.' : 'Imported $count transaction(s).');
    } catch (e) {
      _notice('Could not import SMS: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _notice(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  List<String> get _banks {
    final values = _all.map((r) => _bankFrom(r)).where((v) => v.isNotEmpty).toSet().toList()..sort();
    return ['All banks', ...values];
  }

  List<String> get _methods {
    final values = _all.map((r) => (r['mode'] ?? '').toString().toUpperCase())
      .where((v) => v.isNotEmpty).toSet().toList()..sort();
    return ['All types', ...values];
  }

  String _bankFrom(Map<String, Object?> row) {
    final account = (row['account'] ?? '').toString();
    final separator = account.indexOf(' ••••');
    if (separator > 0) return account.substring(0, separator);
    return account.isEmpty ? '' : account.split(' ').first;
  }

  List<Map<String, Object?>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _all.where((r) {
      final bank = _bankFrom(r);
      final method = (r['mode'] ?? '').toString().toUpperCase();
      final type = (r['type'] ?? '').toString().toUpperCase();
      final date = DateTime.fromMillisecondsSinceEpoch((r['date'] as num).toInt());
      if (_bank != 'All banks' && bank != _bank) return false;
      if (_method != 'All types' && method != _method) return false;
      if (_direction == 'Received' && type != 'CREDIT') return false;
      if (_direction == 'Sent' && type != 'DEBIT') return false;
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

  Future<void> _pickDate(bool start) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (start ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (selected != null) setState(() { if (start) { _from = selected; } else { _to = selected; } });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FinLedger', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Import bank SMS',
            onPressed: _importing ? null : _import,
            icon: _importing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync),
          ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
              children: [
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: 'Search person, account, amount, reference…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty ? null : IconButton(
                      onPressed: _search.clear, icon: const Icon(Icons.close)),
                    filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _dropdown('Bank', _bank, _banks, (v) => setState(() => _bank = v))),
                  const SizedBox(width: 8),
                  Expanded(child: _dropdown('Type', _method, _methods, (v) => setState(() => _method = v))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _dropdown('Direction', _direction, const ['All', 'Received', 'Sent'], (v) => setState(() => _direction = v))),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_from == null ? 'From date' : DateFormat('dd MMM yy').format(_from!)),
                  )),
                  const SizedBox(width: 6),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event, size: 16),
                    label: Text(_to == null ? 'To date' : DateFormat('dd MMM yy').format(_to!)),
                  )),
                ]),
                if (_from != null || _to != null || _bank != 'All banks' || _method != 'All types' || _direction != 'All')
                  Align(alignment: Alignment.centerRight, child: TextButton(
                    onPressed: () => setState(() { _from = null; _to = null; _bank = 'All banks'; _method = 'All types'; _direction = 'All'; }),
                    child: const Text('Clear filters'),
                  )),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Transactions', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                  Text('${rows.length} found', style: const TextStyle(color: Colors.black54)),
                ]),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Column(children: [
                      Icon(Icons.sms_failed_outlined, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('No matching transactions', style: TextStyle(color: Colors.grey)),
                      Text('Import SMS or change your filters.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ]),
                  )
                else
                  ...rows.map(_transactionTile),
              ],
            ),
          ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        icon: const Icon(Icons.sms),
        label: Text(_importing ? 'Importing…' : 'Import SMS'),
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> options, ValueChanged<String> onChanged) {
    final safe = options.contains(value) ? value : options.first;
    return DropdownButtonFormField<String>(
      initialValue: safe,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
      items: options.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }

  Widget _transactionTile(Map<String, Object?> row) {
    final type = (row['type'] ?? 'UNKNOWN').toString().toUpperCase();
    final incoming = type == 'CREDIT';
    final transfer = type == 'TRANSFER';
    final color = incoming ? Colors.green.shade700 : transfer ? Colors.blueGrey : Colors.deepOrange.shade700;
    final amount = (row['amount'] as num?)?.toDouble() ?? 0;
    final date = DateTime.fromMillisecondsSinceEpoch((row['date'] as num).toInt());
    final person = (row['merchant'] ?? '').toString().trim();
    final account = (row['account'] ?? '').toString();
    final method = (row['mode'] ?? 'BANK').toString();
    final heading = person.isNotEmpty ? person : (incoming ? 'Money received' : 'Money sent');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TransactionDetailScreen(transaction: row))),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: .12),
          child: Icon(incoming ? Icons.arrow_downward : Icons.arrow_upward, color: color),
        ),
        title: Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${_bankFrom(row)} · $method · ${DateFormat('dd MMM yyyy, hh:mm a').format(date)}\n$account',
          maxLines: 2, overflow: TextOverflow.ellipsis),
        isThreeLine: true,
        trailing: Text('${incoming ? '+' : transfer ? '↔' : '−'}${_money.format(amount)}',
          style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
      ),
    );
  }
}
