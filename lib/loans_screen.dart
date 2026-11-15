import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'database.dart';

class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key});
  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  List<Map<String,Object?>> rows = [];
  List<Map<String,Object?>> people = [];
  bool loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final db = await FinDatabase.instance.database;
    final r = await db.rawQuery('''
      SELECT pr.*, p.display_name,
        COALESCE((SELECT SUM(rp.amount_minor) FROM relationship_payments rp WHERE rp.relationship_id=pr.id),0) AS paid_minor
      FROM party_relationships pr JOIN parties p ON p.id=pr.party_id
      WHERE pr.relationship_type IN ('LENT','BORROWED')
      ORDER BY CASE pr.status WHEN 'OPEN' THEN 0 ELSE 1 END, pr.created_at DESC
    ''');
    final p = await db.query('parties', orderBy: 'display_name COLLATE NOCASE');
    if (!mounted) return;
    setState(() { rows=r; people=p; loading=false; });
  }

  Future<void> _addLoan() async {
    if (people.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add a person in People before recording a loan.')));
      return;
    }
    final amount = TextEditingController();
    final notes = TextEditingController();
    int? partyId = (people.first['id'] as num).toInt();
    String kind = 'LENT';
    final saved = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
      title: const Text('Record loan'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<int>(
          initialValue: partyId,
          decoration: const InputDecoration(labelText: 'Person'),
          items: people.map((p) => DropdownMenuItem<int>(value: (p['id'] as num).toInt(), child: Text(p['display_name'].toString()))).toList(),
          onChanged: (v) => setDialog(() => partyId=v),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: kind,
          decoration: const InputDecoration(labelText: 'Loan direction'),
          items: const [DropdownMenuItem(value:'LENT',child:Text('I lent money')),DropdownMenuItem(value:'BORROWED',child:Text('I borrowed money'))],
          onChanged: (v) => setDialog(() => kind=v ?? 'LENT'),
        ),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal:true), decoration: const InputDecoration(labelText:'Amount (₹)')),
        TextField(controller: notes, decoration: const InputDecoration(labelText:'Notes (optional)')),
      ])),
      actions: [
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Save')),
      ],
    )));
    if (saved == true && partyId != null) {
      final value = double.tryParse(amount.text.replaceAll(',', '').trim());
      if (value == null || value <= 0) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid amount.')));
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        await (await FinDatabase.instance.database).insert('party_relationships', {
          'party_id': partyId, 'relationship_type': kind, 'amount_minor': (value*100).round(),
          'currency':'INR','status':'OPEN','notes':notes.text.trim(),'created_at':now,'updated_at':now,
        });
        await _load();
      }
    }
    amount.dispose(); notes.dispose();
  }

  Future<void> _settle(Map<String,Object?> row) async {
    final amount = TextEditingController();
    final notes = TextEditingController();
    final remaining = (row['amount_minor'] as num).toInt() -
      ((row['paid_minor'] as num?)?.toInt() ?? 0);
    final value = await showDialog<double>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Record settlement · ${row['display_name']}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Outstanding: ${money.format(remaining/100)}'),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal:true), decoration: const InputDecoration(labelText:'Settlement amount (₹)')),
        TextField(controller: notes, decoration: const InputDecoration(labelText:'Notes (optional)')),
      ]),
      actions: [
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,double.tryParse(amount.text.replaceAll(',', '').trim())),child:const Text('Save settlement')),
      ],
    ));
    if (value != null && value > 0 && (value*100).round() <= remaining) {
      final db = await FinDatabase.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.insert('relationship_payments', {
          'relationship_id':row['id'],'amount_minor':(value*100).round(),
          'payment_date':now,'notes':notes.text.trim(),'created_at':now,
        });
        final paidAfter = ((row['paid_minor'] as num?)?.toInt() ?? 0) + (value*100).round();
        await txn.update('party_relationships', {
          'status': paidAfter >= (row['amount_minor'] as num).toInt() ? 'SETTLED' : 'OPEN',
          'updated_at':now,
        }, where:'id=?', whereArgs:[row['id']]);
      });
      await _load();
    } else if (value != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settlement must be greater than zero and no more than the outstanding amount.')));
    }
    amount.dispose(); notes.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = rows.where((r)=>r['status']=='OPEN').toList();
    final lent = open.where((r)=>r['relationship_type']=='LENT').fold<int>(0,(s,r)=>s+(r['amount_minor'] as num).toInt()-(r['paid_minor'] as num).toInt());
    final borrowed = open.where((r)=>r['relationship_type']=='BORROWED').fold<int>(0,(s,r)=>s+(r['amount_minor'] as num).toInt()-(r['paid_minor'] as num).toInt());
    return Scaffold(
      appBar: AppBar(title: const Text('Loans & settlements')),
      floatingActionButton: FloatingActionButton.extended(onPressed:_addLoan,icon:const Icon(Icons.add),label:const Text('Record loan')),
      body: loading ? const Center(child:CircularProgressIndicator()) : RefreshIndicator(
        onRefresh:_load,
        child: ListView(padding:const EdgeInsets.fromLTRB(12,12,12,90),children:[
          Row(children:[
            Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('You lent',style:TextStyle(color:Colors.black54)),Text(money.format(lent/100),style:const TextStyle(fontWeight:FontWeight.bold,color:Colors.green))])))),
            Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('You borrowed',style:TextStyle(color:Colors.black54)),Text(money.format(borrowed/100),style:const TextStyle(fontWeight:FontWeight.bold,color:Colors.deepOrange))])))),
          ]),
          if(rows.isEmpty) const Padding(padding:EdgeInsets.all(28),child:Text('No loans recorded yet. Add a person first, then record money lent or borrowed.')),
          ...rows.map((r){
            final original=(r['amount_minor'] as num).toInt();
            final paid=(r['paid_minor'] as num).toInt();
            final balance=(original-paid).clamp(0,original);
            final isLent=r['relationship_type']=='LENT';
            return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Row(children:[Expanded(child:Text(r['display_name'].toString(),style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16))),Chip(label:Text(isLent?'You lent':'You borrowed'))]),
              Text('Original ${money.format(original/100)} · Settled ${money.format(paid/100)}'),
              const SizedBox(height:5),
              Text('Outstanding ${money.format(balance/100)}',style:TextStyle(fontWeight:FontWeight.bold,color:balance==0?Colors.green:Colors.black87)),
              if((r['notes']??'').toString().isNotEmpty) Text(r['notes'].toString(),style:const TextStyle(color:Colors.black54)),
              if(balance>0) Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>_settle(r),icon:const Icon(Icons.payments_outlined),label:const Text('Record settlement'))),
            ])));
          }),
          const Padding(padding:EdgeInsets.all(12),child:Text('Loan records are manually maintained and do not automatically change bank transaction classifications. Record the actual transfer separately in your ledger.',style:TextStyle(color:Colors.black54,fontSize:12))),
        ]),
      ),
    );
  }
}
