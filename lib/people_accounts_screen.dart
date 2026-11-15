import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'database.dart';

class PeopleAccountsScreen extends StatefulWidget {
  const PeopleAccountsScreen({super.key});
  @override State<PeopleAccountsScreen> createState() => _PeopleAccountsScreenState();
}
class _PeopleAccountsScreenState extends State<PeopleAccountsScreen> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 2, vsync: this);
  List<Map<String,Object?>> people = [], accounts = [], matches = [];
  final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  @override void initState(){super.initState(); _load();}
  @override void dispose(){tabs.dispose();super.dispose();}
  Future<void> _load() async {
    final db = await FinDatabase.instance.database;
    final p = await db.rawQuery('''SELECT p.*, COUNT(DISTINCT tl.transaction_id) AS txn_count,
      COALESCE(SUM(CASE WHEN tl.direction='INCOMING' THEN tl.amount_minor ELSE 0 END),0) AS received_minor,
      COALESCE(SUM(CASE WHEN tl.direction='OUTGOING' THEN tl.amount_minor ELSE 0 END),0) AS sent_minor
      FROM parties p LEFT JOIN transaction_legs tl ON tl.party_id=p.id GROUP BY p.id ORDER BY p.display_name COLLATE NOCASE''');
    final a = await db.rawQuery('''SELECT a.*, COUNT(DISTINCT tl.transaction_id) AS txn_count,
      COALESCE(SUM(CASE WHEN tl.direction='INCOMING' THEN tl.amount_minor ELSE 0 END),0) AS incoming_minor,
      COALESCE(SUM(CASE WHEN tl.direction='OUTGOING' THEN tl.amount_minor ELSE 0 END),0) AS outgoing_minor
      FROM bank_accounts a LEFT JOIN transaction_legs tl ON tl.account_id=a.id GROUP BY a.id ORDER BY a.bank_name, a.account_suffix''');
    final m = await db.rawQuery('''SELECT c.*, a.amount_minor AS amount_a, a.direction AS direction_a,
      b.direction AS direction_b FROM transaction_match_candidates c
      JOIN financial_transactions a ON a.id=c.transaction_id
      JOIN financial_transactions b ON b.id=c.candidate_transaction_id
      WHERE c.status='NEEDS_REVIEW' ORDER BY c.created_at DESC LIMIT 30''');
    if(mounted) setState((){people=p;accounts=a;matches=m;});
  }
  Future<void> _addPerson() async {
    final name=TextEditingController(), identifier=TextEditingController(); String type='UPI_ID';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Add person'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Person name')),const SizedBox(height:8),DropdownButtonFormField<String>(initialValue:type,decoration:const InputDecoration(labelText:'Identifier type'),items:const [DropdownMenuItem(value:'UPI_ID',child:Text('UPI ID')),DropdownMenuItem(value:'ACCOUNT',child:Text('Bank account')),DropdownMenuItem(value:'PHONE',child:Text('Phone number'))],onChanged:(v)=>type=v??'UPI_ID'),TextField(controller:identifier,decoration:const InputDecoration(labelText:'UPI ID / account / phone'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Save'))]));
    if(ok==true && name.text.trim().isNotEmpty){final id=await FinDatabase.instance.createParty(displayName:name.text.trim()); if(identifier.text.trim().isNotEmpty){final value=identifier.text.trim(); await FinDatabase.instance.addPartyIdentifier(partyId:id,identifierType:type,identifierValue:value,normalizedValue:type == 'ACCOUNT' ? 'account:${value.replaceAll(RegExp(r'[^0-9]'), '').length > 6 ? value.replaceAll(RegExp(r'[^0-9]'), '').substring(value.replaceAll(RegExp(r'[^0-9]'), '').length - 6) : value.replaceAll(RegExp(r'[^0-9]'), '')}' : value.toLowerCase());} await _load();}
    name.dispose();identifier.dispose();
  }
  Future<void> _review(Map<String,Object?> row,bool accept) async {
    final db=await FinDatabase.instance.database;
    await db.update('transaction_match_candidates',{'status':accept?'CONFIRMED':'REJECTED','reviewed_at':DateTime.now().millisecondsSinceEpoch},where:'id=?',whereArgs:[row['id']]);
    if(accept){
      await db.update('financial_transactions',{'direction':'TRANSFER','updated_at':DateTime.now().millisecondsSinceEpoch},where:'id IN (?,?)',whereArgs:[row['transaction_id'],row['candidate_transaction_id']]);
      final legacy = await db.query('financial_transactions', columns:['legacy_transaction_id'], where:'id IN (?,?)', whereArgs:[row['transaction_id'],row['candidate_transaction_id']]);
      for (final item in legacy) {
        final legacyId = item['legacy_transaction_id'];
        if (legacyId != null) await db.update('transactions', {'type':'TRANSFER','category':'Transfer'}, where:'id = ?', whereArgs:[legacyId]);
      }
    }
    await _load();
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('People & Accounts'),bottom:TabBar(controller:tabs,tabs:const[Tab(text:'People'),Tab(text:'Accounts')])) ,body:TabBarView(controller:tabs,children:[_people(),_accounts()]));
  Widget _people()=>RefreshIndicator(onRefresh:_load,child:ListView(padding:const EdgeInsets.all(12),children:[Align(alignment:Alignment.centerRight,child:FilledButton.icon(onPressed:_addPerson,icon:const Icon(Icons.person_add),label:const Text('Add person'))),if(people.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Text('No people mapped yet. Add a person and link a UPI ID, account number or phone number.')),...people.map((p)=>Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.person)),title:Text('${p['display_name']}'),subtitle:Text('${p['txn_count']} linked transactions · Received ${money.format(((p['received_minor'] as num).toInt())/100)} · Sent ${money.format(((p['sent_minor'] as num).toInt())/100)}'))))]));
  Widget _accounts()=>RefreshIndicator(onRefresh:_load,child:ListView(padding:const EdgeInsets.all(12),children:[if(accounts.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Text('Bank accounts are added automatically when recognized in imported SMS.')),...accounts.map((a)=>Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.account_balance)),title:Text('${a['bank_name']??'Bank'} ••••${a['account_suffix']??'----'}'),subtitle:Text('${a['txn_count']} transactions · In ${money.format(((a['incoming_minor'] as num).toInt())/100)} · Out ${money.format(((a['outgoing_minor'] as num).toInt())/100)}'),trailing:Text((a['is_own_account'] as num? ?? 1)==1?'My account':'External')))),const SizedBox(height:16),const Text('Possible transfers to review',style:TextStyle(fontWeight:FontWeight.bold,fontSize:17)),if(matches.isEmpty)const Padding(padding:EdgeInsets.all(12),child:Text('No possible transfer matches found.')),...matches.map((m)=>Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${m['match_type']} · ${m['confidence']}',style:const TextStyle(fontWeight:FontWeight.bold)),Text('${money.format(((m['amount_a'] as num).toInt())/100)} · ${m['direction_a']} ↔ ${m['direction_b']}'),Text(m['reason'].toString()),Row(mainAxisAlignment:MainAxisAlignment.end,children:[TextButton(onPressed:()=>_review(m,false),child:const Text('Not a match')),FilledButton(onPressed:()=>_review(m,true),child:const Text('Confirm transfer'))])]))))]));
}
