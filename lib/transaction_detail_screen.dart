import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TransactionDetailScreen extends StatelessWidget {
  final Map<String,Object?> transaction;
  const TransactionDetailScreen({super.key,required this.transaction});

  @override
  Widget build(BuildContext context){
    final money=NumberFormat.currency(locale:'en_IN',symbol:'₹',decimalDigits:2);
    final amount=(transaction['amount'] as num?)?.toDouble()??0;
    final type=(transaction['type']??'UNKNOWN').toString();
    final date=(transaction['date'] as num?)?.toInt();
    final dateText=date==null?'Date unavailable':DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(date));
    return Scaffold(
      appBar:AppBar(title:const Text('Transaction details')),
      body:ListView(padding:const EdgeInsets.all(16),children:[
        Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(type,style:const TextStyle(color:Colors.black54)),
          const SizedBox(height:8),
          Text(money.format(amount),style:const TextStyle(fontSize:30,fontWeight:FontWeight.bold)),
          const SizedBox(height:8),
          Text(dateText),
        ]))),
        _field('Description',transaction['merchant']??transaction['category']),
        _field('Category',transaction['category']),
        _field('Payment method',transaction['mode']),
        _field('Bank / account',transaction['account']),
        _field('Source',transaction['source']),
        _field('Fingerprint',transaction['fingerprint']),
        _field('Original SMS / notes',transaction['description']),
        const Padding(padding:EdgeInsets.only(top:12),child:Text(
          'This view shows the details currently stored for this ledger entry. A linked-SMS audit timeline will be added after the importer assigns canonical event IDs to every legacy row.',
          style:TextStyle(color:Colors.black54,fontSize:12),
        )),
      ]),
    );
  }

  Widget _field(String label,Object? value){
    final text=(value??'').toString().trim();
    if(text.isEmpty)return const SizedBox.shrink();
    return Card(child:ListTile(title:Text(label,style:const TextStyle(fontSize:12,color:Colors.black54)),subtitle:Text(text)));
  }
}
