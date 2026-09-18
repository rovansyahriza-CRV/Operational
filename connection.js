'use strict';
// Browser-safe publishable key. No service-role credential belongs in this file.
const OP_CONFIG={url:'https://nhmpwjriextmbotmvvbu.supabase.co',key:'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz'};
let opSession=null,remoteContractId=null,remoteWoId=null,remoteWoStatus=null,remoteContracts=[],sharedDraftMeta=null;
async function rpc(name,params){const response=await fetch(OP_CONFIG.url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:OP_CONFIG.key,'Content-Type':'application/json'},body:JSON.stringify(params)});const body=await response.json().catch(()=>null);if(!response.ok)throw Error(body?.message||'Koneksi gagal ('+response.status+')');return body;}
async function api(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_api',{p_token:opSession.token,p_action:action,p_data:data});}
function hasPic(p){return !!opSession?.pic?.some(x=>['all',p.toLowerCase()].includes(String(x).trim().toLowerCase()))}
function authUi(){const local=!opSession;$('#approveWo').disabled=remoteWoStatus!=='DRAFT';$('#identity').textContent=opSession?'Masuk: '+opSession.name:'Belum login';$('#logout').hidden=local;$('#loginOpen').hidden=!local;$('#saveMaster').disabled=!hasPic('Operational Master Komersial')||!parsed.items.length||parsed.issues.some(i=>i.severity==='error')||!!remoteContractId;$('#saveWo').disabled=!hasPic('Operational WO')||!remoteContractId||!wo.length||wo.some(i=>!Number.isFinite(i.qty)||i.qty<=0)||!!remoteWoId;$('#loadContracts').disabled=local||!(hasPic('Operational WO')||hasPic('Operational Master Komersial'));$('#loadWos').disabled=!hasPic('Operational WO');$('#approveWo').hidden=!remoteWoId||!hasPic('Operational WO')||!opSession?.author?.some(x=>['all','operational approval wo'].includes(String(x).trim().toLowerCase()));document.querySelector('[data-tab="master"]').hidden=!local&&!hasPic('Operational Master Komersial')&&!hasPic('Operational WO');document.querySelector('[data-tab="wo"]').hidden=!local&&!hasPic('Operational WO');$('#importToggle').hidden=!local&&!hasPic('Operational Master Komersial');if(!local&&!hasPic('Operational Master Komersial'))$('#importPanel').hidden=true;$('#addWo').hidden=!local&&!hasPic('Operational WO');if(remoteWoId)$('#addWo').disabled=true;$('#addItemToggle').hidden=local||!hasPic('Operational Master Komersial')||!remoteContractId;if($('#addItemToggle').hidden)$('#addItemPanel').hidden=true;}
function busy(button,fn){return async()=>{button.disabled=true;try{await fn()}catch(err){status(err.message)}finally{button.disabled=false;authUi()}}}
const priorRenderMaster=renderMaster;renderMaster=function(){priorRenderMaster();if(remoteContractId)document.querySelectorAll('[data-parent]').forEach(el=>el.disabled=true);authUi()};const priorRenderWo=renderWo;renderWo=function(){priorRenderWo();authUi()};const priorTotal=total;total=function(){priorTotal();authUi()};
function resetBinding(){remoteContractId=null;remoteWoId=null;$('#contractBinding').textContent='Master belum tersimpan';['projectCode','projectName','contractNo','contractType','revision'].forEach(id=>$('#'+id).disabled=false);authUi()}
const oldPreview=$('#preview').onclick;
$('#preview').onclick=()=>{
 const prior=parsed;
 $('#previewFeedback').textContent='';
 oldPreview();
 if(prior!==parsed){
  resetBinding();
  $('#importPanel').hidden=true;
  $('#importToggle').textContent='Ubah pengaturan import';
  requestAnimationFrame(()=>{
   $('#summary').scrollIntoView({behavior:'instant',block:'start'});
   $('#summary').focus({preventScroll:true});
  });
 }else{
  $('#previewFeedback').textContent=$('#status').textContent;
 }
};
$('#loginOpen').onclick=()=>$('#loginDialog').showModal();$('#loginClose').onclick=()=>$('#loginDialog').close();
$('#loginForm').onsubmit=async e=>{e.preventDefault();const b=$('#loginSubmit');b.disabled=true;$('#loginError').textContent='';try{const id=$('#employeeId').value.trim();if(!/^\d+$/.test(id))throw Error('Pilih nama karyawan dari hasil pencarian.');const result=await rpc('op_login',{p_id:id,p_password:$('#employeePassword').value});if(result?.error)throw Error(result.error);opSession=result;$('#employeePassword').value='';$('#loginDialog').close();authUi();status('Login berhasil. Akses mengikuti PIC dan approval mengikuti Author.');if($('#projectCode').value)refreshSharedDrafts($('#projectCode').value);if(!hasPic('Operational Master Komersial')&&hasPic('Operational WO'))tab('wo')}catch(err){$('#loginError').textContent=err.message;$('#employeePassword').value=''}finally{b.disabled=false}};
$('#logout').onclick=async()=>{try{if(opSession)await rpc('op_logout',{p_token:opSession.token})}catch(err){status('Koneksi logout gagal; sesi di browser tetap dihapus.')}opSession=null;remoteContractId=null;remoteWoId=null;sharedDraftMeta=null;parsed={items:[],issues:[],skipped:[]};wo=[];setSms();selected.clear();$('#savedContracts').innerHTML='<option value="">Pilih kontrak tersimpan</option>';$('#savedWos').innerHTML='<option value="">Pilih WO tersimpan</option>';$('#sharedDrafts').innerHTML='<option value="">Pilih draft tim (Supabase)</option>';$('#sharedDrafts').disabled=true;renderMaster();renderWo();resetBinding();tab('master');status('Sudah keluar. Data yang dimuat telah dibersihkan.')};
$('#loadContracts').onclick=busy($('#loadContracts'),async()=>{remoteContracts=await api('contracts');$('#savedContracts').innerHTML='<option value="">Pilih kontrak tersimpan</option>'+remoteContracts.map(c=>`<option value="${c.id}">${escapeHtml(c.project_code+' / '+c.number+' / Rev '+c.revision)}</option>`).join('');status(remoteContracts.length+' kontrak tersedia.')});
async function loadMaster(cid){const contract=remoteContracts.find(c=>c.id===cid);if(!contract)throw Error('Pilih kontrak terlebih dahulu.');const rows=await api('master',{contractId:cid});remoteContractId=cid;remoteWoId=null;sharedDraftMeta=null;parsed={items:rows.map(i=>({id:i.id,code:i.code,description:i.description,parentId:i.parent_id,rowKind:i.row_kind,unit:i.unit,price:i.unit_price,qty:i.reference_qty,amount:i.source_amount,rate:i.rate_kind,sourceRow:i.source_row})),issues:[],skipped:[]};wo=[];setSms();selected.clear();collapsed.clear();$('#projectCode').value=contract.project_code;$('#projectName').value=contract.project_name;$('#contractNo').value=contract.number;$('#contractType').value=contract.contract_type;$('#revision').value=contract.revision;['projectCode','projectName','contractNo','contractType','revision'].forEach(id=>$('#'+id).disabled=true);$('#contractBinding').textContent=contract.number+' Â· Rev '+contract.revision+' Â· tersimpan';renderMaster();renderWo();status('Master dimuat dari Supabase.');tab('master')}
$('#savedContracts').onchange=async e=>{if(!e.target.value)return;if(wo.length&&!confirm('Muat kontrak lain dan kosongkan draft WO lokal?'))return;try{await loadMaster(e.target.value)}catch(err){status(err.message)}};
$('#saveMaster').onclick=busy($('#saveMaster'),async()=>{if(!confirm('Simpan master sebagai kontrak/revisi baru di Supabase? Struktur kelompok sudah ditinjau?'))return;const result=await api('import_master',{projectCode:$('#projectCode').value,projectName:$('#projectName').value,contractNo:$('#contractNo').value,contractType:$('#contractType').value,revision:$('#revision').value,sourceFile:sourceName,sourceSheet:$('#sheet').value,items:parsed.items});remoteContractId=result.contractId;parsed.items.forEach(i=>{i.parentId=i.parentId?result.itemIds[i.parentId]:null;i.id=result.itemIds[i.id]});wo.forEach(i=>i.sourceId=result.itemIds[i.sourceId]);selected.clear();$('#contractBinding').textContent=$('#contractNo').value+' Â· tersimpan';['projectCode','projectName','contractNo','contractType','revision'].forEach(id=>$('#'+id).disabled=true);renderMaster();status('Master tersimpan di Supabase. Harga pada WO akan disalin dari master ini.')});
function populateAddItemParent(){$('#addItemParent').innerHTML='<option value="">Tanpa induk</option>'+parsed.items.filter(i=>i.rowKind==='GROUP').map(g=>`<option value="${g.id}">${escapeHtml(g.description)}</option>`).join('');}
$('#addItemToggle').onclick=()=>{const willOpen=$('#addItemPanel').hidden;if(willOpen)populateAddItemParent();$('#addItemPanel').hidden=!willOpen;};
$('#addItemSubmit').onclick=busy($('#addItemSubmit'),async()=>{
 const description=$('#addItemDescription').value.trim(),unit=$('#addItemUnit').value.trim(),code=$('#addItemCode').value.trim(),parentId=$('#addItemParent').value;
 const priceRaw=$('#addItemPrice').value.trim(),qtyRaw=$('#addItemQty').value.trim();
 if(!description){$('#addItemFeedback').textContent='Uraian wajib diisi.';return;}
 if(!unit){$('#addItemFeedback').textContent='Satuan wajib diisi.';return;}
 const price=priceRaw===''?NaN:Number(priceRaw);
 if(!Number.isFinite(price)||price<0){$('#addItemFeedback').textContent='Unit price tidak valid.';return;}
 const qty=qtyRaw===''?null:Number(qtyRaw);
 if(qty!==null&&(!Number.isFinite(qty)||qty<0)){$('#addItemFeedback').textContent='Qty tidak valid.';return;}
 $('#addItemFeedback').textContent='';
 const result=await api('add_master_item',{contractId:remoteContractId,parentId:parentId||null,code:code||null,description,unit,price,qty,rateKind:'STANDARD'});
 parsed.items.push({id:result.itemId,code:code||null,description,parentId:parentId||null,rowKind:'ITEM',unit,price,qty,amount:qty!=null?qty*price:null,rate:'STANDARD',sourceRow:null});
 ['addItemCode','addItemDescription','addItemUnit','addItemQty','addItemPrice'].forEach(id=>$('#'+id).value='');
 $('#addItemParent').value='';
 renderMaster();
 status('Item manual tersimpan di kontrak. Belum masuk revisi Excel manapun -- eksklusif ditambahkan lewat form ini.');
});
$('#saveWo').onclick=busy($('#saveWo'),async()=>{const result=await api('save_wo',{contractId:remoteContractId,number:$('#woNo').value,title:$('#woTitle').value,items:wo});remoteWoId=result.woId;await displayWo(remoteWoId);status('WO tersimpan sebagai DRAFT. Belum disetujui.')});
$('#loadWos').onclick=busy($('#loadWos'),async()=>{const rows=await api('list_wo');$('#savedWos').innerHTML='<option value="">Pilih WO tersimpan</option>'+rows.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' / '+w.contract_number+' / '+w.status)}</option>`).join('');status(rows.length+' WO tersedia.')});
async function displayWo(id){const data=await api('read_wo',{woId:id});setSms();remoteWoId=id;remoteWoStatus=data.header.status;remoteContractId=data.header.contract_id;$('#woNo').value=data.header.number;$('#woTitle').value=data.header.title;wo=data.items.map(i=>({id:i.id,sourceId:i.commercial_item_id,code:i.code_snapshot,description:i.description_snapshot,unit:i.unit_snapshot,price:i.unit_price_snapshot,rate:i.rate_kind_snapshot,package:i.package_name,qty:i.qty,path:[]}));renderWo();$('#woRows').querySelectorAll('input,button').forEach(el=>el.disabled=true);$('#woNo').disabled=true;$('#woTitle').disabled=true;$('#woState').textContent=data.header.status+' Â· tampilan tersimpan';$('#approveWo').disabled=data.header.status!=='DRAFT';tab('wo')}
$('#savedWos').onchange=async e=>{if(!e.target.value)return;if(wo.length&&!remoteWoId&&!confirm('Ganti draft lokal dengan WO tersimpan?'))return;try{await displayWo(e.target.value)}catch(err){status(err.message)}};
$('#approveWo').onclick=busy($('#approveWo'),async()=>{if(!confirm('Setujui WO ini? Item dan harga WO yang disetujui akan terkunci.'))return;await api('approve_wo',{woId:remoteWoId});await displayWo(remoteWoId);status('WO disetujui. Approval tercatat di audit log.')});
$('#newWo').onclick=async()=>{if(wo.length&&!confirm('Kosongkan tampilan draft WO? Data yang sudah tersimpan tetap ada.'))return;try{if(remoteWoId){remoteContracts=await api('contracts');await loadMaster(remoteContractId);}wo=[];setSms();remoteWoId=null;remoteWoStatus=null;$('#woNo').disabled=false;$('#woTitle').disabled=false;$('#woNo').value='';$('#woTitle').value='';$('#woState').textContent='Draft baru';renderWo();tab('master')}catch(err){status(err.message)}};
$('#newMaster').onclick=()=>{if((parsed.items.length||wo.length)&&!confirm('Mulai master baru? Simpan atau unduh draft lokal terlebih dahulu.'))return;parsed={items:[],issues:[],skipped:[]};wo=[];sharedDraftMeta=null;setSms();selected.clear();collapsed.clear();resetBinding();$('#projectCode').value='';$('#projectName').value='';$('#contractNo').value='';$('#revision').value='01';$('#woNo').disabled=false;$('#woTitle').disabled=false;$('#importPanel').hidden=false;renderMaster();renderWo();tab('master')};
authUi();





// Restore downloaded drafts locally; never trust file IDs as database bindings.
$('#openWoDraft').onclick=()=>$('#woDraftFile').click();
$('#woDraftFile').onchange=async e=>{
 const file=e.target.files[0];if(!file)return;
 try{
  if(file.size>20*1024*1024)throw Error('Batas draft 20 MB.');
  const d=JSON.parse(await file.text());
  const str=v=>typeof v==='string'&&v.trim().length>0;
  if(d.format!=='bima-operational-draft-v1'||d.kind!=='wo'||d.currency!=='IDR'||!['BLANKET_ORDER','LUMPSUM'].includes(d.contractType)||!['project','contract','number','title'].every(k=>str(d[k]))||!Array.isArray(d.items)||!d.items.length)throw Error('Format draft WO tidak valid.');
  const smsRestored=validateSms(d.sms);
  const restored=d.items.map(i=>{
   if(!i||!['code','description','unit','package'].every(k=>str(i[k]))||!Number.isFinite(i.price)||i.price<0||!Number.isFinite(i.qty)||i.qty<=0||!Number.isFinite(i.price*i.qty)||!Array.isArray(i.path)||!i.path.every(x=>typeof x==='string')||!['STANDARD','WORKING','STANDBY'].includes(i.rate))throw Error('Data item draft tidak valid.');
   return {id:crypto.randomUUID(),sourceId:typeof i.sourceId==='string'?i.sourceId:'',code:i.code,description:i.description,unit:i.unit,package:i.package,price:i.price,qty:i.qty,path:i.path,rate:i.rate};
  });
  if(!Number.isFinite(restored.reduce((s,i)=>s+i.price*i.qty,0)))throw Error('Total draft tidak valid.');
  if((wo.length||parsed.items.length)&&!confirm('Ganti data lokal di halaman dengan draft WO dari file?'))return;
  parsed={items:[],issues:[],skipped:[]};selected.clear();collapsed.clear();workbook=null;
  remoteWoStatus=null;resetBinding();wo=restored;setSms(smsRestored);
  $('#projectCode').value='';$('#revision').value='01';
  $('#projectName').value=d.project;$('#contractNo').value=d.contract;$('#contractType').value=d.contractType;
  sourceName=typeof d.sourceFile==='string'?d.sourceFile:'';
  $('#sheet').replaceChildren(new Option(typeof d.sourceSheet==='string'?d.sourceSheet:''));$('#sheet').disabled=true;
  $('#excelFile').value='';$('#preview').disabled=true;
  $('#woNo').disabled=false;$('#woTitle').disabled=false;$('#woNo').value=d.number;$('#woTitle').value=d.title;await rememberSmsNumber(d.number,smsRestored.number);
  $('#woState').textContent='Draft lokal dari file';$('#savedContracts').value='';$('#savedWos').value='';
  renderMaster();renderWo();tab('wo');
  status('Draft WO dipulihkan dari file. Belum terhubung ke master Supabase. Simpan draft WO untuk mengunduh perubahan.');
 }catch(err){status('Gagal membuka draft: '+err.message)}finally{e.target.value=''}
};

const smsKeys=['number','revision','date','notification','location','approval','approver','approvalDate','contractor','proposer','proposerRole'];
const smsIds=['smsNumber','smsRevision','smsDate','smsNotification','smsLocation','smsApproval','smsApprover','smsApprovalDate','smsContractor','smsProposer','smsProposerRole'];
let smsEvidence=null;
function validateSms(raw){
 const d=raw??{};
 if(typeof d!=='object'||Array.isArray(d))throw Error('Referensi SMS tidak valid.');
 const out={};smsKeys.forEach(k=>{if(d[k]!=null&&typeof d[k]!=='string')throw Error('Field SMS tidak valid.');out[k]=d[k]??'';});
 out.approval=out.approval||'DRAFT';
 if(!['DRAFT','SUBMITTED','APPROVED'].includes(out.approval))throw Error('Status SMS tidak valid.');
 for(const k of ['date','approvalDate'])if(out[k]&&!/^\d{4}-\d{2}-\d{2}$/.test(out[k]))throw Error('Tanggal SMS tidak valid.');
 if(d.evidence){const e=d.evidence;if(typeof e.name!=='string'||typeof e.data!=='string'||!/^data:application\/pdf;base64,JVBERi0[A-Za-z0-9+/=]*$/.test(e.data)||e.data.length>12*1024*1024)throw Error('Bukti PDF tidak valid.');out.evidence={name:e.name,data:e.data};}
 out.routing=Object.fromEntries(['propose','supervisor','superintendent','requester'].map(k=>[k,d.routing?.[k]===true]));
 if(out.approval==='APPROVED'&&(!out.evidence||!Object.values(out.routing).every(Boolean)))out.approval='SUBMITTED';
 return out;
}
function getSms(){return validateSms({...Object.fromEntries(smsKeys.map((k,i)=>[k,$('#'+smsIds[i]).value.trim()])),evidence:smsEvidence,routing:Object.fromEntries([...document.querySelectorAll('[data-route]')].map(e=>[e.dataset.route,e.checked]))});}
function setSms(raw){const d=validateSms(raw);smsKeys.forEach((k,i)=>$('#'+smsIds[i]).value=d[k]);smsEvidence=d.evidence||null;document.querySelectorAll('[data-route]').forEach(e=>e.checked=d.routing[e.dataset.route]);$('#smsEvidence').value='';smsFeedback();}
function smsFeedback(){
 $('#smsEvidenceName').textContent=smsEvidence?'PDF tersimpan dalam draft: '+smsEvidence.name:'Belum ada bukti terlampir.';
 const d=getSms();$('#smsApproval').value=d.approval;$('#smsFeedback').textContent=d.approval==='APPROVED'?'Pastikan nomor SMS, revisi, nama, tanggal persetujuan, dan bukti PDF lengkap.':'Belum menjadi acuan yang disetujui end user.';
}
smsIds.forEach(id=>$('#'+id).addEventListener('change',smsFeedback));
$('#smsEvidence').onchange=async e=>{const f=e.target.files[0];if(!f)return;$('#smsEvidenceError').textContent='';try{if(f.size>8*1024*1024)throw Error('Batas PDF 8 MB.');const bytes=new Uint8Array(await f.arrayBuffer());if(new TextDecoder().decode(bytes.slice(0,5))!=='%PDF-')throw Error('File harus berupa PDF.');let binary='';for(let n=0;n<bytes.length;n+=8192)binary+=String.fromCharCode(...bytes.subarray(n,n+8192));smsEvidence={name:f.name,data:'data:application/pdf;base64,'+btoa(binary)};smsFeedback();status('PDF berhasil dilampirkan. Klik Simpan draft WO agar lampiran ikut tersimpan dalam JSON.');}catch(err){e.target.value='';$('#smsEvidenceError').textContent=err.message;status(err.message)}};
$('#smsRemoveEvidence').onclick=()=>{smsEvidence=null;$('#smsEvidence').value='';$('#smsEvidenceError').textContent='';smsFeedback()};
const downloadWithoutSms=download;
download=function(kind,data){
 if(kind==='wo'){try{const sms=getSms();if(sms.approval==='APPROVED'&&(!sms.number||!sms.revision||!sms.approver||!sms.approvalDate||!sms.evidence))throw Error('Lengkapi nomor/revisi SMS, nama/tanggal persetujuan, dan bukti PDF sebelum menyimpan status disetujui.');data={...data,sms};}catch(err){status(err.message);return;}}
 return downloadWithoutSms(kind,data);
};
// The existing remote API does not persist SMS yet; prevent silent metadata loss.
const saveWoWithoutSms=$('#saveWo').onclick;
$('#saveWo').onclick=async()=>{const d=getSms();if(smsEvidence||smsKeys.some(k=>k!=='approval'&&d[k])||d.approval!=='DRAFT'){status('WO–SMS saat ini disimpan melalui Simpan draft WO. Penyimpanan SMS ke Supabase belum tersedia.');return;}return saveWoWithoutSms();};

async function smsSequence(woNumber,minimum=0,allocate=false){
 if(!navigator.locks)throw Error('Browser belum mendukung penomoran aman antar tab.');
 return navigator.locks.request('bima-sms-numbering',()=>{
  const key='bima-operational-sms-sequence-v1:'+encodeURIComponent(woNumber.trim());
  const stored=localStorage.getItem(key),old=stored===null?0:Number(stored);
  if(!Number.isSafeInteger(old)||old<0)throw Error('Catatan urutan SMS lokal tidak valid.');
  const next=Math.max(old,minimum)+(allocate?1:0);
  if(!Number.isSafeInteger(next))throw Error('Urutan SMS melebihi batas.');
  localStorage.setItem(key,String(next));return next;
 });
}
async function rememberSmsNumber(woNumber,smsNumber){
 const prefix='BIMA-SMS/'+woNumber.trim()+'-';
 if(!smsNumber||!smsNumber.startsWith(prefix))return;
 const suffix=smsNumber.slice(prefix.length);
 if(!/^\d{3,}$/.test(suffix))return;
 const n=Number(suffix);if(!Number.isSafeInteger(n)||n<1)return;
 await smsSequence(woNumber,n);
}
$('#generateSms').onclick=async()=>{
 const b=$('#generateSms'),woNumber=$('#woNo').value.trim();
 if(!woNumber){status('Isi Nomor WO terlebih dahulu.');return;}
 if(remoteWoId){status('Buat draft lokal baru untuk nomor SMS baru.');return;}
 if($('#smsNumber').value.trim()&&!confirm('Buat nomor SMS berikutnya? Nomor lama tetap terpakai. Status dan bukti persetujuan akan dikosongkan untuk SMS baru.'))return;
 b.disabled=true;
 try{
  await rememberSmsNumber(woNumber,$('#smsNumber').value.trim());
  const n=await smsSequence(woNumber,0,true);
  $('#smsNumber').value='BIMA-SMS/'+woNumber+'-'+String(n).padStart(3,'0');
  $('#smsApproval').value='DRAFT';$('#smsApprover').value='';$('#smsApprovalDate').value='';smsEvidence=null;document.querySelectorAll('[data-route]').forEach(e=>e.checked=false);$('#smsEvidence').value='';smsFeedback();
  status('Nomor SMS dibuat. Simpan draft WO untuk menyimpan nomor ini bersama data pekerjaan.');
 }catch(err){status('Nomor SMS belum dibuat: '+err.message)}finally{b.disabled=false;}
};

document.querySelectorAll('[data-route]').forEach(e=>e.addEventListener('change',smsFeedback));
$('#printSms').onclick=()=>{
 try{
 const d=getSms(),v=id=>$('#'+id).value.trim();
 if(!wo.length||!['woNo','woTitle','projectName','contractNo'].every(id=>v(id))||!d.number||!d.revision||!d.date||!d.contractor||!d.proposer||!d.proposerRole)throw Error('Lengkapi project, kontrak, WO, nomor/revisi/tanggal SMS, kontraktor, serta nama dan jabatan proposer sebelum mencetak.');
 if(wo.some(i=>!Number.isFinite(i.qty)||i.qty<=0||!Number.isFinite(i.price)||i.price<0||!Number.isFinite(i.qty*i.price)))throw Error('Periksa qty dan harga item.');
 const sum=wo.reduce((s,i)=>s+i.qty*i.price,0);if(!Number.isFinite(sum))throw Error('Total tidak valid.');
 const e=escapeHtml,groups=new Map();wo.forEach(i=>{const k=i.package||'Paket 1';if(!groups.has(k))groups.set(k,[]);groups.get(k).push(i)});
 const rows=[...groups].map(([name,items])=>`<tr class="package"><td colspan="6">${e(name)}</td></tr>${items.map(i=>`<tr><td>${e(i.code)}</td><td>${e(i.description)}</td><td class="num">${fmt(i.qty)}</td><td>${e(i.unit)}</td><td class="num">${fmt(i.price)}</td><td class="num">${fmt(i.qty*i.price)}</td></tr>`).join('')}<tr><td colspan="5">Subtotal ${e(name)}</td><td class="num">${fmt(items.reduce((s,i)=>s+i.qty*i.price,0))}</td></tr>`).join('');
 const w=window.open('','_blank');if(!w)throw Error('Izinkan jendela pop-up untuk preview cetak.');
 w.opener=null;w.document.write(`<!doctype html><html lang="id"><head><meta charset="utf-8"><title>${e(d.number)}</title><style>@page{size:A4 portrait;margin:12mm}body{font:10px Arial;color:#111;margin:0}h1{text-align:center;font-size:18px}h2{font-size:13px}p{line-height:1.5}table{border-collapse:collapse;width:100%;margin:12px 0;table-layout:fixed}th,td{border:1px solid #555;padding:6px;vertical-align:top;overflow-wrap:anywhere}thead{display:table-header-group}tr{break-inside:avoid}th,.package{background:#eee}.num{text-align:right} .approval{break-inside:avoid;text-align:center}.signature{height:80px}.actions{padding:14px;background:#fff2d5}button{padding:10px;cursor:pointer}@media print{.actions{display:none}}</style></head><body><div class="actions"><button onclick="window.print()">Cetak / Save as PDF</button> Pilih kertas A4. Nonaktifkan header/footer browser. <button onclick="window.close()">Tutup</button></div><h1>SITE MEASUREMENT SHEET</h1><h2>${e(v('woTitle'))}</h2><table><tr><td>Project: ${e(v('projectName'))}</td><td>Kontrak: ${e(v('contractNo'))}</td></tr><tr><td>WO No.: ${e(v('woNo'))}</td><td>SMS No.: ${e(d.number)}</td></tr><tr><td>Notification: ${e(d.notification||'-')}</td><td>Revisi: ${e(d.revision)} / Tanggal: ${e(d.date)}</td></tr><tr><td colspan="2">Lokasi: ${e(d.location||'-')}</td></tr></table><p>Dokumen untuk sirkulasi persetujuan. Persetujuan mengacu pada dokumen bertanda tangan lengkap yang dilampirkan.</p><table class="approval"><tr><th>PROPOSE REPRESENTATIVE</th><th colspan="2">PRJ / EXE DEPARTMENT</th><th>REQUESTER REPRESENTATIVE</th></tr><tr><td>${e(d.contractor)}</td><td>Supervisor</td><td>Superintendent</td><td></td></tr><tr class="signature"><td></td><td></td><td></td><td></td></tr><tr><td>${e(d.proposer)}<br>${e(d.proposerRole)}</td><td>Nama / Jabatan:<br><br>Tanggal:</td><td>Nama / Jabatan:<br><br>Tanggal:</td><td>Nama / Jabatan:<br><br>Tanggal:</td></tr></table><table><colgroup><col style="width:9%"><col style="width:43%"><col style="width:10%"><col style="width:8%"><col style="width:14%"><col style="width:16%"></colgroup><thead><tr><th>Kode</th><th>Uraian / Scope</th><th>Qty</th><th>Unit</th><th>Unit price (Rp)</th><th>Nilai (Rp)</th></tr></thead><tbody>${rows}<tr><th colspan="5">TOTAL NILAI KOMERSIAL</th><th class="num">${fmt(sum)}</th></tr></tbody></table><p>Nilai dihitung menggunakan presisi harga sumber; angka ditampilkan hingga 2 desimal. Biaya aktual resources dicatat terpisah.</p></body></html>`);w.document.close();
 status('Preview cetak dibuka. Gunakan Cetak / Save as PDF untuk mengunduh atau mencetak. Status approval tidak berubah.');
 }catch(err){status(err.message)}
};

"use strict";
const projectStorage='bima-spms-projects-v1';let projectList=[],editingProject=null;
try{const saved=JSON.parse(localStorage.getItem(projectStorage)||'[]');if(!Array.isArray(saved)||saved.some(p=>!p||!['id','code','name','client','location','state'].every(k=>typeof p[k]==='string')))throw Error('Format project tidak valid');projectList=saved;}catch(e){status('Daftar project lokal tidak dapat dibaca: '+e.message);}
const states={ACTIVE:'Aktif',PLANNING:'Persiapan',CLOSED:'Selesai'};
function renderProjects(){
 renderProjectCodeOptions();
 $('#projectCount').textContent=projectList.length;$('#activeProjectCount').textContent=projectList.filter(p=>p.state==='ACTIVE').length;
 const q=$('#projectSearch').value.toLowerCase();$('#projectCards').innerHTML=projectList.filter(p=>(p.code+' '+p.name+' '+p.client).toLowerCase().includes(q)).map(p=>`<article class="project-card"><div class="toolbar"><span class="project-code">${escapeHtml(p.code)}</span><span class="tag">${escapeHtml(states[p.state]||p.state)}</span></div><h3>${escapeHtml(p.name)}</h3><p>${escapeHtml(p.client||'Client belum diisi')}<br>${escapeHtml(p.location||'Lokasi belum diisi')}</p><p><strong>Kontrak:</strong> ${escapeHtml(p.contract||'Belum diisi')}<br><strong>Periode:</strong> ${escapeHtml(p.startDate||'—')} s/d ${escapeHtml(p.endDate||'—')}</p><div class="toolbar"><button data-project-open="${escapeHtml(p.id)}" class="primary">Buka master →</button><button data-project-edit="${escapeHtml(p.id)}">Edit</button></div></article>`).join('')||'<div class="empty project-card">Belum ada project yang cocok. Tambahkan identitas project untuk mulai menyusun master komersial.</div>';
 document.querySelectorAll('[data-project-edit]').forEach(b=>b.onclick=()=>editProject(b.dataset.projectEdit));
 document.querySelectorAll('[data-project-open]').forEach(b=>b.onclick=()=>{const p=projectList.find(p=>p.id===b.dataset.projectOpen);if(parsed.items.length||wo.length||remoteContractId){if($('#projectCode').value===p.code&&$('#projectName').value===p.name){tab('master');return;}status('Simpan draft yang sedang terbuka, lalu gunakan Master baru sebelum berpindah project.');return;}$('#projectCode').value=p.code;$('#projectName').value=p.name;$('#contractNo').value=p.contract||'';tab('master');status('Project dipilih. Isi kontrak lalu import master komersial.');loadProjectLocalMaster(p);});
}
function editProject(id){const p=projectList.find(p=>p.id===id);editingProject=p?.id||null;$('#projectDialogTitle').textContent=p?'Edit project':'Project baru';for(const [field,key]of Object.entries({pCode:'code',pName:'name',pClient:'client',pLocation:'location',pContract:'contract',pStart:'startDate',pEnd:'endDate',pStatus:'state'}))$('#'+field).value=p?.[key]||(key==='state'?'ACTIVE':'');$('#projectError').textContent='';$('#projectDialog').showModal();}
$('#addProject').onclick=()=>editProject();$('#closeProject').onclick=()=>$('#projectDialog').close();$('#projectSearch').oninput=renderProjects;
$('#projectForm').onsubmit=e=>{e.preventDefault();try{const p={id:editingProject||crypto.randomUUID(),code:$('#pCode').value.trim(),name:$('#pName').value.trim(),client:$('#pClient').value.trim(),location:$('#pLocation').value.trim(),contract:$('#pContract').value.trim(),startDate:$('#pStart').value,endDate:$('#pEnd').value,state:$('#pStatus').value};if(!p.code||!p.name)throw Error('Kode dan nama wajib diisi.');if((p.startDate&&!p.endDate)||(!p.startDate&&p.endDate))throw Error('Isi Start Date dan End Date untuk periode project.');if(p.startDate&&p.endDate<p.startDate)throw Error('End Date tidak boleh lebih awal dari Start Date.');if(projectList.some(x=>x.id!==p.id&&x.code.toLowerCase()===p.code.toLowerCase()))throw Error('Kode project sudah digunakan.');const next=editingProject?projectList.map(x=>x.id===p.id?p:x):[...projectList,p];localStorage.setItem(projectStorage,JSON.stringify(next));projectList=next;renderProjects();$('#projectDialog').close();status('Identitas project tersimpan di browser ini.');}catch(err){$('#projectError').textContent=err.message}};
const originalTab=tab;tab=function(name){originalTab(name);$('#contractBinding').hidden=name==='projects';const copy={projects:['PROJECT WORKSPACE','Project List','Kelola project, kontrak, dan pekerjaan dalam satu tempat.'],master:['CONTRACT & PRICING','Master Commercial','Import remunerasi, tinjau struktur item, dan siapkan tarif pekerjaan.'],wo:['WORK EXECUTION','WO–SMS','Susun scope, kelola referensi approval, dan siapkan dokumen cetak.']}[name];if(copy){$('#pageEyebrow').textContent=copy[0];$('#pageTitle').textContent=copy[1];$('#pageDescription').textContent=copy[2];}if(name==='projects')renderProjects();};
renderProjects();tab('projects');

function renderProjectCodeOptions(){
 $('#projectCodeOptions').replaceChildren(...projectList.map(p=>new Option(p.name+' / '+(p.client||''),p.code)));
 $('#projectCodeHint').textContent=projectList.length?'Ketik kode atau nama, lalu pilih project.':'Belum ada project. Tambahkan melalui Project List.';
}
let projectBeforeSearch=null;
$('#projectCode').addEventListener('focus',()=>{projectBeforeSearch={code:$('#projectCode').value,name:$('#projectName').value};});
$('#projectCode').addEventListener('change',()=>{
 const field=$('#projectCode'),p=projectList.find(p=>p.code.toLowerCase()===field.value.trim().toLowerCase());
 const previous=projectBeforeSearch||{code:'',name:$('#projectName').value};
 if(!p){field.value=previous.code;status('Pilih kode yang tersedia di Project List. Tambahkan project baru dari menu Project List.');return;}
 if((parsed.items.length||wo.length||remoteContractId)&&(previous.code!==p.code||previous.name!==p.name)){
  field.value=previous.code;status('Simpan draft lalu gunakan Master baru sebelum berpindah project.');return;
 }
 field.value=p.code;$('#projectName').value=p.name;if(!parsed.items.length&&!wo.length&&!remoteContractId)$('#contractNo').value=p.contract||'';projectBeforeSearch={code:p.code,name:p.name};status('Project dipilih: '+p.name);loadProjectLocalMaster(p);
});
renderProjectCodeOptions();

function localMasterKey(p){return 'bima-spms-masters-v1:'+p.id;}
function readLocalMasters(p){const data=JSON.parse(localStorage.getItem(localMasterKey(p))||'[]');if(!Array.isArray(data))throw Error('Data master lokal tidak valid.');return data;}
function currentLocalProject(){return projectList.find(p=>p.code===$('#projectCode').value.trim());}
function refreshLocalMasters(p){const rows=readLocalMasters(p);$('#localMasters').replaceChildren(new Option('Pilih master lokal',''),...rows.map((r,i)=>new Option(r.contract+' / Rev '+r.revision,String(i))));return rows;}
function applyLocalMaster(p,d){
 resetBinding();remoteWoStatus=null;sharedDraftMeta=null;parsed=structuredClone(d.parsed);selected.clear();collapsed.clear();workbook=null;
 $('#projectCode').value=p.code;$('#projectName').value=p.name;$('#contractNo').value=d.contract;$('#revision').value=d.revision;$('#contractType').value=d.contractType;
 sourceName=d.sourceFile;$('#sheet').replaceChildren(new Option(d.sourceSheet));$('#sheet').disabled=true;$('#excelFile').value='';$('#preview').disabled=true;$('#search').value='';
 $('#importPanel').hidden=true;$('#importToggle').textContent='Ubah pengaturan import';$('#contractBinding').textContent=d.contract+' / Rev '+d.revision+' / tersimpan lokal';renderMaster();renderWo();status('Master lokal dimuat: '+parsed.items.filter(i=>i.rowKind==='ITEM').length+' item. Belum tersimpan di Supabase.');
}
function loadProjectLocalMaster(p){try{const rows=refreshLocalMasters(p);if(!parsed.items.length&&!wo.length&&!remoteContractId&&rows.length){const i=rows.length-1;applyLocalMaster(p,rows[i]);$('#localMasters').value=String(i);}}catch(err){status('Gagal memuat master lokal: '+err.message)}refreshSharedDrafts(p.code)}
async function refreshSharedDrafts(projectCode){
 const sel=$('#sharedDrafts'),hint=$('#sharedDraftsHint');
 sel.innerHTML='<option value="">Pilih draft tim (Supabase)</option>';
 if(!opSession||!hasPic('Operational Master Komersial')){sel.disabled=true;if(hint)hint.textContent='Login untuk melihat draft yang dibagikan tim.';return;}
 sel.disabled=false;
 try{
  const rows=await api('list_drafts',{projectCode});
  rows.forEach(r=>sel.appendChild(new Option(`${r.contract_no} / Rev ${r.revision} Â· ${r.updated_by_name||'?'} Â· ${new Date(r.updated_at).toLocaleString('id-ID')}`,JSON.stringify({contractNo:r.contract_no,revision:r.revision}))));
  if(hint)hint.textContent=rows.length?rows.length+' draft tim tersedia untuk project ini.':'Belum ada draft tim untuk project ini.';
 }catch(err){if(hint)hint.textContent='Gagal memuat draft tim: '+err.message;}
}
$('#sharedDrafts').onchange=async e=>{
 if(!e.target.value)return;
 try{
  const {contractNo,revision}=JSON.parse(e.target.value);
  const p=currentLocalProject();if(!p)throw Error('Pilih project terlebih dahulu.');
  if((parsed.items.length||wo.length||remoteContractId)&&!confirm('Muat draft tim ini? Perubahan yang belum disimpan di halaman akan diganti.'))return;
  const data=await api('load_draft',{projectCode:p.code,contractNo,revision});
  resetBinding();remoteWoStatus=null;parsed=data.payload;selected.clear();collapsed.clear();workbook=null;
  $('#projectCode').value=p.code;$('#projectName').value=p.name;$('#contractNo').value=contractNo;$('#revision').value=revision;$('#contractType').value=data.contractType;
  sourceName=data.sourceFile||'';$('#sheet').replaceChildren(new Option(data.sourceSheet||''));$('#sheet').disabled=true;$('#excelFile').value='';$('#preview').disabled=true;$('#search').value='';
  $('#importPanel').hidden=true;$('#importToggle').textContent='Ubah pengaturan import';$('#contractBinding').textContent=contractNo+' / Rev '+revision+' / draft tim';
  sharedDraftMeta={projectCode:p.code,contractNo,revision,updatedAt:data.updatedAt};
  $('#localMasters').value='';renderMaster();renderWo();status('Draft tim dimuat. Belum tersimpan sebagai kontrak final di Supabase.');
 }catch(err){status('Gagal memuat draft tim: '+err.message)}
};
$('#localMasters').onchange=e=>{if(e.target.value==='')return;try{if(wo.length||remoteContractId){status('Simpan draft dan gunakan Master baru sebelum mengganti master.');return;}const p=currentLocalProject();if(!p)throw Error('Pilih project.');const rows=readLocalMasters(p),d=rows[Number(e.target.value)];if(!d)return;if(parsed.items.length&&!confirm('Muat versi master tersimpan? Perubahan master yang belum disimpan akan diganti.'))return;applyLocalMaster(p,d);}catch(err){status(err.message)}};
const exportMasterDownload=$('#exportMaster').onclick;
$('#exportMaster').onclick=async()=>{
 try{const p=currentLocalProject();if(!p)throw Error('Pilih Kode Project dari Project List sebelum menyimpan master.');const contract=$('#contractNo').value.trim(),revision=$('#revision').value.trim();if(!contract||!revision)throw Error('Isi nomor kontrak dan revisi.');if(!parsed.items.length||parsed.issues.some(i=>i.severity==='error'))throw Error('Master belum valid.');
 const rows=readLocalMasters(p),d={contract,revision,contractType:$('#contractType').value,sourceFile:sourceName,sourceSheet:$('#sheet').value,parsed:structuredClone(parsed)};
 const prior=rows.findIndex(r=>r.contract===contract&&r.revision===revision);if(prior>=0&&!confirm('Perbarui master lokal untuk kontrak dan revisi ini? Gunakan revisi baru untuk menyimpan versi terpisah.'))return;if(prior>=0)rows.splice(prior,1);rows.push(d);
 localStorage.setItem(localMasterKey(p),JSON.stringify(rows));refreshLocalMasters(p);$('#localMasters').value=String(rows.length-1);exportMasterDownload();
 if(opSession&&hasPic('Operational Master Komersial')){
  try{
   const sameDraft=sharedDraftMeta&&sharedDraftMeta.projectCode===p.code&&sharedDraftMeta.contractNo===contract&&sharedDraftMeta.revision===revision;
   const result=await api('save_draft',{projectCode:p.code,contractNo:contract,revision,contractType:$('#contractType').value,sourceFile:sourceName,sourceSheet:$('#sheet').value,payload:parsed,expectedUpdatedAt:sameDraft?sharedDraftMeta.updatedAt:null});
   sharedDraftMeta={projectCode:p.code,contractNo:contract,revision,updatedAt:result.updatedAt};
   await refreshSharedDrafts(p.code);
   status('Master tersimpan lokal, dibagikan ke tim lewat Supabase, dan cadangan JSON diunduh.');
  }catch(err){
   status('Tersimpan lokal, tapi gagal dibagikan ke tim: '+err.message+(String(err.message).includes('diperbarui orang lain')?' Muat ulang draft tim lalu gabungkan perubahan sebelum menyimpan lagi.':''));
  }
 }else{
  status('Master tersimpan di project pada browser ini dan cadangan JSON diunduh. Belum tersimpan di Supabase.'+(opSession?'':' Login untuk membagikan draft ke tim.'));
 }
 }catch(err){status('Master belum tersimpan lokal: '+err.message)}
};

let employeeSearchTimer,employeeSearchVersion=0;
$('#employeeSearch').addEventListener('input',()=>{
 clearTimeout(employeeSearchTimer);const version=++employeeSearchVersion,query=$('#employeeSearch').value.trim();
 $('#employeeId').value='';$('#employeePassword').value='';$('#employeeSuggestions').replaceChildren();$('#employeeSuggestions').hidden=true;
 $('#employeeSearchStatus').textContent=query.length<2?'Ketik minimal 2 huruf nama.':'Mencari karyawan...';
 if(query.length<2)return;
 employeeSearchTimer=setTimeout(async()=>{
  try{const rows=await rpc('search_active_karyawan',{p_query:query});if(version!==employeeSearchVersion)return;
   const matches=Array.isArray(rows)?rows.slice(0,8):[];
   $('#employeeSearchStatus').textContent=matches.length?'Pilih nama yang sesuai.':'Nama tidak ditemukan.';
   for(const row of matches){if(!/^\d+$/.test(String(row.id))||typeof row.nama!=='string')continue;const button=document.createElement('button');button.type='button';button.textContent=row.nama+' (ID: '+row.id+')';button.onclick=()=>{++employeeSearchVersion;$('#employeeId').value=String(row.id);$('#employeeSearch').value=row.nama+' (ID: '+row.id+')';$('#employeeSuggestions').hidden=true;$('#employeeSuggestions').replaceChildren();$('#employeeSearchStatus').textContent='Karyawan dipilih. Masukkan password akun.';$('#employeePassword').focus();};$('#employeeSuggestions').append(button);}
   $('#employeeSuggestions').hidden=!$('#employeeSuggestions').children.length;
  }catch(err){if(version===employeeSearchVersion)$('#employeeSearchStatus').textContent='Pencarian gagal. Ketik ulang untuk mencoba lagi.';}
 },300);
});
$('#loginDialog').addEventListener('close',()=>{clearTimeout(employeeSearchTimer);++employeeSearchVersion;$('#employeeSuggestions').hidden=true;$('#employeePassword').value='';});

const renderAuthControls=authUi,openWorkspaceTab=tab;
function canOpenPage(name){return !!opSession && (name==='wo'?hasPic('Operational WO'):name==='master'?(hasPic('Operational Master Komersial')||hasPic('Operational WO')):name==='projects'&&hasPic('Operational Master Komersial'));}
tab=function(name){if(canOpenPage(name))openWorkspaceTab(name);};
authUi=function(){
 renderAuthControls();const locked=!opSession;
 document.body.classList.toggle('auth-locked',locked);
 document.querySelectorAll('main,aside').forEach(el=>el.inert=locked);
 document.querySelectorAll('[data-tab]').forEach(el=>{el.hidden=!canOpenPage(el.dataset.tab);el.disabled=el.hidden;});
 $('#loginClose').hidden=locked;
 if(locked){document.querySelectorAll('dialog[open]').forEach(d=>{if(d.id!=='loginDialog')d.close();});if(!$('#loginDialog').open)$('#loginDialog').showModal();}
 else if(!canOpenPage(document.querySelector('[data-tab].active')?.dataset.tab))tab(hasPic('Operational Master Komersial')?'projects':'wo');
};
$('#loginDialog').addEventListener('cancel',e=>{if(!opSession)e.preventDefault();});
setInterval(()=>{if(opSession&&Date.parse(opSession.expiresAt)<=Date.now()){opSession=null;authUi();$('#loginError').textContent='Sesi berakhir. Silakan login kembali.';}},1000);
authUi();
