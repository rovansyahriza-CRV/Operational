'use strict';
// Browser-safe publishable key. No service-role credential belongs in this file.
const OP_CONFIG={url:'https://nhmpwjriextmbotmvvbu.supabase.co',key:'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz'};
const $=s=>document.querySelector(s);
const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=n=>n==null?'—':Number(n).toLocaleString('id-ID',{maximumFractionDigits:2});
let opSession=null;
function status(s){$('#status').textContent=s}
async function rpc(name,params){const response=await fetch(OP_CONFIG.url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:OP_CONFIG.key,'Content-Type':'application/json'},body:JSON.stringify(params)});const body=await response.json().catch(()=>null);if(!response.ok)throw Error(body?.message||'Koneksi gagal ('+response.status+')');return body}
async function api(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_api',{p_token:opSession.token,p_action:action,p_data:data})}
async function dailyApi(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_daily_report',{p_token:opSession.token,p_action:action,p_data:data})}
async function manpowerApi(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_manpower',{p_token:opSession.token,p_action:action,p_data:data})}
function busy(button,fn){return async()=>{button.disabled=true;try{await fn()}catch(err){status(err.message)}finally{button.disabled=false}}}
const WEATHER_LABELS={CERAH:'Cerah',BERAWAN:'Berawan',HUJAN_RINGAN:'Hujan Ringan',HUJAN_LEBAT:'Hujan Lebat'};
function compressImage(file,maxDim=1024,quality=0.6){
 return new Promise((resolve,reject)=>{
  const reader=new FileReader();
  reader.onload=()=>{
   const img=new Image();
   img.onload=()=>{
    let w=img.width,h=img.height;
    if(w>maxDim||h>maxDim){const scale=maxDim/Math.max(w,h);w=Math.round(w*scale);h=Math.round(h*scale)}
    const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
    canvas.getContext('2d').drawImage(img,0,0,w,h);
    resolve(canvas.toDataURL('image/jpeg',quality));
   };
   img.onerror=()=>reject(Error('File bukan gambar yang valid.'));
   img.src=reader.result;
  };
  reader.onerror=()=>reject(Error('Gagal membaca file.'));
  reader.readAsDataURL(file);
 });
}

let employeeSearchTimer,employeeSearchVersion=0;
$('#employeeSearch').addEventListener('input',()=>{
 clearTimeout(employeeSearchTimer);const version=++employeeSearchVersion,query=$('#employeeSearch').value.trim();
 $('#employeeId').value='';$('#employeeSuggestions').replaceChildren();$('#employeeSuggestions').hidden=true;
 $('#employeeSearchStatus').textContent=query.length<2?'Ketik minimal 2 huruf nama.':'Mencari karyawan...';
 if(query.length<2)return;
 employeeSearchTimer=setTimeout(async()=>{
  try{
   const rows=await rpc('search_active_karyawan',{p_query:query});
   if(version!==employeeSearchVersion)return;
   const matches=Array.isArray(rows)?rows.slice(0,8):[];
   $('#employeeSearchStatus').textContent=matches.length?'Pilih nama yang sesuai.':'Nama tidak ditemukan.';
   for(const row of matches){
    if(!/^\d+$/.test(String(row.id))||typeof row.nama!=='string')continue;
    const button=document.createElement('button');
    button.type='button';button.textContent=row.nama+' (ID: '+row.id+')';
    button.onclick=()=>{++employeeSearchVersion;$('#employeeId').value=String(row.id);$('#employeeSearch').value=row.nama+' (ID: '+row.id+')';$('#employeeSuggestions').hidden=true;$('#employeeSuggestions').replaceChildren();$('#employeeSearchStatus').textContent='Karyawan dipilih. Masukkan password akun.';$('#employeePassword').focus()};
    $('#employeeSuggestions').append(button);
   }
   $('#employeeSuggestions').hidden=!$('#employeeSuggestions').children.length;
  }catch(err){if(version===employeeSearchVersion)$('#employeeSearchStatus').textContent='Pencarian gagal. Ketik ulang untuk mencoba lagi.'}
 },300);
});

$('#loginForm').onsubmit=async e=>{
 e.preventDefault();
 const b=$('#loginSubmit');b.disabled=true;$('#loginError').textContent='';
 try{
  const id=$('#employeeId').value.trim();
  if(!/^\d+$/.test(id))throw Error('Pilih nama karyawan dari hasil pencarian.');
  const result=await rpc('op_login',{p_id:id,p_password:$('#employeePassword').value});
  if(result?.error)throw Error(result.error);
  const allowed=(result.pic||[]).some(x=>['all','operational wo'].includes(String(x).trim().toLowerCase()));
  if(!allowed)throw Error('Akun ini belum diizinkan akses Operational WO / Daily Progress.');
  opSession=result;
  $('#employeePassword').value='';
  $('#loginSection').hidden=true;$('#progressSection').hidden=false;
  $('#identity').textContent='Masuk: '+opSession.name;$('#logout').hidden=false;
  status('Login berhasil.');
 }catch(err){$('#loginError').textContent=err.message;$('#employeePassword').value=''}
 finally{b.disabled=false}
};
$('#logout').onclick=async()=>{
 try{if(opSession)await rpc('op_logout',{p_token:opSession.token})}catch(err){}
 opSession=null;
 $('#loginSection').hidden=false;$('#progressSection').hidden=true;
 $('#identity').textContent='Belum login';$('#logout').hidden=true;
 $('#progressWo').innerHTML='<option value="">Pilih WO tersimpan</option>';
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>';$('#progressSms').disabled=true;
 $('#progressLoadSms').disabled=true;$('#progressLoadDetails').disabled=true;$('#progressSaveAll').disabled=true;$('#progressViewReport').disabled=true;
 $('#progressSearch').value='';batchDetails=[];keptValues={};itemWeather={};stagedPhotos={};
 $('#progressBatchList').innerHTML='<p class="empty">Pilih WO dan SMS, lalu muat breakdown.</p>';
 $('#progressManpowerList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat siapa yang check-in.</p>';
 $('#progressMaterialList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat material yang diterima.</p>';
 $('#progressMaterialUsageList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat pemakaian material.</p>';
 $('#materialUsageItem').innerHTML='<option value="">Pilih WO dulu</option>';$('#materialUsageItem').disabled=true;
 $('#materialUsageQty').value='';$('#materialUsageQty').disabled=true;$('#btnSaveMaterialUsage').disabled=true;
 $('#materialUsageStatus').textContent='';materialBalanceRows=[];lastMaterialUsageRows=[];
 showEditMode();
 status('Sudah keluar.');
};

// Manpower dan Daily Progress sama-sama di-scope ke WO+tanggal -- gak perlu foreign key baru,
// tinggal query check-in yang jatuh di tanggal yang sama buat WO yang sama.
function localDateOf(isoTimestamp){const d=new Date(isoTimestamp);return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')}
let lastManpowerRows=[];
function groupManpowerByKualifikasi(rows){
 const map=new Map();
 for(const r of rows){
  const key=r.kualifikasi||'Tanpa klasifikasi';
  if(!map.has(key))map.set(key,[]);
  map.get(key).push(r);
 }
 return [...map.entries()].map(([kualifikasi,members])=>({kualifikasi,members})).sort((a,b)=>a.kualifikasi.localeCompare(b.kualifikasi));
}
async function refreshManpowerForDate(){
 const woId=$('#progressWo').value,date=$('#progressBatchDate').value;
 lastManpowerRows=[];
 if(!woId||!date){$('#progressManpowerList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat siapa yang check-in.</p>';return}
 try{
  const rows=await manpowerApi('list_checkins',{woId});
  const dayRows=rows.filter(r=>localDateOf(r.check_in_at)===date);
  lastManpowerRows=dayRows;
  const groups=groupManpowerByKualifikasi(dayRows);
  $('#progressManpowerList').innerHTML=groups.length?groups.map(g=>`<div class="mp-class-group">
   <div class="mp-class-title">${escapeHtml(g.kualifikasi)} (${g.members.length})</div>
   ${g.members.map(r=>`<div class="mp-card"><span class="mp-name">${escapeHtml(r.employee_name)}</span><span class="mp-time">${fmt(r.hours)} jam</span></div>`).join('')}
  </div>`).join('')+`<p class="hint">Total ${dayRows.length} orang.</p>`:'<p class="empty">Belum ada yang check-in di WO ini pada tanggal tsb.</p>';
 }catch(err){$('#progressManpowerList').innerHTML='<p class="empty">Gagal memuat data manpower: '+escapeHtml(err.message)+'</p>'}
}

// Material End User Receiving juga di-scope ke WO+tanggal (lewat endUserReceiving.woID +
// ConfirmedDate) -- ditampilkan langsung di halaman input, konsisten kayak Manpower, bukan
// cuma di Daily Report. lastMaterialRows dipakai ulang pas bikin Daily Report/PDF biar gak
// nembak query 2x.
let lastMaterialRows=[];
async function refreshMaterialForDate(){
 const woId=$('#progressWo').value,date=$('#progressBatchDate').value;
 lastMaterialRows=[];
 if(!woId||!date){$('#progressMaterialList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat material yang diterima.</p>';return}
 try{
  const rows=await dailyApi('list_material_received',{woId,reportDate:date});
  lastMaterialRows=rows;
  $('#progressMaterialList').innerHTML=rows.length?rows.map(m=>`<div class="mp-card"><span class="mp-name">${escapeHtml(m.itemDescription)} — ${fmt(m.qty)} ${escapeHtml(m.unit||'')}</span><span class="mp-time">${escapeHtml(m.issuedByName||'-')} → ${escapeHtml(m.confirmedByName||'-')}</span></div>`).join(''):'<p class="empty">Belum ada material yang diserahkan di WO ini pada tanggal tsb.</p>';
 }catch(err){$('#progressMaterialList').innerHTML='<p class="empty">Gagal memuat data material: '+escapeHtml(err.message)+'</p>'}
}
// Material Digunakan: balance (sisa = diterima - dikembalikan - dipakai) di-scope ke WO aja
// (material bisa dipakai berhari-hari), sedangkan histori pemakaian di-scope ke WO+tanggal
// kayak manpower/material diterima.
let materialBalanceRows=[];
function renderMaterialUsageItemOptions(){
 const sel=$('#materialUsageItem');
 sel.innerHTML='<option value="">Pilih item</option>'+materialBalanceRows.map(m=>`<option value="${m.confirmationId}">${escapeHtml(m.itemDescription)} — sisa ${fmt(m.balance)} ${escapeHtml(m.unit||'')}</option>`).join('');
}
async function refreshMaterialBalance(){
 const woId=$('#progressWo').value;
 materialBalanceRows=[];
 $('#materialUsageItem').disabled=true;$('#materialUsageQty').disabled=true;$('#btnSaveMaterialUsage').disabled=true;
 if(!woId){renderMaterialUsageItemOptions();$('#materialUsageItem').innerHTML='<option value="">Pilih WO dulu</option>';return}
 try{
  materialBalanceRows=await dailyApi('list_material_balance',{woId});
  renderMaterialUsageItemOptions();
  const has=materialBalanceRows.length>0;
  $('#materialUsageItem').disabled=!has;$('#materialUsageQty').disabled=!has;$('#btnSaveMaterialUsage').disabled=!has;
  if(!has)$('#materialUsageItem').innerHTML='<option value="">Tidak ada sisa material buat WO ini</option>';
 }catch(err){$('#materialUsageStatus').textContent='Gagal memuat sisa material: '+err.message}
}
let lastMaterialUsageRows=[];
async function refreshMaterialUsageForDate(){
 const woId=$('#progressWo').value,date=$('#progressBatchDate').value;
 lastMaterialUsageRows=[];
 if(!woId||!date){$('#progressMaterialUsageList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat pemakaian material.</p>';return}
 try{
  const rows=await dailyApi('list_material_usage',{woId,reportDate:date});
  lastMaterialUsageRows=rows;
  $('#progressMaterialUsageList').innerHTML=rows.length?rows.map(m=>`<div class="mp-card"><span class="mp-name">${escapeHtml(m.itemDescription)} — ${fmt(m.qty)} ${escapeHtml(m.unit||'')}</span><span class="mp-time">${escapeHtml(m.recordedByName||'-')}</span></div>`).join(''):'<p class="empty">Belum ada pemakaian material dicatat di WO ini pada tanggal tsb.</p>';
 }catch(err){$('#progressMaterialUsageList').innerHTML='<p class="empty">Gagal memuat data pemakaian: '+escapeHtml(err.message)+'</p>'}
}
$('#btnSaveMaterialUsage').onclick=busy($('#btnSaveMaterialUsage'),async()=>{
 const woId=$('#progressWo').value,date=$('#progressBatchDate').value,confirmationId=$('#materialUsageItem').value,qty=Number($('#materialUsageQty').value);
 $('#materialUsageStatus').textContent='';
 if(!woId||!confirmationId){$('#materialUsageStatus').textContent='Pilih item dulu.';return}
 if(!date){$('#materialUsageStatus').textContent='Isi tanggal dulu.';return}
 if(!Number.isFinite(qty)||qty<=0){$('#materialUsageStatus').textContent='Qty tidak valid.';return}
 try{
  await dailyApi('save_material_usage',{confirmationId,woId,reportDate:date,qty});
  $('#materialUsageQty').value='';
  await refreshMaterialBalance();
  await refreshMaterialUsageForDate();
  $('#materialUsageStatus').textContent='Pemakaian tersimpan.';
 }catch(err){$('#materialUsageStatus').textContent='Gagal: '+err.message}
});
$('#progressBatchDate').addEventListener('change',async()=>{
 await refreshManpowerForDate();
 await refreshMaterialForDate();
 await refreshMaterialUsageForDate();
 if(batchDetails.length){await loadItemWeather();renderBatchList()}
});

let batchDetails=[];
function pathFor(rows,row){const names=[];let cur=row;while(cur){names.unshift(cur.description);cur=cur.parent_id?rows.find(r=>r.id===cur.parent_id):null}return names.join(' / ')}

$('#progressLoadWos').onclick=busy($('#progressLoadWos'),async()=>{
 const rows=await api('list_wo');
 $('#progressWo').innerHTML='<option value="">Pilih WO tersimpan</option>'+rows.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' / '+w.contract_number+' / '+w.status)}</option>`).join('');
 $('#progressSms').disabled=true;$('#progressLoadSms').disabled=true;
 status(rows.length+' WO tersedia.');
});
$('#progressWo').addEventListener('change',async()=>{
 const woId=$('#progressWo').value;
 $('#progressLoadSms').disabled=!woId;
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>';$('#progressSms').disabled=true;
 $('#progressLoadDetails').disabled=true;$('#progressSaveAll').disabled=true;
 $('#reportHeaderDetails').hidden=!woId;
 if(woId)await loadReportHeader();
 refreshManpowerForDate();
 refreshMaterialForDate();
 refreshMaterialBalance();
 refreshMaterialUsageForDate();
});

// --- Detail Laporan (header proyek: Owner/Lokasi/Kontraktor/Konsultan/No.SPK) --
// isi sekali per WO, disimpan ke Supabase (operational.projects lewat WO->contract->project).
async function loadReportHeader(){
 const woId=$('#progressWo').value;if(!woId)return;
 $('#reportHeaderStatus').textContent='';
 try{
  const h=await dailyApi('get_report_header',{woId});
  $('#rhClient').value=h.client||'';$('#rhLocation').value=h.location||'';
  $('#rhContractor').value=h.contractorName||'';$('#rhConsultant').value=h.supervisorConsultant||'';
  $('#rhContractNumber').value=h.contractNumber||'';$('#rhStart').value=h.startDate||'';$('#rhEnd').value=h.endDate||'';
 }catch(err){$('#reportHeaderStatus').textContent='Gagal memuat: '+err.message}
}
$('#reportHeaderSave').onclick=busy($('#reportHeaderSave'),async()=>{
 const woId=$('#progressWo').value;if(!woId){status('Pilih WO dulu.');return}
 await dailyApi('save_report_header',{
  woId,client:$('#rhClient').value.trim(),location:$('#rhLocation').value.trim(),
  contractorName:$('#rhContractor').value.trim(),supervisorConsultant:$('#rhConsultant').value.trim(),
  contractNumber:$('#rhContractNumber').value.trim(),startDate:$('#rhStart').value,endDate:$('#rhEnd').value
 });
 $('#reportHeaderStatus').textContent='Tersimpan.';
});
$('#progressLoadSms').onclick=busy($('#progressLoadSms'),async()=>{
 const woId=$('#progressWo').value;if(!woId)return;
 const rows=await api('list_sms',{woId});
 $('#progressSms').disabled=false;
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>'+rows.map(r=>`<option value="${r.id}">${escapeHtml(r.number+' Rev '+r.revision+' · '+r.status)}</option>`).join('');
 status(rows.length+' SMS tersedia untuk WO ini.');
});
$('#progressSms').addEventListener('change',()=>{$('#progressLoadDetails').disabled=!$('#progressSms').value;$('#progressViewReport').disabled=true});
const SHIFTS=['PAGI','SIANG','LEMBUR'];
const SHIFT_LABELS={PAGI:'Pagi (08:00–12:00)',SIANG:'Siang (13:00–17:00)',LEMBUR:'Lembur (18:00–21:30)'};
let keptValues={},itemWeather={},stagedPhotos={};
function showEditMode(){$('#progressEditMode').hidden=false;$('#progressReportMode').hidden=true}
async function loadItemWeather(){
 const smsId=$('#progressSms').value,date=$('#progressBatchDate').value;
 itemWeather={};
 if(!smsId||!date)return;
 try{
  const rows=await dailyApi('list_item_weather',{smsId,reportDate:date});
  rows.forEach(r=>{
   if(!itemWeather[r.smsItemId])itemWeather[r.smsItemId]={};
   itemWeather[r.smsItemId][r.shift]={weather:r.weather,temperatureC:r.temperatureC,effectiveHours:r.effectiveHours};
  });
 }catch(err){}
}
function groupLeavesByItem(leaves){
 const map=new Map();
 for(const r of leaves){
  if(!map.has(r.sms_item_id))map.set(r.sms_item_id,{sms_item_id:r.sms_item_id,item_code:r.item_code,item_description:r.item_description,leaves:[]});
  map.get(r.sms_item_id).leaves.push(r);
 }
 return [...map.values()];
}
function syncShiftInputsToState(){
 document.querySelectorAll('[data-shift-weather]').forEach(el=>{
  const [sid,shift]=el.dataset.shiftWeather.split(':');
  if(!el.value)return;
  itemWeather[sid]=itemWeather[sid]||{};itemWeather[sid][shift]=itemWeather[sid][shift]||{};
  itemWeather[sid][shift].weather=el.value;
 });
 document.querySelectorAll('[data-shift-temp]').forEach(el=>{
  const [sid,shift]=el.dataset.shiftTemp.split(':');
  if(el.value==='')return;
  itemWeather[sid]=itemWeather[sid]||{};itemWeather[sid][shift]=itemWeather[sid][shift]||{};
  itemWeather[sid][shift].temperatureC=el.value;
 });
 document.querySelectorAll('[data-shift-hours]').forEach(el=>{
  const [sid,shift]=el.dataset.shiftHours.split(':');
  if(el.value==='')return;
  itemWeather[sid]=itemWeather[sid]||{};itemWeather[sid][shift]=itemWeather[sid][shift]||{};
  itemWeather[sid][shift].effectiveHours=el.value;
 });
}
function renderBatchList(){
 const query=$('#progressSearch').value.trim().toLowerCase();
 document.querySelectorAll('[data-batch-qty]').forEach(el=>{if(el.value.trim()!=='')keptValues[el.dataset.batchQty]=el.value;else delete keptValues[el.dataset.batchQty]});
 syncShiftInputsToState();
 const allLeaves=batchDetails.filter(r=>r.row_kind==='ITEM');
 const leaves=query?allLeaves.filter(r=>{
  const haystack=(r.item_code+' '+r.item_description+' '+pathFor(batchDetails,r)).toLowerCase();
  return haystack.includes(query);
 }):allLeaves;
 const groups=groupLeavesByItem(leaves);
 $('#progressBatchList').innerHTML=groups.length?groups.map(g=>`<div class="item-group">
  <div class="ig-header">
   <div class="pc-item">${escapeHtml(g.item_code)} — ${escapeHtml(g.item_description)}</div>
   <p class="hint">Cuaca per shift (berlaku buat semua sub-item di bawah, tanggal ini)</p>
   ${SHIFTS.map(s=>{
    const cur=(itemWeather[g.sms_item_id]||{})[s]||{};
    return `<div class="shift-block">
     <label>${SHIFT_LABELS[s]} — Cuaca</label>
     <select data-shift-weather="${g.sms_item_id}:${s}">
      <option value="">- pilih -</option>
      ${Object.entries(WEATHER_LABELS).map(([v,l])=>`<option value="${v}" ${cur.weather===v?'selected':''}>${l}</option>`).join('')}
     </select>
     <div class="field-row">
      <div><label>Suhu (°C)</label><input type="number" step="any" data-shift-temp="${g.sms_item_id}:${s}" value="${cur.temperatureC??''}"></div>
      <div><label>Jam Efektif</label><input type="number" step="0.5" min="0" data-shift-hours="${g.sms_item_id}:${s}" value="${cur.effectiveHours??''}"></div>
     </div>
    </div>`;
   }).join('')}
  </div>
  ${g.leaves.map(r=>`<div class="progress-card">
   <div class="pc-path">${escapeHtml(pathFor(batchDetails,r))}</div>
   <div class="pc-meta">Satuan: ${escapeHtml(r.unit||'-')} &middot; Target: ${r.qty!=null?fmt(r.qty):'—'} &middot; Tercatat: ${fmt(r.progress_total)}</div>
   <label for="qty-${r.id}">Qty hari ini</label>
   <input id="qty-${r.id}" type="number" min="0.000001" step="any" inputmode="decimal" data-batch-qty="${r.id}" value="${escapeHtml(keptValues[r.id]||'')}">
   <label class="photo-input">Foto (opsional, maks 3)</label>
   <input type="file" accept="image/*" capture="environment" data-batch-photo="${r.id}">
   <div class="photo-preview" data-photo-preview="${r.id}">${(stagedPhotos[r.id]||[]).map((p,i)=>`<span class="photo-thumb"><img src="${p.dataUrl}" alt="Foto ${i+1}"><button type="button" data-remove-photo="${r.id}:${i}" aria-label="Hapus foto">×</button></span>`).join('')}</div>
  </div>`).join('')}
 </div>`).join(''):(query?'<p class="empty">Gak ada yang cocok dengan pencarian.</p>':'<p class="empty">Belum ada breakdown di SMS ini.</p>');
 $('#progressSaveAll').disabled=!allLeaves.length;
 return allLeaves.length;
}
$('#progressSearch').addEventListener('input',renderBatchList);
$('#progressBatchList').addEventListener('change',async e=>{
 const el=e.target.closest('[data-batch-photo]');
 if(!el)return;
 const detailId=el.dataset.batchPhoto,file=el.files[0];
 el.value='';
 if(!file)return;
 const existing=stagedPhotos[detailId]||[];
 if(existing.length>=3){status('Maksimal 3 foto per sub-item.');return}
 try{
  const dataUrl=await compressImage(file);
  stagedPhotos[detailId]=[...existing,{dataUrl,mimeType:'image/jpeg'}];
  renderBatchList();
 }catch(err){status('Gagal memproses foto: '+err.message)}
});
$('#progressBatchList').addEventListener('click',e=>{
 const el=e.target.closest('[data-remove-photo]');
 if(!el)return;
 const [detailId,idx]=el.dataset.removePhoto.split(':');
 stagedPhotos[detailId]=(stagedPhotos[detailId]||[]).filter((_,i)=>String(i)!==idx);
 renderBatchList();
});
$('#progressLoadDetails').onclick=busy($('#progressLoadDetails'),async()=>{
 const smsId=$('#progressSms').value;if(!smsId)return;
 if(!$('#progressBatchDate').value)$('#progressBatchDate').value=new Date().toISOString().slice(0,10);
 $('#progressSearch').value='';keptValues={};stagedPhotos={};
 batchDetails=await dailyApi('list_sms_details',{smsId});
 await loadItemWeather();
 const total=renderBatchList();
 await refreshManpowerForDate();
 await refreshMaterialForDate();
 await refreshMaterialBalance();
 await refreshMaterialUsageForDate();
 $('#progressViewReport').disabled=false;
 status(total+' sub-item tersedia buat diisi progress.');
});
$('#progressSaveAll').onclick=busy($('#progressSaveAll'),async()=>{
 const reportDate=$('#progressBatchDate').value;
 if(!reportDate){status('Isi tanggal dulu.');return;}
 const inputs=[...document.querySelectorAll('[data-batch-qty]')].filter(el=>el.value.trim()!=='');
 const shiftWeatherEls=[...document.querySelectorAll('[data-shift-weather]')].filter(el=>el.value);
 if(!inputs.length&&!shiftWeatherEls.length){status('Belum ada qty atau cuaca yang diisi.');return;}
 let ok=0,fail=0,photoFail=0,weatherFail=0,firstError='';
 for(const el of inputs){
  const detailId=el.dataset.batchQty;
  const qty=Number(el.value);
  if(!Number.isFinite(qty)||qty<=0){fail++;if(!firstError)firstError='Qty tidak valid pada salah satu baris.';continue}
  try{
   const saved=await dailyApi('save_progress',{detailId,reportDate,qty});
   ok++;el.value='';
   for(const p of stagedPhotos[detailId]||[]){
    try{await dailyApi('add_progress_photo',{progressId:saved.id,photoData:p.dataUrl.split(',')[1],mimeType:p.mimeType})}
    catch(err){photoFail++}
   }
   delete stagedPhotos[detailId];
  }
  catch(err){fail++;if(!firstError)firstError=err.message}
 }
 for(const el of shiftWeatherEls){
  const [smsItemId,shift]=el.dataset.shiftWeather.split(':');
  const tempEl=document.querySelector('[data-shift-temp="'+smsItemId+':'+shift+'"]');
  const hoursEl=document.querySelector('[data-shift-hours="'+smsItemId+':'+shift+'"]');
  try{await dailyApi('save_item_weather',{smsItemId,reportDate,shift,weather:el.value,temperatureC:tempEl?tempEl.value:'',effectiveHours:hoursEl?hoursEl.value:''})}
  catch(err){weatherFail++}
 }
 await $('#progressLoadDetails').onclick();
 status(ok+' progress tersimpan'+(weatherFail?', '+weatherFail+' cuaca gagal disimpan':'')+(photoFail?', '+photoFail+' foto gagal upload':'')+(fail?', '+fail+' gagal ('+firstError+')':'.'));
});

// --- Daily Report (baca-saja): header proyek + tim per klasifikasi + rekap per main group
// (sms_item, dengan cuaca 3-shift) + entri leaf di bawahnya (qty digabung kalau ada >1 entri
// leaf yang sama di tanggal yang sama) ---
function computeDayProgress(startDate,endDate,reportDate){
 if(!startDate||!endDate)return null;
 const ms=86400000,start=new Date(startDate+'T00:00:00'),end=new Date(endDate+'T00:00:00'),cur=new Date(reportDate+'T00:00:00');
 return {dayNum:Math.round((cur-start)/ms)+1,total:Math.round((end-start)/ms)+1};
}
function shiftSummaryLine(s){return `${SHIFT_LABELS[s.shift]||s.shift}: ${escapeHtml(WEATHER_LABELS[s.weather]||s.weather)}`+(s.temperatureC!=null?` (${fmt(s.temperatureC)}°C)`:'')+(s.effectiveHours!=null?`, ${fmt(s.effectiveHours)} jam`:'')}
let lastReportContext=null;
$('#progressViewReport').onclick=busy($('#progressViewReport'),async()=>{
 const woId=$('#progressWo').value,smsId=$('#progressSms').value,reportDate=$('#progressBatchDate').value;
 if(!smsId||!reportDate){status('Pilih SMS dan tanggal dulu.');return}
 const [groups,header]=await Promise.all([
  dailyApi('read_daily_report',{smsId,reportDate}),
  dailyApi('get_report_header',{woId}).catch(()=>null)
 ]);
 const materials=lastMaterialRows;
 const materialUsage=lastMaterialUsageRows;
 groups.forEach(g=>g.entries.forEach(e=>{const detail=batchDetails.find(d=>d.id===e.detailId);e._path=detail?pathFor(batchDetails,detail):e.description}));
 const manpowerGroups=groupManpowerByKualifikasi(lastManpowerRows);
 const dayProgress=header?computeDayProgress(header.startDate,header.endDate,reportDate):null;
 lastReportContext={
  woLabel:$('#progressWo').selectedOptions[0]?.textContent||'-',
  smsLabel:$('#progressSms').selectedOptions[0]?.textContent||'-',
  reportDate,groups,header,manpowerGroups,manpowerTotal:lastManpowerRows.length,dayProgress,materials,materialUsage
 };
 const headerHtml=`<div class="report-header-block">
  <div><strong>Pekerjaan:</strong> ${escapeHtml(header?.projectName||'-')}</div>
  <div><strong>Lokasi:</strong> ${escapeHtml(header?.location||'-')}</div>
  <div><strong>Pemilik Proyek:</strong> ${escapeHtml(header?.client||'-')}</div>
  <div><strong>Kontraktor Pelaksana:</strong> ${escapeHtml(header?.contractorName||'-')}</div>
  <div><strong>Konsultan Pengawas:</strong> ${escapeHtml(header?.supervisorConsultant||'-')}</div>
  <div><strong>No. SPK/Kontrak:</strong> ${escapeHtml(header?.contractNumber||'-')}</div>
  <div><strong>Hari ke:</strong> ${dayProgress?dayProgress.dayNum+' dari '+dayProgress.total+' hari':'-'}</div>
 </div>`;
 const manpowerHtml=manpowerGroups.length?`<div class="report-header-block">
  <strong>Tenaga Kerja (Manpower) — Total ${lastManpowerRows.length} orang</strong>
  ${manpowerGroups.map(g=>`<div>${escapeHtml(g.kualifikasi)}: ${g.members.length} orang</div>`).join('')}
 </div>`:'';
 const materialHtml=materials&&materials.length?`<div class="report-header-block">
  <strong>Material Diterima End User</strong>
  ${materials.map(m=>`<div>${escapeHtml(m.itemDescription)} — ${fmt(m.qty)} ${escapeHtml(m.unit||'')} &middot; diserahkan ${escapeHtml(m.issuedByName||'-')} ke ${escapeHtml(m.confirmedByName||'-')}${m.notes?' &middot; '+escapeHtml(m.notes):''}</div>`).join('')}
 </div>`:'';
 const materialUsageHtml=materialUsage&&materialUsage.length?`<div class="report-header-block">
  <strong>Material Digunakan</strong>
  ${materialUsage.map(m=>`<div>${escapeHtml(m.itemDescription)} — ${fmt(m.qty)} ${escapeHtml(m.unit||'')} &middot; oleh ${escapeHtml(m.recordedByName||'-')}${m.notes?' &middot; '+escapeHtml(m.notes):''}</div>`).join('')}
 </div>`:'';
 $('#dailyReportView').innerHTML=headerHtml+manpowerHtml+materialHtml+materialUsageHtml+(groups.length?groups.map(g=>`<div class="report-card">
   <div class="pc-item">${escapeHtml(g.itemCode)} — ${escapeHtml(g.itemDescription)}</div>
   ${g.weatherShifts&&g.weatherShifts.length?`<div class="rc-shifts">${g.weatherShifts.map(s=>`<div>${shiftSummaryLine(s)}</div>`).join('')}</div>`:'<span class="rc-weather">Cuaca belum diisi</span>'}
   ${g.entries.map(e=>`<div class="rc-entry">
    <div class="pc-path">${escapeHtml(e._path)}</div>
    <div class="pc-meta">Qty: ${fmt(e.qty)} ${escapeHtml(e.unit||'')} &middot; Oleh: ${escapeHtml(e.recordedByNames||'-')} &middot; update terakhir ${new Date(e.lastUpdatedAt).toLocaleTimeString('id-ID',{hour:'2-digit',minute:'2-digit'})}</div>
    ${e.notes?`<div class="pc-path">Catatan: ${escapeHtml(e.notes)}</div>`:''}
    ${e.photos&&e.photos.length?`<div class="rc-photos">${e.photos.map(p=>`<img src="data:${escapeHtml(p.mimeType)};base64,${p.photoData}" alt="Foto progress">`).join('')}</div>`:''}
   </div>`).join('')}
  </div>`).join(''):'<p class="empty">Belum ada progress tercatat di tanggal ini.</p>');
 $('#progressEditMode').hidden=true;$('#progressReportMode').hidden=false;
 $('#reportDriveStatus').textContent='';
 status('Daily Report '+reportDate+' dimuat.');
});
$('#progressBackToEdit').onclick=showEditMode;

// --- Export PDF (client-side, jsPDF) + upload ke Google Drive lewat Apps Script ---
// Kenapa Apps Script bukan panggil Google Drive API langsung dari sini: upload ke Drive
// butuh kredensial (service account/OAuth) yang gak boleh nempel di kode client-side statis
// kaya GitHub Pages ini. Apps Script Web App jalan pakai identitas akun Google yang deploy,
// polanya sama kaya APPS_SCRIPT_URL yang udah dipakai Fusion4 (attendance.html).
const DRIVE_APPS_SCRIPT_URL=''; // TODO: isi URL Web App Apps Script setelah di-deploy (lihat drive-upload.gs)
const DRIVE_SHARED_SECRET=''; // TODO: samain persis dengan SHARED_SECRET di Apps Script

let logoDataUrlCache=null;
async function loadLogoDataUrl(){
 // Logo aslinya ~60KB (370x367 PNG interlaced) -- kegedean buat ditempel apa adanya ke tiap PDF
 // (jsPDF gak recompress). Resize kecil dulu lewat canvas, size-nya jadi cuma beberapa KB.
 if(logoDataUrlCache!==null)return logoDataUrlCache;
 try{
  const res=await fetch('logo.png');
  if(!res.ok)throw Error('logo not found');
  const blob=await res.blob();
  const bitmapUrl=await new Promise((resolve,reject)=>{
   const reader=new FileReader();
   reader.onload=()=>resolve(reader.result);
   reader.onerror=()=>reject(Error('Gagal baca logo.'));
   reader.readAsDataURL(blob);
  });
  logoDataUrlCache=await new Promise((resolve,reject)=>{
   const img=new Image();
   img.onload=()=>{
    const size=96,canvas=document.createElement('canvas');canvas.width=size;canvas.height=size;
    canvas.getContext('2d').drawImage(img,0,0,size,size);
    resolve(canvas.toDataURL('image/png'));
   };
   img.onerror=()=>reject(Error('Gagal decode logo.'));
   img.src=bitmapUrl;
  });
 }catch(err){logoDataUrlCache=''}
 return logoDataUrlCache;
}
async function buildDailyReportDoc(){
 if(!lastReportContext)throw Error('Muat Daily Report dulu.');
 if(!window.jspdf)throw Error('Library PDF belum termuat, coba refresh halaman.');
 const {jsPDF}=window.jspdf;
 const doc=new jsPDF({unit:'pt',format:'a4'});
 if(typeof doc.autoTable!=='function')throw Error('Library tabel PDF belum termuat, coba refresh halaman.');
 const pageWidth=doc.internal.pageSize.getWidth(),pageHeight=doc.internal.pageSize.getHeight();
 const margin=40;
 const gridStyles={fontSize:8,cellPadding:4,lineColor:[180,180,180],lineWidth:0.5};
 const headStyles={fillColor:[36,52,99],textColor:255,fontStyle:'bold'};
 const h=lastReportContext.header,dp=lastReportContext.dayProgress;

 const logoDataUrl=await loadLogoDataUrl();
 const textX=logoDataUrl?margin+42:margin;
 if(logoDataUrl){try{doc.addImage(logoDataUrl,'PNG',margin,margin-24,34,34)}catch(err){}}
 doc.setFontSize(15);doc.setFont(undefined,'bold');doc.text('LAPORAN HARIAN PROYEK',textX,margin);
 doc.setFontSize(9);doc.setFont(undefined,'normal');doc.text('DAILY CONSTRUCTION PROGRESS REPORT — BIMA SPMS',textX,margin+15);

 doc.autoTable({
  startY:margin+28,margin:{left:margin,right:margin},theme:'grid',styles:gridStyles,
  columnStyles:{0:{fontStyle:'bold',cellWidth:120,fillColor:[245,246,250]},1:{cellWidth:'auto'}},
  body:[
   ['Nama Pekerjaan',h?.projectName||'-'],
   ['Lokasi Proyek',h?.location||'-'],
   ['Pemilik Proyek (Owner)',h?.client||'-'],
   ['Kontraktor Pelaksana',h?.contractorName||'-'],
   ['Konsultan Pengawas',h?.supervisorConsultant||'-'],
   ['No. SPK / Kontrak',h?.contractNumber||'-'],
   ['Hari ke',dp?dp.dayNum+' dari '+dp.total+' hari':'-'],
   ['WO / SMS',lastReportContext.woLabel+' / '+lastReportContext.smsLabel],
   ['Tanggal',lastReportContext.reportDate]
  ]
 });
 let y=doc.lastAutoTable.finalY+18;

 if(lastReportContext.manpowerGroups&&lastReportContext.manpowerGroups.length){
  if(y>pageHeight-100){doc.addPage();y=margin}
  doc.setFontSize(11);doc.setFont(undefined,'bold');doc.text('TENAGA KERJA (MANPOWER)',margin,y);
  doc.autoTable({
   startY:y+8,margin:{left:margin,right:margin},theme:'grid',styles:gridStyles,headStyles,
   head:[['Klasifikasi / Posisi','Jumlah Hadir']],
   body:lastReportContext.manpowerGroups.map(g=>[g.kualifikasi,g.members.length+' Org']),
   foot:[['TOTAL',lastReportContext.manpowerTotal+' Org']],
   footStyles:{fillColor:[245,246,250],textColor:[20,20,20],fontStyle:'bold'}
  });
  y=doc.lastAutoTable.finalY+18;
 }

 if(lastReportContext.materials&&lastReportContext.materials.length){
  if(y>pageHeight-100){doc.addPage();y=margin}
  doc.setFontSize(11);doc.setFont(undefined,'bold');doc.text('MATERIAL DITERIMA END USER',margin,y);
  doc.autoTable({
   startY:y+8,margin:{left:margin,right:margin},theme:'grid',styles:{...gridStyles,valign:'top'},headStyles,
   head:[['Item','Qty','Satuan','Diserahkan','Diterima','Catatan']],
   body:lastReportContext.materials.map(m=>[m.itemDescription,fmt(m.qty),m.unit||'-',m.issuedByName||'-',m.confirmedByName||'-',m.notes||'-'])
  });
  y=doc.lastAutoTable.finalY+18;
 }

 if(lastReportContext.materialUsage&&lastReportContext.materialUsage.length){
  if(y>pageHeight-100){doc.addPage();y=margin}
  doc.setFontSize(11);doc.setFont(undefined,'bold');doc.text('MATERIAL DIGUNAKAN',margin,y);
  doc.autoTable({
   startY:y+8,margin:{left:margin,right:margin},theme:'grid',styles:{...gridStyles,valign:'top'},headStyles,
   head:[['Item','Qty','Satuan','Dicatat Oleh','Catatan']],
   body:lastReportContext.materialUsage.map(m=>[m.itemDescription,fmt(m.qty),m.unit||'-',m.recordedByName||'-',m.notes||'-'])
  });
  y=doc.lastAutoTable.finalY+18;
 }

 if(!lastReportContext.groups.length){
  doc.setFontSize(10);doc.setFont(undefined,'normal');doc.text('Belum ada progress tercatat di tanggal ini.',margin,y);
 }
 for(const g of lastReportContext.groups){
  if(y>pageHeight-120){doc.addPage();y=margin}
  doc.setFontSize(11);doc.setFont(undefined,'bold');
  doc.text(String(g.itemCode+' — '+g.itemDescription),margin,y);
  y+=8;

  if(g.weatherShifts&&g.weatherShifts.length){
   doc.autoTable({
    startY:y+6,margin:{left:margin,right:margin},theme:'grid',styles:gridStyles,headStyles,
    head:[['Shift','Kondisi Cuaca','Suhu (°C)','Jam Efektif']],
    body:g.weatherShifts.map(s=>[SHIFT_LABELS[s.shift]||s.shift,WEATHER_LABELS[s.weather]||s.weather,s.temperatureC!=null?fmt(s.temperatureC):'-',s.effectiveHours!=null?fmt(s.effectiveHours)+' Jam':'-'])
   });
   y=doc.lastAutoTable.finalY+10;
  }

  doc.autoTable({
   startY:y,margin:{left:margin,right:margin},theme:'grid',styles:{...gridStyles,valign:'top'},
   headStyles:{fillColor:[217,49,46],textColor:255,fontStyle:'bold'},
   head:[['Uraian / Breakdown','Qty','Satuan','Oleh','Update Terakhir','Catatan']],
   body:g.entries.map(e=>[e._path,fmt(e.qty),e.unit||'-',e.recordedByNames||'-',new Date(e.lastUpdatedAt).toLocaleTimeString('id-ID',{hour:'2-digit',minute:'2-digit'}),e.notes||'-'])
  });
  y=doc.lastAutoTable.finalY+8;

  // Foto ditaruh di luar tabel (bukan di dalam cell) -- lebih simpel & tetep kebaca rapi
  const photosFlat=g.entries.flatMap(e=>e.photos||[]);
  if(photosFlat.length){
   const imgSize=80;let x=margin;
   if(y+imgSize+10>pageHeight-margin){doc.addPage();y=margin}
   for(const p of photosFlat){
    if(x+imgSize>pageWidth-margin){x=margin;y+=imgSize+10;if(y+imgSize+10>pageHeight-margin){doc.addPage();y=margin}}
    try{doc.addImage('data:'+p.mimeType+';base64,'+p.photoData,'JPEG',x,y,imgSize,imgSize)}catch(err){}
    x+=imgSize+10;
   }
   y+=imgSize+14;
  }
  y+=10;
 }
 return doc;
}
function reportFileName(){return 'DailyReport_'+lastReportContext.woLabel.replace(/[^\w-]+/g,'_')+'_'+lastReportContext.reportDate+'.pdf'}

$('#reportDownloadPdf').onclick=busy($('#reportDownloadPdf'),async()=>{
 const doc=await buildDailyReportDoc();
 doc.save(reportFileName());
});
$('#reportUploadDrive').onclick=busy($('#reportUploadDrive'),async()=>{
 $('#reportDriveStatus').textContent='';
 if(!DRIVE_APPS_SCRIPT_URL){$('#reportDriveStatus').textContent='Belum dikonfigurasi -- deploy drive-upload.gs dulu, lalu isi DRIVE_APPS_SCRIPT_URL di progress.js.';return}
 $('#reportDriveStatus').textContent='Membuat PDF...';
 const doc=await buildDailyReportDoc();
 const base64=doc.output('datauristring').split(',')[1];
 $('#reportDriveStatus').textContent='Mengunggah ke Google Drive...';
 const res=await fetch(DRIVE_APPS_SCRIPT_URL,{method:'POST',body:JSON.stringify({secret:DRIVE_SHARED_SECRET,fileName:reportFileName(),pdfBase64:base64}),headers:{'Content-Type':'text/plain'}});
 const body=await res.json().catch(()=>null);
 if(!body||body.status!=='ok')throw Error(body?.message||'Upload ke Drive gagal.');
 $('#reportDriveStatus').textContent='Tersimpan di Drive: '+body.url;
});
