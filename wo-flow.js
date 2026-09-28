'use strict';
// Alur WO–SMS: 1 Create WO -> 2 Create SMS (pilih item kontrak) -> 3 Detail treatment (opsional) -> SAVE -> Daftar WO.
// SAVE menyimpan berurutan (save_wo -> save_sms -> add_detail_row). Kalau gagal di tengah, yang sudah
// tersimpan diingat (flow.savedWoId / flow.savedSmsId / detail.savedId), jadi SAVE ulang gak bikin WO/SMS dobel.
// Persetujuan end user & approval internal WO dikerjakan dari Daftar WO, bukan dari form pembuatan.
let flow=null,flowMaster=[],flowMasterContract=null,woListRows=null,woContracts=new Map(),approvalSms=null,approvalSnapshot=null;
const woTreeOpen=new Set(),smsTreeOpen=new Set(),smsListCache=new Map(),smsDataCache=new Map();
const canWo=()=>!!opSession&&hasPic('Operational WO');
const canApproveWo=()=>canWo()&&!!opSession?.author?.some(x=>['all','operational approval wo'].includes(String(x).trim().toLowerCase()));
const blanketContracts=()=>[...woContracts.values()].filter(c=>c.contract_type==='BLANKET_ORDER'&&!/^INT-/.test(c.number||''));
const contractLabel=c=>c?`${c.project_code} · ${c.project_name} · ${c.number} Rev ${c.revision}`:'-';
const statusTag=s=>`<span class="tag st-${escapeHtml(String(s||'').toLowerCase())}">${escapeHtml(s||'-')}</span>`;
const headerIds=['smsDate','smsNotification','smsLocation','smsContractor','smsProposer','smsProposerRole'];

// ---------- view switching ----------
function woShowView(view){
 $('#woCreate').hidden=view!=='create';$('#woList').hidden=view!=='list';
 $('#woViewList').classList.toggle('active',view==='list');$('#woViewCreate').classList.toggle('active',view==='create');
 if(view==='list'&&canWo()&&!woListRows)loadWoList().catch(err=>status(err.message));
}
$('#woViewList').onclick=()=>woShowView('list');
$('#woViewCreate').onclick=()=>{if(!canWo()){status('Login dengan akses Operational WO dulu.');return}if(!flow)startFlow();woShowView('create')};

function woFlowAuthUi(){
 const ok=canWo();
 $('#woLoginHint').hidden=ok;$('#woViewCreate').disabled=!ok;$('#woListRefresh').disabled=!ok;
 if(!opSession&&(woListRows||flow)){woListRows=null;flow=null;woContracts=new Map();smsListCache.clear();smsDataCache.clear();woTreeOpen.clear();smsTreeOpen.clear();$('#woTree').innerHTML='<p class="empty">Login untuk melihat WO.</p>';woShowView('list')}
}

// ---------- flow state ----------
function startFlow(opts={}){
 flow={step:1,mode:opts.woId?'existing':'new',contractId:opts.contractId||'',woId:opts.woId||'',smsId:opts.smsId||null,reviseFromId:opts.reviseFromId||null,
  approval:opts.approval||{status:'DRAFT',routing:{propose:false,supervisor:false,superintendent:false,requester:false},approvalDate:''},
  savedWoId:null,savedSmsId:null,details:[],detailItem:'',label:opts.label||'',itemsContract:opts.contractId||null,lockWo:!!opts.woId};
 if(!opts.keepItems)wo=[];
 if(!woContracts.size&&canWo())loadWoList().catch(err=>status(err.message));
 headerIds.forEach(id=>$('#'+id).value=opts.header?.[id]||'');
 if(!opts.header)$('#smsDate').value=new Date().toISOString().slice(0,10);
 $('#woNo').value='';$('#woTitle').value='';$('#flowItemSearch').value='';
 document.querySelector(`[name="flowWoMode"][value="${flow.mode}"]`).checked=true;
 renderFlowStep1();renderWo();flowGoto(opts.step||1,true);
}
function flowLocked(){return !!(flow&&(flow.lockWo||flow.smsId||flow.reviseFromId||flow.savedWoId))}
function renderFlowStep1(){
 const contracts=blanketContracts();
 $('#flowContract').innerHTML='<option value="">Pilih kontrak</option>'+contracts.map(c=>`<option value="${c.id}">${escapeHtml(contractLabel(c))}</option>`).join('');
 $('#flowContract').value=flow.mode==='new'?flow.contractId:'';
 const wos=woListRows||[];
 $('#flowExistingWoSel').innerHTML='<option value="">Pilih WO</option>'+wos.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' · '+(w.title||'')+' · '+w.status)}</option>`).join('');
 $('#flowExistingWoSel').value=flow.mode==='existing'?flow.woId:'';
 $('#flowNewWo').hidden=flow.mode!=='new';$('#flowExistingWo').hidden=flow.mode!=='existing';
 const locked=flowLocked();
 document.querySelectorAll('[name="flowWoMode"],#flowExistingWoSel,#flowContract').forEach(el=>el.disabled=locked);
 $('#woNo').disabled=$('#woTitle').disabled=!!flow.savedWoId;
 $('#flowModeNote').hidden=!flow.label;$('#flowModeNote').textContent=flow.label;
}
document.querySelectorAll('[name="flowWoMode"]').forEach(r=>r.onchange=()=>{flow.mode=r.value;if(flow.mode==='new')flow.woId='';else flow.contractId='';renderFlowStep1()});
$('#flowContract').onchange=e=>{flow.contractId=e.target.value};
$('#flowExistingWoSel').onchange=e=>{flow.woId=e.target.value;flow.contractId=(woListRows||[]).find(w=>w.id===flow.woId)?.contract_id||''};

function flowWo(){return flow.mode==='existing'?(woListRows||[]).find(w=>w.id===flow.woId):null}
function flowContract(){return woContracts.get(flow.contractId)}
function validateStep(n){
 if(n>=1){
  if(flow.mode==='new'){
   if(!flow.contractId)return[1,'Pilih kontrak dulu.'];
   if(!$('#woNo').value.trim()||!$('#woTitle').value.trim())return[1,'Isi Nomor WO dan Nama WO.'];
   if(!flow.savedWoId&&(woListRows||[]).some(w=>w.contract_id===flow.contractId&&w.number.toLowerCase()===$('#woNo').value.trim().toLowerCase()))return[1,'Nomor WO sudah dipakai di kontrak ini. Pilih "Tambah SMS ke WO yang sudah ada" kalau mau nambah SMS.'];
  }else if(!flow.woId)return[1,'Pilih WO yang mau ditambah SMS.'];
 }
 if(n>=2){
  if(!$('#smsDate').value)return[2,'Isi Tanggal SMS.'];
  if(!$('#smsContractor').value.trim()||!$('#smsProposer').value.trim()||!$('#smsProposerRole').value.trim())return[2,'Isi nama kontraktor, nama dan jabatan Propose Representative.'];
  if(!wo.length)return[2,'Centang minimal satu item kontrak untuk SMS ini.'];
  if(wo.some(i=>!Number.isFinite(i.qty)||i.qty<=0))return[2,'Ada qty item SMS yang belum valid.'];
 }
 return null;
}
async function flowGoto(step,force){
 if(!force&&step>flow.step){const err=validateStep(step-1);if(err){status(err[1]);if(err[0]<flow.step||err[0]!==flow.step)flowGoto(err[0],true);return}}
 if(step>=2){try{await ensureFlowMaster()}catch(err){status(err.message);return}}
 flow.step=step;
 document.querySelectorAll('.flow-step').forEach(p=>p.hidden=Number(p.dataset.panel)!==step);
 document.querySelectorAll('.stepper li[data-step]').forEach(li=>{const n=Number(li.dataset.step);li.classList.toggle('active',n===step);li.classList.toggle('done',n<step)});
 if(step===2)renderFlowStep2();
 if(step===3)renderFlowStep3();
 $('#woCreate').scrollIntoView({block:'start',behavior:'smooth'});
}
document.querySelectorAll('[data-goto]').forEach(b=>b.onclick=()=>flowGoto(Number(b.dataset.goto)));
document.querySelectorAll('[data-next]').forEach(b=>b.onclick=()=>flowGoto(Number(b.dataset.next)));
document.querySelectorAll('[data-prev]').forEach(b=>b.onclick=()=>flowGoto(Number(b.dataset.prev),true));

// ---------- step 2: item kontrak ----------
async function ensureFlowMaster(){
 if(!flow.contractId)throw Error('Kontrak WO belum diketahui.');
 if(wo.length&&flow.itemsContract&&flow.itemsContract!==flow.contractId){
  if(!confirm('Kontrak berubah. Kosongkan item SMS yang sudah dipilih dari kontrak sebelumnya?'))throw Error('Kontrak tidak diganti -- kembalikan pilihan WO/kontrak di langkah 1.');
  wo=[];flow.details=[];renderWo();
 }
 flow.itemsContract=flow.contractId;
 if(flowMasterContract===flow.contractId)return;
 const rows=await api('master',{contractId:flow.contractId});
 flowMaster=rows.map(i=>({id:i.id,code:i.code,description:i.description,parentId:i.parent_id,rowKind:i.row_kind,unit:i.unit,price:Number(i.unit_price),rate:i.rate_kind}));
 flowMasterContract=flow.contractId;
}
function masterPath(item){const names=[];let cur=flowMaster.find(i=>i.id===item.parentId),guard=0;while(cur&&guard++<50){names.unshift(cur.description);cur=flowMaster.find(i=>i.id===cur.parentId)}return names}
function renderFlowStep2(){
 const c=flowContract(),w=flowWo();
 $('#flowCtx2').textContent=(w?w.number+' · '+(w.title||''):$('#woNo').value.trim()+' · '+$('#woTitle').value.trim()+' (WO baru)')+' — '+contractLabel(c);
 const project=typeof projectList!=='undefined'?projectList.find(p=>p.code===c?.project_code):null;
 if(!$('#smsContractor').value.trim()&&project?.contractorName)$('#smsContractor').value=project.contractorName;
 if(!$('#smsLocation').value.trim()&&project?.location)$('#smsLocation').value=project.location;
 renderFlowPicker();
}
function renderFlowPicker(){
 const q=$('#flowItemSearch').value.trim().toLowerCase(),pack=$('#packageName').value.trim()||'Paket 1';
 const items=flowMaster.filter(i=>i.rowKind==='ITEM');
 const hits=items.filter(i=>!q||(i.code+' '+i.description+' '+masterPath(i).join(' ')).toLowerCase().includes(q));
 const shown=hits.slice(0,150);
 $('#flowPickRows').innerHTML=shown.map(i=>{const on=wo.some(l=>l.sourceId===i.id&&l.package===pack);const path=masterPath(i).join(' / ');return `<tr class="${on?'picked':''}"><td><input type="checkbox" data-pick="${i.id}" ${on?'checked':''} aria-label="Pilih ${escapeHtml(i.code)}"></td><td>${escapeHtml(i.code)}</td><td class="scope">${escapeHtml(i.description)}${path?`<small>${escapeHtml(path)}</small>`:''}</td><td>${escapeHtml(i.unit)}</td><td class="num">${fmt(i.price)}</td></tr>`}).join('')
  ||`<tr><td colspan="5" class="empty">${items.length?'Tidak ada item yang cocok.':'Kontrak ini belum punya item. Isi dulu di Master Commercial.'}</td></tr>`;
 if(hits.length>shown.length)$('#flowPickRows').insertAdjacentHTML('beforeend',`<tr><td colspan="5" class="empty">Menampilkan 150 dari ${hits.length} item. Persempit pencarian.</td></tr>`);
 document.querySelectorAll('[data-pick]').forEach(el=>el.onchange=()=>{
  const item=flowMaster.find(i=>i.id===el.dataset.pick),pack=$('#packageName').value.trim()||'Paket 1';
  if(el.checked){if(!wo.some(l=>l.sourceId===item.id&&l.package===pack))wo.push({id:crypto.randomUUID(),sourceId:item.id,code:item.code,description:item.description,unit:item.unit,price:item.price,rate:item.rate,path:masterPath(item),package:pack,qty:1})}
  else{const line=wo.find(l=>l.sourceId===item.id&&l.package===pack);if(line&&!removeLine(line.id)){el.checked=true;return}}
  renderWo();
 });
}
function removeLine(lineId){
 const has=flow?.details.some(d=>d.lineId===lineId);
 if(has&&!confirm('Item ini punya detail treatment yang belum disimpan. Hapus item beserta detailnya?'))return false;
 wo=wo.filter(l=>l.id!==lineId);if(flow)flow.details=flow.details.filter(d=>d.lineId!==lineId);
 return true;
}
$('#flowItemSearch').oninput=renderFlowPicker;$('#packageName').addEventListener('change',renderFlowPicker);
const renderWoBeforeFlow=renderWo;
renderWo=function(){
 renderWoBeforeFlow();
 $('#woRows').querySelectorAll('[data-remove]').forEach(el=>el.onclick=()=>{if(removeLine(el.dataset.remove))renderWo()});
 if($('#woRows .empty'))$('#woRows .empty').textContent='Belum ada item. Centang item kontrak di tabel atas.';
 if(flow&&flow.step===2&&!$('#woCreate').hidden)renderFlowPicker();
};

// ---------- step 3: detail treatment (lokal sampai SAVE) ----------
const detailLabel={GROUP:'Group',JOINT:'Joint',ITEM:'Sub-item'};
function renderFlowStep3(){
 if(!wo.some(l=>l.id===flow.detailItem))flow.detailItem=wo[0]?.id||'';
 $('#flowDetailItem').innerHTML=wo.map(l=>`<option value="${l.id}">${escapeHtml(l.code+' — '+l.description+' ('+l.package+')')}</option>`).join('');
 $('#flowDetailItem').value=flow.detailItem;
 const mine=flow.details.filter(d=>d.lineId===flow.detailItem),groups=mine.filter(d=>d.kind!=='ITEM');
 const opt=list=>'<option value="">Pilih</option>'+list.map(g=>`<option value="${g.key}">${escapeHtml((g.kind==='JOINT'?'— ':'')+g.description)}</option>`).join('');
 const keepJ=$('#flowJointParent').value,keepI=$('#flowItemParent').value;
 $('#flowJointParent').innerHTML=opt(groups.filter(g=>g.kind==='GROUP'));$('#flowItemParent').innerHTML=opt(groups);
 if(groups.some(g=>g.key===keepJ))$('#flowJointParent').value=keepJ;
 if(groups.some(g=>g.key===keepI))$('#flowItemParent').value=keepI;
 const ordered=[];const walk=(parent,depth)=>flow.details.filter(d=>d.parentKey===parent).forEach(d=>{ordered.push([d,depth]);walk(d.key,depth+1)});walk(null,0);
 $('#flowDetailRows').innerHTML=ordered.map(([d,depth])=>{const line=wo.find(l=>l.id===d.lineId);return `<tr class="${d.lineId===flow.detailItem?'':'muted-row'}"><td>${escapeHtml(line?.code||'')}</td><td>${detailLabel[d.kind]}</td><td style="padding-left:${12+depth*18}px">${escapeHtml(d.kind==='GROUP'?d.category+' / '+d.description:d.description)}${d.savedId?' <small>tersimpan</small>':''}</td><td>${escapeHtml(d.unit||'')}</td><td class="num">${d.qty!=null?fmt(d.qty):''}</td><td>${d.savedId?'':`<button type="button" data-flow-del="${d.key}">Hapus</button>`}</td></tr>`}).join('')
  ||'<tr><td colspan="6" class="empty">Belum ada detail. Lewati langkah ini kalau belum perlu, lalu klik SAVE.</td></tr>';
 document.querySelectorAll('[data-flow-del]').forEach(b=>b.onclick=()=>{const drop=new Set([b.dataset.flowDel]);let grew=true;while(grew){grew=false;flow.details.forEach(d=>{if(d.parentKey&&drop.has(d.parentKey)&&!drop.has(d.key)){drop.add(d.key);grew=true}})}flow.details=flow.details.filter(d=>!drop.has(d.key));renderFlowStep3()});
 if(!dailyActivities.length&&opSession)loadActivities().catch(()=>{});
}
$('#flowDetailItem').onchange=e=>{flow.detailItem=e.target.value;renderFlowStep3()};
$('#flowCategory').addEventListener('input',()=>{
 const cat=$('#flowCategory').value.trim().toLowerCase(),row=dailyActivities.find(a=>!a.parent_id&&a.name.toLowerCase()===cat);
 $('#flowActivityOptions').innerHTML=row?dailyActivities.filter(a=>a.parent_id===row.id).map(a=>`<option value="${escapeHtml(a.name)}">`).join(''):'';
});
function addFlowDetail(d){
 $('#flowDetailError').textContent='';
 if(!flow.detailItem){$('#flowDetailError').textContent='Pilih item SMS dulu.';return false}
 flow.details.push({key:crypto.randomUUID(),lineId:flow.detailItem,parentKey:null,savedId:null,...d});renderFlowStep3();return true;
}
$('#flowAddGroup').onclick=()=>{const category=$('#flowCategory').value.trim(),description=$('#flowActivity').value.trim();if(!category||!description){$('#flowDetailError').textContent='Isi kategori dan nama aktivitas.';return}if(addFlowDetail({kind:'GROUP',category,description})){$('#flowCategory').value='';$('#flowActivity').value=''}};
$('#flowAddJoint').onclick=()=>{const parentKey=$('#flowJointParent').value,description=$('#flowJointName').value.trim();if(!parentKey){$('#flowDetailError').textContent='Pilih Group induk.';return}if(!description){$('#flowDetailError').textContent='Isi nama joint/instance.';return}if(addFlowDetail({kind:'JOINT',parentKey,description}))$('#flowJointName').value=''};
$('#flowAddItem').onclick=()=>{
 const parentKey=$('#flowItemParent').value,description=$('#flowItemDesc').value.trim(),unit=$('#flowItemUnit').value.trim(),raw=$('#flowItemQty').value.trim(),qty=raw?Number(raw):null;
 if(!parentKey){$('#flowDetailError').textContent='Pilih Group/Joint induk.';return}
 if(!description||!unit){$('#flowDetailError').textContent='Isi uraian dan satuan sub-item.';return}
 if(raw&&(!Number.isFinite(qty)||qty<=0)){$('#flowDetailError').textContent='Qty tidak valid.';return}
 if(addFlowDetail({kind:'ITEM',parentKey,description,unit,qty})){$('#flowItemDesc').value='';$('#flowItemQty').value=''}
};

// ---------- SAVE ----------
$('#flowSave').onclick=busy($('#flowSave'),async()=>{
 const err=validateStep(2);if(err){status(err[1]);await flowGoto(err[0],true);return}
 const progress=[];
 try{
  let woId=flow.mode==='existing'?flow.woId:flow.savedWoId;
  if(!woId){
   const r=await api('save_wo',{contractId:flow.contractId,number:$('#woNo').value.trim(),title:$('#woTitle').value.trim(),items:[]});
   woId=flow.savedWoId=r.woId;renderFlowStep1();
   progress.push('WO '+$('#woNo').value.trim());
  }
  const smsId=flow.smsId||flow.savedSmsId,a=flow.approval;
  const r=await api('save_sms',{woId,smsId,reviseFromId:smsId?null:flow.reviseFromId,
   documentDate:$('#smsDate').value,notificationNumber:$('#smsNotification').value.trim(),location:$('#smsLocation').value.trim(),
   contractor:$('#smsContractor').value.trim(),proposer:$('#smsProposer').value.trim(),proposerRole:$('#smsProposerRole').value.trim(),
   routingPropose:a.routing.propose,routingSupervisor:a.routing.supervisor,routingSuperintendent:a.routing.superintendent,routingRequester:a.routing.requester,
   status:a.status,approvalDate:a.approvalDate||null,evidenceBase64:null,evidenceFilename:null,
   items:wo.map(i=>({sourceId:i.sourceId,qty:i.qty,package:i.package}))});
  flow.savedSmsId=r.smsId;progress.push('SMS '+r.number+' Rev '+r.revision);
  const pending=flow.details.filter(d=>!d.savedId);
  if(pending.length){
   const fresh=await api('read_sms',{smsId:r.smsId});
   const smsItemFor=lineId=>{const l=wo.find(x=>x.id===lineId);return fresh.items.find(x=>x.commercial_item_id===l?.sourceId&&x.package_name===l?.package)?.id};
   const byKey=new Map(flow.details.map(d=>[d.key,d]));
   let n=0;
   for(const d of flow.details){
    if(d.savedId)continue;
    const smsItemId=smsItemFor(d.lineId);if(!smsItemId)throw Error('Item SMS untuk detail "'+d.description+'" gak ketemu.');
    const parentId=d.parentKey?byKey.get(d.parentKey)?.savedId:null;
    if(d.parentKey&&!parentId)throw Error('Induk detail "'+d.description+'" belum tersimpan.');
    let res;
    if(d.kind==='GROUP'){
     const cat=await dailyApi('add_activity',{name:d.category}),act=await dailyApi('add_activity',{parentId:cat.id,name:d.description});
     res=await dailyApi('add_detail_row',{smsItemId,rowKind:'GROUP',activityId:act.id,description:d.description});
    }else if(d.kind==='JOINT')res=await dailyApi('add_detail_row',{smsItemId,rowKind:'GROUP',parentId,description:d.description});
    else res=await dailyApi('add_detail_row',{smsItemId,rowKind:'ITEM',parentId,description:d.description,unit:d.unit,qty:d.qty});
    d.savedId=res.id;n++;
   }
   progress.push(n+' detail treatment');
   dailyActivities=[];
  }
  status('Tersimpan: '+progress.join(' → ')+'. Lihat di Daftar WO.');
  smsListCache.delete(woId);smsDataCache.delete(r.smsId);woTreeOpen.add(woId);smsTreeOpen.add(r.smsId);
  flow=null;wo=[];renderWo();woListRows=null;woShowView('list');
 }catch(e){
  status('SAVE berhenti: '+e.message+(progress.length?' (yang sudah tersimpan: '+progress.join(', ')+'). Perbaiki lalu klik SAVE lagi -- bagian yang sudah tersimpan gak akan dobel.':''));
  if(flow?.step===3)renderFlowStep3();
 }
});

// ---------- Daftar WO ----------
async function loadWoList(){
 if(!canWo())return;
 $('#woTree').innerHTML='<p class="empty">Memuat WO...</p>';
 const [wos,contracts]=await Promise.all([api('list_wo'),api('contracts')]);
 woContracts=new Map(contracts.map(c=>[c.id,c]));
 woListRows=wos.filter(w=>!isInternalWo(w));
 await Promise.all([...woTreeOpen].map(id=>loadSmsList(id).catch(()=>{})));
 await Promise.all([...smsTreeOpen].map(id=>loadSmsData(id).catch(()=>{})));
 renderWoTree();
 if(flow)renderFlowStep1();
}
async function loadSmsList(woId){if(!smsListCache.has(woId))smsListCache.set(woId,await api('list_sms',{woId}));return smsListCache.get(woId)}
async function loadSmsData(smsId){
 if(!smsDataCache.has(smsId)){const [data,details]=await Promise.all([api('read_sms',{smsId}),dailyApi('list_sms_details',{smsId})]);smsDataCache.set(smsId,{...data,details})}
 return smsDataCache.get(smsId);
}
function renderWoTree(){
 if(!woListRows){$('#woTree').innerHTML='<p class="empty">Belum dimuat.</p>';return}
 const q=$('#woListSearch').value.trim().toLowerCase();
 const rows=woListRows.filter(w=>{const c=woContracts.get(w.contract_id);return !q||(w.number+' '+(w.title||'')+' '+contractLabel(c)).toLowerCase().includes(q)});
 $('#woTree').innerHTML=rows.map(woNodeHtml).join('')||`<p class="empty">${woListRows.length?'Tidak ada WO yang cocok.':'Belum ada WO. Klik "+ Buat WO–SMS" untuk mulai.'}</p>`;
}
function woNodeHtml(w){
 const open=woTreeOpen.has(w.id),c=woContracts.get(w.contract_id),sms=smsListCache.get(w.id);
 const approve=w.status==='DRAFT'&&canApproveWo()?`<button type="button" data-wo-approve="${w.id}">Approval internal WO</button>`:'';
 return `<div class="wo-node${open?' open':''}" id="wo-node-${w.id}"><div class="wo-row"><button type="button" class="twisty" data-wo-toggle="${w.id}" aria-expanded="${open}" aria-label="Buka ${escapeHtml(w.number)}">${open?'▾':'▸'}</button><div class="wo-main" data-wo-toggle="${w.id}"><strong>${escapeHtml(w.number)}</strong>${w.revision&&w.revision!=='01'?` <small>Rev ${escapeHtml(w.revision)}</small>`:''} ${statusTag(w.status)}<div class="wo-sub">${escapeHtml(w.title||'-')} · ${escapeHtml(contractLabel(c))}</div></div><div class="wo-actions"><button type="button" class="primary" data-wo-add-sms="${w.id}">+ SMS baru</button><button type="button" data-wo-revise="${w.id}">Revisi WO</button>${approve}</div></div>
 ${open?`<div class="wo-children">${!sms?'<p class="empty">Memuat SMS...</p>':sms.length?sms.map(s=>smsNodeHtml(w,s)).join(''):'<p class="empty">Belum ada SMS di WO ini.</p>'}</div>`:''}</div>`;
}
function smsNodeHtml(w,s){
 const open=smsTreeOpen.has(s.id),data=smsDataCache.get(s.id);
 let body='';
 if(open){
  if(!data)body='<p class="empty">Memuat item...</p>';
  else{
   const locked=data.header.status==='APPROVED';
   const actions=`<div class="sms-actions">${locked?`<button type="button" data-sms-revise="${s.id}">Revisi SMS</button>`:`<button type="button" data-sms-edit="${s.id}">Edit SMS</button>`}<button type="button" data-sms-approval="${s.id}">Persetujuan end user</button><button type="button" data-sms-print="${s.id}">Cetak / PDF</button><button type="button" data-sms-excel="${s.id}">Export Excel</button></div>`;
   const items=data.items.map(it=>{
    const rows=data.details.filter(d=>d.sms_item_id===it.id);
    const walk=(parent,depth)=>rows.filter(d=>(d.parent_id||null)===parent).map(d=>`<li style="margin-left:${depth*16}px"><span class="kind">${d.row_kind==='GROUP'?(d.parent_id?'Joint':'Group'):'Sub-item'}</span> ${escapeHtml(d.description)}${d.row_kind==='ITEM'?` <small>${d.qty!=null?fmt(d.qty)+' ':''}${escapeHtml(d.unit||'')}${Number(d.progress_total)?' · progress '+fmt(d.progress_total):''}</small>`:''}</li>`+walk(d.id,depth+1)).join('');
    return `<div class="sms-item"><div class="sms-item-row"><div><strong>${escapeHtml(it.code_snapshot)}</strong> ${escapeHtml(it.description_snapshot)} <small>${escapeHtml(it.package_name)}</small></div><div class="num">${fmt(it.qty)} ${escapeHtml(it.unit_snapshot)}</div><button type="button" data-sms-breakdown="${it.id}" data-sms="${s.id}">Breakdown (${rows.length})</button></div>${rows.length?`<ul class="detail-tree">${walk(null,0)}</ul>`:''}</div>`;
   }).join('')||'<p class="empty">SMS ini belum punya item.</p>';
   body=actions+items;
  }
 }
 return `<div class="sms-node${open?' open':''}"><div class="sms-row" data-sms-toggle="${s.id}" data-wo="${w.id}"><span class="twisty">${open?'▾':'▸'}</span><strong>${escapeHtml(s.number)}</strong> <small>Rev ${escapeHtml(s.revision)}</small> ${statusTag(s.status)} <small>${escapeHtml(s.document_date||'')}</small></div>${open?`<div class="sms-body">${body}</div>`:''}</div>`;
}
$('#woListSearch').oninput=renderWoTree;
$('#woListRefresh').onclick=busy($('#woListRefresh'),async()=>{smsListCache.clear();smsDataCache.clear();await loadWoList();status('Daftar WO dimuat ulang.')});
$('#woTree').addEventListener('click',async e=>{
 const t=e.target.closest('button,[data-wo-toggle],[data-sms-toggle]');if(!t)return;
 try{
  if(t.dataset.woToggle){const id=t.dataset.woToggle;woTreeOpen.has(id)?woTreeOpen.delete(id):woTreeOpen.add(id);renderWoTree();if(woTreeOpen.has(id)){await loadSmsList(id);renderWoTree()}}
  else if(t.dataset.smsToggle){const id=t.dataset.smsToggle;smsTreeOpen.has(id)?smsTreeOpen.delete(id):smsTreeOpen.add(id);renderWoTree();if(smsTreeOpen.has(id)){await loadSmsData(id);renderWoTree()}}
  else if(t.dataset.woAddSms){const w=woListRows.find(x=>x.id===t.dataset.woAddSms);startFlow({woId:w.id,contractId:w.contract_id,step:2,label:'Menambah SMS baru ke '+w.number+'.'});woShowView('create')}
  else if(t.dataset.woApprove)await approveWoInternal(t.dataset.woApprove);
  else if(t.dataset.woRevise)await reviseWoPrompt(t.dataset.woRevise);
  else if(t.dataset.smsEdit||t.dataset.smsRevise)openSmsInFlow(t.dataset.smsEdit||t.dataset.smsRevise,!!t.dataset.smsRevise);
  else if(t.dataset.smsApproval)openApproval(t.dataset.smsApproval);
  else if(t.dataset.smsPrint)withSmsLoaded(t.dataset.smsPrint,()=>$('#printSms').onclick());
  else if(t.dataset.smsExcel)await withSmsLoaded(t.dataset.smsExcel,()=>$('#exportWoExcel').onclick());
  else if(t.dataset.smsBreakdown)await openBreakdown(t.dataset.smsBreakdown,t.dataset.sms);
 }catch(err){status(err.message)}
});
function woOfSms(smsId){const data=smsDataCache.get(smsId);return woListRows.find(w=>w.id===data?.header.wo_id)}
async function approveWoInternal(woId){
 const w=woListRows.find(x=>x.id===woId);
 if(!confirm('Approval internal WO '+w.number+'?\nIni approval di aplikasi (scope WO), terpisah dari persetujuan end user pada SMS.'))return;
 await api('approve_wo',{woId});status('WO '+w.number+' disetujui (approval internal).');await loadWoList();
}
// Nomor & Judul WO gak bisa diedit langsung di baris yang sama (save_wo cuma INSERT, gak ada
// UPDATE) -- perubahan Judul WO lewat REVISI baru, sama polanya kayak Revisi SMS. Nomor WO
// tetap sama, revision naik otomatis di backend (revise_wo), item yang udah ada dibawa ke
// revisi baru biar gak ilang.
async function reviseWoPrompt(woId){
 const w=woListRows.find(x=>x.id===woId);
 const newTitle=prompt('Revisi WO '+w.number+' (Rev '+w.revision+').\nNomor WO tetap sama, revision otomatis naik.\nItem yang sudah ada di WO ini akan dibawa ke revisi baru.\n\nJudul WO baru (kosongkan untuk pakai judul lama):',w.title||'');
 if(newTitle===null)return;
 if(!confirm('Buat revisi baru dari WO '+w.number+' Rev '+w.revision+'?'))return;
 const data=await api('read_wo',{woId});
 const items=(data.items||[]).map(i=>({sourceId:i.commercial_item_id,qty:Number(i.qty),package:i.package_name}));
 const r=await api('revise_wo',{sourceWoId:woId,title:newTitle.trim(),items});
 status('WO '+w.number+' berhasil direvisi jadi Rev '+r.revision+'.');
 smsListCache.delete(woId);smsDataCache.clear();
 await loadWoList();
}
function openSmsInFlow(smsId,revise){
 const data=smsDataCache.get(smsId),h=data.header,w=woOfSms(smsId);
 if(flow&&(wo.length||flow.details.length)&&!confirm('Ada isian WO–SMS yang belum di-SAVE. Buang dan buka SMS ini?'))return;
 startFlow({woId:w.id,contractId:w.contract_id,step:2,smsId:revise?null:smsId,reviseFromId:revise?smsId:null,
  approval:revise?undefined:{status:h.status,routing:{propose:h.routing_propose,supervisor:h.routing_supervisor,superintendent:h.routing_superintendent,requester:h.routing_requester},approvalDate:h.approval_date||''},
  header:{smsDate:revise?new Date().toISOString().slice(0,10):h.document_date,smsNotification:h.notification_number,smsLocation:h.location,smsContractor:h.contractor,smsProposer:h.proposer,smsProposerRole:h.proposer_role},
  label:revise?'Membuat revisi dari '+h.number+' Rev '+h.revision+'. Revisi baru dimulai sebagai DRAFT; breakdown ditambah ulang di langkah 3 atau dari Daftar WO.':'Mengedit '+h.number+' Rev '+h.revision+'. Breakdown yang sudah tersimpan diubah lewat tombol Breakdown di Daftar WO; langkah 3 cuma menambah yang baru.'});
 wo=data.items.map(i=>({id:crypto.randomUUID(),sourceId:i.commercial_item_id,code:i.code_snapshot,description:i.description_snapshot,unit:i.unit_snapshot,price:Number(i.unit_price_snapshot),rate:'STANDARD',package:i.package_name,qty:Number(i.qty),path:[]}));
 renderWo();woShowView('create');
}

// Cetak/Excel/Persetujuan memakai field global yang sama dengan form pembuatan -> simpan & kembalikan isiannya.
function snapshotForm(){return {wo,fields:Object.fromEntries([...smsIds,'woNo','woTitle','projectName','contractNo','contractType'].map(id=>[id,$('#'+id).value])),evidence:smsEvidence,routing:[...document.querySelectorAll('[data-route]')].map(e=>e.checked)}}
function restoreForm(s){wo=s.wo;Object.entries(s.fields).forEach(([id,v])=>$('#'+id).value=v);smsEvidence=s.evidence;document.querySelectorAll('[data-route]').forEach((e,i)=>e.checked=s.routing[i]);renderWo()}
function loadSmsIntoForm(smsId){
 const data=smsDataCache.get(smsId),w=woOfSms(smsId),c=woContracts.get(w.contract_id);
 setSms(smsRowToLocal(data.header));
 wo=data.items.map(i=>({id:i.id,sourceId:i.commercial_item_id,code:i.code_snapshot,description:i.description_snapshot,unit:i.unit_snapshot,price:Number(i.unit_price_snapshot),rate:'STANDARD',package:i.package_name,qty:Number(i.qty),path:[]}));
 $('#woNo').value=w.number;$('#woTitle').value=w.title||'';$('#projectName').value=c?.project_name||'';$('#contractNo').value=c?.number||'';
}
function withSmsLoaded(smsId,fn){
 const snap=snapshotForm();loadSmsIntoForm(smsId);
 let out;try{out=fn()}catch(err){restoreForm(snap);throw err}
 if(out&&typeof out.then==='function')return out.finally(()=>restoreForm(snap));
 restoreForm(snap);
}
function openApproval(smsId){
 approvalSms=smsId;approvalSnapshot=snapshotForm();loadSmsIntoForm(smsId);
 const h=smsDataCache.get(smsId).header;
 $('#approvalContext').textContent=woOfSms(smsId).number+' · '+h.number+' Rev '+h.revision;
 $('#approvalError').textContent='';
 const locked=h.status==='APPROVED';
 $('#smsApprovalDialog').querySelectorAll('input,select').forEach(el=>{if(!['smsNumber','smsRevision'].includes(el.id))el.disabled=locked});
 $('#smsRemoveEvidence').disabled=locked;$('#approvalSave').hidden=locked;
 $('#smsApprovalDialog').showModal();
}
function closeApproval(){if(!approvalSnapshot)return;restoreForm(approvalSnapshot);approvalSnapshot=null;$('#smsApprovalDialog').querySelectorAll('input,select,button').forEach(el=>el.disabled=false);$('#approvalSave').hidden=false;approvalSms=null}
$('#approvalClose').onclick=()=>{$('#smsApprovalDialog').close();closeApproval()};
$('#smsApprovalDialog').addEventListener('close',closeApproval);
$('#approvalSave').onclick=busy($('#approvalSave'),async()=>{
 const smsId=approvalSms,data=smsDataCache.get(smsId),h=data.header,w=woOfSms(smsId);
 const want=$('#smsApproval').value,d=getSms();
 $('#approvalError').textContent='';
 if(want==='APPROVED'&&!Object.values(d.routing).every(Boolean)){$('#approvalError').textContent='Centang keempat routing sebelum menandai APPROVED.';return}
 if(want==='APPROVED'&&!d.evidence){$('#approvalError').textContent='Lampirkan bukti PDF sebelum menandai APPROVED.';return}
 if(want==='APPROVED'&&!confirm('Tandai '+h.number+' disetujui end user? Setelah ini SMS terkunci.'))return;
 const original=h.evidence_data?'data:application/pdf;base64,'+h.evidence_data:null,changed=d.evidence&&d.evidence.data!==original;
 try{
  await api('save_sms',{woId:w.id,smsId,documentDate:h.document_date,notificationNumber:h.notification_number,location:h.location,contractor:h.contractor,proposer:h.proposer,proposerRole:h.proposer_role,
   routingPropose:d.routing.propose,routingSupervisor:d.routing.supervisor,routingSuperintendent:d.routing.superintendent,routingRequester:d.routing.requester,
   status:want,approvalDate:d.approvalDate||null,evidenceBase64:changed?d.evidence.data.replace(/^data:application\/pdf;base64,/,''):null,evidenceFilename:changed?d.evidence.name:null,
   items:data.items.map(i=>({sourceId:i.commercial_item_id,qty:i.qty,package:i.package_name}))});
 }catch(err){$('#approvalError').textContent=err.message;return}
 smsDataCache.delete(smsId);smsListCache.delete(w.id);
 $('#smsApprovalDialog').close();closeApproval();
 status('Persetujuan end user tersimpan: '+h.number+' → '+want+'.');
 await loadWoList();
});
let breakdownSms=null;
async function openBreakdown(smsItemId,smsId){
 const it=smsDataCache.get(smsId).items.find(i=>i.id===smsItemId);
 const done=openDetailDialog(smsItemId);
 $('#detailContext').textContent=it.code_snapshot+' — '+it.description_snapshot+' ('+fmt(it.qty)+' '+it.unit_snapshot+')';
 await done;breakdownSms=smsId;
}
// Setelah dialog Breakdown ditutup, segarkan tree SMS tsb biar jumlah breakdown ikut berubah.
async function refreshBreakdownSms(){const smsId=breakdownSms;if(!smsId)return;breakdownSms=null;smsDataCache.delete(smsId);await loadSmsData(smsId).catch(()=>{});renderWoTree()}
$('#detailDialog').addEventListener('close',refreshBreakdownSms);$('#closeDetail').addEventListener('click',refreshBreakdownSms);

// ---------- integrasi dengan bagian lain ----------
// Project List "Buka WO" -> tampilkan WO tsb di Daftar WO.
async function displayWo(id){
 tab('wo');woShowView('list');woTreeOpen.add(id);
 if(!woListRows)await loadWoList();else{await loadSmsList(id);renderWoTree()}
 $('#wo-node-'+id)?.scrollIntoView({block:'center',behavior:'smooth'});
}
// Master "Tambah pilihan ke SMS": item master Supabase langsung jadi item SMS di form pembuatan.
const addWoFromMaster=$('#addWo').onclick;
$('#addWo').onclick=()=>{
 if(!remoteContractId){status('Simpan atau muat master dari Supabase dulu sebelum menyusun SMS.');return}
 if(!canWo()){status('Akun ini gak punya akses Operational WO.');return}
 if(!flow||flow.contractId!==remoteContractId)startFlow({contractId:remoteContractId,keepItems:true});
 addWoFromMaster();
 woShowView('create');flowGoto(flow.step,true);
 status('Item ditambahkan ke SMS. Lengkapi Nomor/Nama WO di langkah 1, lalu lanjut.');
};
const tabBeforeWoFlow=tab;
tab=function(name){
 tabBeforeWoFlow(name);
 if(name!=='wo')return;
 $('#contractContext').hidden=true;$('#contractBinding').hidden=true;
 $('#pageDescription').textContent='Create WO → Create SMS → Detail treatment (opsional) → SAVE. Semua yang tersimpan ada di Daftar WO.';
 woFlowAuthUi();
 if($('#woCreate').hidden&&canWo()&&!woListRows)loadWoList().catch(err=>status(err.message));
};
woFlowAuthUi();
