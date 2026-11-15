import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'database.dart';

class IntelligenceScreen extends StatefulWidget {
  const IntelligenceScreen({super.key});
  @override
  State<IntelligenceScreen> createState() => _IntelligenceScreenState();
}

class _IntelligenceScreenState extends State<IntelligenceScreen> {
  final money = NumberFormat.currency(locale:'en_IN',symbol:'₹',decimalDigits:2);
  List<Map<String,Object?>> candidates=[];
  bool loading=true;

  @override
  void initState(){super.initState();_load();}

  Future<void> _load() async {
    final db=await FinDatabase.instance.database;
    final rows=await db.rawQuery('''
      SELECT c.*, a.amount_minor, a.direction AS direction_a,
        a.transaction_date AS date_a, a.payment_method AS method_a,
        a.description AS description_a, a.reference_number AS reference_a,
        b.direction AS direction_b, b.transaction_date AS date_b,
        b.payment_method AS method_b, b.description AS description_b,
        b.reference_number AS reference_b
      FROM transaction_match_candidates c
      JOIN financial_transactions a ON a.id=c.transaction_id
      JOIN financial_transactions b ON b.id=c.candidate_transaction_id
      WHERE c.status='NEEDS_REVIEW'
      ORDER BY c.created_at DESC LIMIT 100
    ''');
    if(mounted) setState(() { candidates=rows; loading=false; });
  }

  Future<void> _review(Map<String,Object?> row,bool confirm) async {
    final db=await FinDatabase.instance.database;
    final now=DateTime.now().millisecondsSinceEpoch;
    await db.update('transaction_match_candidates',{
      'status':confirm?'CONFIRMED':'REJECTED','reviewed_at':now,
    },where:'id=?',whereArgs:[row['id']]);
    if(confirm){
      await db.update('financial_transactions',{
        'direction':'TRANSFER','updated_at':now,
      },where:'id IN (?,?)',whereArgs:[row['transaction_id'],row['candidate_transaction_id']]);
      final linked=await db.query('financial_transactions',columns:['legacy_transaction_id'],
        where:'id IN (?,?)',whereArgs:[row['transaction_id'],row['candidate_transaction_id']]);
      for(final item in linked){
        final legacyId=item['legacy_transaction_id'];
        if(legacyId!=null){
          await db.update('transactions',{'type':'TRANSFER','category':'Transfer'},
            where:'id=?',whereArgs:[legacyId]);
        }
      }
    }
    await _load();
  }

  String _date(Object? value){
    if(value==null)return 'Date unavailable';
    return DateFormat('dd MMM, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch((value as num).toInt()));
  }

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Transaction intelligence')),
    body:loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(
      onRefresh:_load,
      child:ListView(padding:const EdgeInsets.all(12),children:[
        const Card(child:Padding(padding:EdgeInsets.all(14),child:Text(
          'These are suggestions, not confirmed transfers. Review the amount, direction, date and bank details before accepting. FinLedger never merges transactions solely because their amounts match.',
        ))),
        if(candidates.isEmpty)const Padding(padding:EdgeInsets.all(28),child:Text('No pending match suggestions. Import more bank SMS to discover possible matches.')),
        ...candidates.map((r)=>Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[Expanded(child:Text((r['match_type']??'Possible match').toString(),style:const TextStyle(fontWeight:FontWeight.bold))),Chip(label:Text((r['confidence']??'LOW').toString()))]),
          Text(money.format(((r['amount_minor'] as num?)?.toInt()??0)/100),style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
          const SizedBox(height:6),
          Text('${r['direction_a']} · ${r['method_a']} · ${_date(r['date_a'])}'),
          Text('${r['direction_b']} · ${r['method_b']} · ${_date(r['date_b'])}'),
          if((r['description_a']??'').toString().isNotEmpty)Text('First: ${r['description_a']}'),
          if((r['description_b']??'').toString().isNotEmpty)Text('Second: ${r['description_b']}'),
          const SizedBox(height:5),
          Text((r['reason']??'').toString(),style:const TextStyle(color:Colors.black54,fontSize:12)),
          Row(mainAxisAlignment:MainAxisAlignment.end,children:[
            TextButton(onPressed:()=>_review(r,false),child:const Text('Not a match')),
            FilledButton(onPressed:()=>_review(r,true),child:const Text('Confirm transfer')),
          ]),
        ])))),
      ]),
    ),
  );
}
