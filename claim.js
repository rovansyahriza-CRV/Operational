'use strict';
// Tab "Klaim Release" di progress.html -- geser progress & resource yang udah tercatat di
// WO-Internal (Draft) ke WO-Released buat tagihan. Numpang login/WO(#progressWo)/api/
// dailyApi/busy/status/$/escapeHtml/fmt dari progress.js, activeTab/TABS dari checkin.js.

let claimTargetWoList=[];
let claimCommercialItems=[];
let claimProgressRows=[];
let claimResourceData={manpower:[],material:[],equipment:[]};

function round2(n){return Math.round(Number(n||0)*100)/100}

async function enterClaim(){
 const woId=$('#progressWo').value;
 $('#claimResourceList').innerHTML='<p class="empty">Pilih WO &amp; rentang tanggal, lalu Muat resource.</p>';
 $('#claimHistoryList').innerHTML='<p class="empty">Pilih WO Released tujuan buat lihat riwayat klaim.</p>';
 if(!woId){
  $('#claimProgressList').innerHTML='<p class="empty">Pilih WO dulu di atas.</p>';
  $('#claimTargetWo').innerHTML='<option value="">Pilih WO tujuan</option>';
  $('#claimSubmit').disabled=true;
  return;
 }
 await loadClaimTargetWoOptions();
 await loadClaimableProgress(woId);
}

async function loadClaimTargetWoOptions(){
 try{
  const rows=(await api('list_wo')).filter(w=>w.release_role==='RELEASED');
  claimTargetWoList=rows;
  $('#claimTargetWo').innerHTML='<option value="">Pilih WO tujuan</option>'+rows.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' / '+w.contract_number+' / '+w.status)}</option>`).join('');
 }catch(err){status('Gagal memuat daftar WO: '+err.message)}
}

async function loadClaimableProgress(woId){
 const wrap=$('#claimProgressList');
 wrap.innerHTML='<p class="empty">Memuat...</p>';
 try{
  claimProgressRows=await dailyApi('list_claimable_progress',{sourceWoId:woId});
  renderClaimProgress();
 }catch(err){wrap.innerHTML='<p class="empty">Gagal memuat: '+escapeHtml(err.message)+'</p>'}
}

function renderClaimProgress(){
 const wrap=$('#claimProgressList');
 if(!claimProgressRows.length){wrap.innerHTML='<p class="empty">Gak ada progress yang bisa diklaim di WO ini -- semua udah diklaim, atau belum ada progress tercatat.</p>';return}
 wrap.innerHTML=claimProgressRows.map(r=>{
  const balance=round2(Number(r.total_progress)-Number(r.total_claimed));
  return `<div class="claim-row" data-sms-item="${r.sms_item_id}" data-commercial-item="${r.commercial_item_id||''}">
   <div><strong>${escapeHtml(r.item_code||'')}</strong> ${escapeHtml(r.item_description||'')}</div>
   <p class="hint">Total progress: ${fmt(r.total_progress)} ${escapeHtml(r.unit||'')} &middot; Sudah diklaim: ${fmt(r.total_claimed)} &middot; Sisa: <strong>${fmt(balance)}</strong></p>
   <label>Qty diklaim sekarang</label>
   <input type="number" class="claim-qty" min="0" max="${balance}" step="any" placeholder="0">
   <label>Item tujuan di WO Released</label>
   <select class="claim-target-item"><option value="">-- pilih WO Released tujuan dulu --</option></select>
  </div>`;
 }).join('');
 wrap.querySelectorAll('.claim-qty').forEach(el=>el.addEventListener('input',updateClaimSubmitState));
}

$('#claimTargetWo').addEventListener('change',async()=>{
 const woId=$('#claimTargetWo').value;
 const rowEls=[...document.querySelectorAll('#claimProgressList .claim-row')];
 if(!woId){
  rowEls.forEach(el=>{el.querySelector('.claim-target-item').innerHTML='<option value="">-- pilih WO Released tujuan dulu --</option>'});
  $('#claimHistoryList').innerHTML='<p class="empty">Pilih WO Released tujuan buat lihat riwayat klaim.</p>';
  updateClaimSubmitState();
  return;
 }
 try{
  claimCommercialItems=await dailyApi('list_release_target_items',{targetWoId:woId});
 }catch(err){claimCommercialItems=[];status('Gagal memuat item SMS WO tujuan: '+err.message)}
 rowEls.forEach(el=>{
  const defaultId=el.dataset.commercialItem;
  const options=claimCommercialItems.map(i=>`<option value="${i.commercialItemId}" ${i.commercialItemId===defaultId?'selected':''}>${escapeHtml(i.code||'')} ${escapeHtml(i.description||'')}</option>`).join('');
  el.querySelector('.claim-target-item').innerHTML=options?'<option value="">-- pilih item --</option>'+options:'<option value="">WO ini belum punya item di SMS -- tambahkan lewat "+ Buat WO-SMS" dulu</option>';
  if(defaultId&&claimCommercialItems.some(i=>i.commercialItemId===defaultId))el.querySelector('.claim-target-item').value=defaultId;
 });
 loadClaimHistory(woId);
 updateClaimSubmitState();
});

async function loadClaimHistory(targetWoId){
 const wrap=$('#claimHistoryList');
 wrap.innerHTML='<p class="empty">Memuat...</p>';
 try{
  const [progressRows,resourceRows]=await Promise.all([
   dailyApi('list_wo_release_claims',{targetWoId}),
   dailyApi('list_wo_release_resource_claims',{targetWoId})
  ]);
  if(!progressRows.length&&!resourceRows.length){wrap.innerHTML='<p class="empty">Belum ada klaim ke WO ini.</p>';return}
  const progressHtml=progressRows.map(r=>`<div class="claim-row"><div>${escapeHtml(r.source_item_description||'')} <span class="hint">(dari ${escapeHtml(r.source_wo_number||'-')})</span> → <strong>${escapeHtml(r.target_item_description||'')}</strong></div><p class="hint">Qty: ${fmt(r.qty)} &middot; ${escapeHtml(r.claim_date||'')} &middot; oleh ${escapeHtml(r.claimed_by_name||'-')}${r.notes?' &middot; '+escapeHtml(r.notes):''}</p></div>`).join('');
  const resourceLabel={MANPOWER:'Manpower',MATERIAL:'Material',EQUIPMENT:'Alat'};
  const resourceHtml=resourceRows.map(r=>`<div class="claim-row"><div>${resourceLabel[r.resource_type]||r.resource_type}</div><p class="hint">Portion: ${fmt(r.portion)} &middot; ${escapeHtml(r.claim_date||'')} &middot; oleh ${escapeHtml(r.claimed_by_name||'-')}</p></div>`).join('');
  wrap.innerHTML=progressHtml+resourceHtml;
 }catch(err){wrap.innerHTML='<p class="empty">Gagal memuat riwayat: '+escapeHtml(err.message)+'</p>'}
}

$('#claimLoadResources').addEventListener('click',busy($('#claimLoadResources'),async()=>{
 const woId=$('#progressWo').value;
 if(!woId){status('Pilih WO dulu.');return}
 const startDate=$('#claimStartDate').value||null,endDate=$('#claimEndDate').value||null;
 claimResourceData=await dailyApi('list_claimable_resources',{sourceWoId:woId,startDate,endDate});
 renderClaimResources();
}));

function renderClaimResources(){
 const wrap=$('#claimResourceList');
 const row=(type,id,label,balance,unit)=>`<div class="claim-row" data-resource-type="${type}" data-resource-id="${id}">
  <div>${escapeHtml(label)}</div>
  <p class="hint">Sisa bisa diklaim: <strong>${fmt(balance)} ${escapeHtml(unit)}</strong></p>
  <label>Portion diklaim sekarang</label>
  <input type="number" class="claim-portion" min="0" max="${balance}" step="any" placeholder="0" value="${balance}">
 </div>`;
 let html='';
 const mp=claimResourceData.manpower||[];
 if(mp.length)html+='<h3 class="mu-subheading">Manpower</h3>'+mp.map(m=>row('MANPOWER',m.id,(m.employee_name||'-')+' -- checkin '+(m.check_in_at?new Date(m.check_in_at).toLocaleString('id-ID'):'-'),round2(Number(m.total_hours)-Number(m.claimed_hours)),'jam')).join('');
 const mat=claimResourceData.material||[];
 if(mat.length)html+='<h3 class="mu-subheading">Material</h3>'+mat.map(m=>row('MATERIAL',m.id,(m.item_description||'-')+' -- '+(m.usage_date||''),round2(Number(m.total_qty)-Number(m.claimed_qty)),m.unit||'')).join('');
 const eq=claimResourceData.equipment||[];
 if(eq.length)html+='<h3 class="mu-subheading">Alat / Equipment</h3>'+eq.map(m=>row('EQUIPMENT',m.id,(m.item_description||'-')+' -- checkin '+(m.check_in_at?new Date(m.check_in_at).toLocaleString('id-ID'):'-'),round2(Number(m.total_hours)-Number(m.claimed_hours)),'jam')).join('');
 wrap.innerHTML=html||'<p class="empty">Gak ada resource yang bisa diklaim di rentang tanggal ini.</p>';
 wrap.querySelectorAll('.claim-portion').forEach(el=>el.addEventListener('input',updateClaimSubmitState));
}

function updateClaimSubmitState(){
 const hasTargetWo=!!$('#claimTargetWo').value;
 const hasProgress=[...document.querySelectorAll('#claimProgressList .claim-row')].some(el=>Number(el.querySelector('.claim-qty').value)>0&&el.querySelector('.claim-target-item').value);
 const hasResource=[...document.querySelectorAll('#claimResourceList .claim-row')].some(el=>Number(el.querySelector('.claim-portion').value)>0);
 $('#claimSubmit').disabled=!(hasTargetWo&&(hasProgress||hasResource));
}
document.addEventListener('input',e=>{if(e.target.matches('.claim-qty,.claim-portion')||e.target.matches('.claim-target-item'))updateClaimSubmitState()});
document.addEventListener('change',e=>{if(e.target.matches('.claim-target-item'))updateClaimSubmitState()});

$('#claimSubmit').onclick=busy($('#claimSubmit'),async()=>{
 const targetWoId=$('#claimTargetWo').value;
 if(!targetWoId){status('Pilih WO Released tujuan dulu.');return}

 const progressClaims=[];
 document.querySelectorAll('#claimProgressList .claim-row').forEach(el=>{
  const qty=Number(el.querySelector('.claim-qty').value);
  const targetItem=el.querySelector('.claim-target-item').value;
  if(qty>0&&targetItem)progressClaims.push({sourceSmsItemId:el.dataset.smsItem,targetWoId,targetCommercialItemId:targetItem,qty});
 });

 const resourceClaims=[];
 document.querySelectorAll('#claimResourceList .claim-row').forEach(el=>{
  const portion=Number(el.querySelector('.claim-portion').value);
  if(portion>0)resourceClaims.push({resourceType:el.dataset.resourceType,resourceId:el.dataset.resourceId,targetWoId,portion});
 });

 if(!progressClaims.length&&!resourceClaims.length){status('Isi minimal 1 qty progress atau 1 portion resource.');return}

 await dailyApi('claim_progress_to_release',{progressClaims,resourceClaims});
 status('Klaim berhasil disimpan ke '+(claimTargetWoList.find(w=>w.id===targetWoId)?.number||'WO tujuan')+'.');
 await loadClaimableProgress($('#progressWo').value);
 $('#claimResourceList').innerHTML='<p class="empty">Pilih WO &amp; rentang tanggal, lalu Muat resource.</p>';
 loadClaimHistory(targetWoId);
});
