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
 $('#progressSearch').value='';batchDetails=[];keptValues={};keptWeather={};stagedPhotos={};
 $('#progressBatchList').innerHTML='<p class="empty">Pilih WO dan SMS, lalu muat breakdown.</p>';
 $('#progressManpowerList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat siapa yang check-in.</p>';
 showEditMode();
 status('Sudah keluar.');
};

// Manpower dan Daily Progress sama-sama di-scope ke WO+tanggal -- gak perlu foreign key baru,
// tinggal query check-in yang jatuh di tanggal yang sama buat WO yang sama.
function localDateOf(isoTimestamp){const d=new Date(isoTimestamp);return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')}
async function refreshManpowerForDate(){
 const woId=$('#progressWo').value,date=$('#progressBatchDate').value;
 if(!woId||!date){$('#progressManpowerList').innerHTML='<p class="empty">Pilih WO dan tanggal buat lihat siapa yang check-in.</p>';return}
 try{
  const rows=await manpowerApi('list_checkins',{woId});
  const dayRows=rows.filter(r=>localDateOf(r.check_in_at)===date);
  $('#progressManpowerList').innerHTML=dayRows.length?dayRows.map(r=>`<div class="mp-card"><span class="mp-name">${escapeHtml(r.employee_name)}</span><span class="mp-time">${fmt(r.hours)} jam</span></div>`).join(''):'<p class="empty">Belum ada yang check-in di WO ini pada tanggal tsb.</p>';
 }catch(err){$('#progressManpowerList').innerHTML='<p class="empty">Gagal memuat data manpower: '+escapeHtml(err.message)+'</p>'}
}
$('#progressBatchDate').addEventListener('change',refreshManpowerForDate);

let batchDetails=[];
function pathFor(rows,row){const names=[];let cur=row;while(cur){names.unshift(cur.description);cur=cur.parent_id?rows.find(r=>r.id===cur.parent_id):null}return names.join(' / ')}

$('#progressLoadWos').onclick=busy($('#progressLoadWos'),async()=>{
 const rows=await api('list_wo');
 $('#progressWo').innerHTML='<option value="">Pilih WO tersimpan</option>'+rows.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' / '+w.contract_number+' / '+w.status)}</option>`).join('');
 $('#progressSms').disabled=true;$('#progressLoadSms').disabled=true;
 status(rows.length+' WO tersedia.');
});
$('#progressWo').addEventListener('change',()=>{
 $('#progressLoadSms').disabled=!$('#progressWo').value;
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>';$('#progressSms').disabled=true;
 $('#progressLoadDetails').disabled=true;$('#progressSaveAll').disabled=true;
 refreshManpowerForDate();
});
$('#progressLoadSms').onclick=busy($('#progressLoadSms'),async()=>{
 const woId=$('#progressWo').value;if(!woId)return;
 const rows=await api('list_sms',{woId});
 $('#progressSms').disabled=false;
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>'+rows.map(r=>`<option value="${r.id}">${escapeHtml(r.number+' Rev '+r.revision+' · '+r.status)}</option>`).join('');
 status(rows.length+' SMS tersedia untuk WO ini.');
});
$('#progressSms').addEventListener('change',()=>{$('#progressLoadDetails').disabled=!$('#progressSms').value;$('#progressViewReport').disabled=true});
let keptValues={},keptWeather={},stagedPhotos={};
function showEditMode(){$('#progressEditMode').hidden=false;$('#progressReportMode').hidden=true}
function renderBatchList(){
 const query=$('#progressSearch').value.trim().toLowerCase();
 document.querySelectorAll('[data-batch-qty]').forEach(el=>{if(el.value.trim()!=='')keptValues[el.dataset.batchQty]=el.value;else delete keptValues[el.dataset.batchQty]});
 document.querySelectorAll('[data-batch-weather]').forEach(el=>{if(el.value)keptWeather[el.dataset.batchWeather]=el.value;else delete keptWeather[el.dataset.batchWeather]});
 const allLeaves=batchDetails.filter(r=>r.row_kind==='ITEM');
 const leaves=query?allLeaves.filter(r=>{
  const haystack=(r.item_code+' '+r.item_description+' '+pathFor(batchDetails,r)).toLowerCase();
  return haystack.includes(query);
 }):allLeaves;
 $('#progressBatchList').innerHTML=leaves.map(r=>`<div class="progress-card">
  <div class="pc-item">${escapeHtml(r.item_code)} — ${escapeHtml(r.item_description)}</div>
  <div class="pc-path">${escapeHtml(pathFor(batchDetails,r))}</div>
  <div class="pc-meta">Satuan: ${escapeHtml(r.unit||'-')} &middot; Target: ${r.qty!=null?fmt(r.qty):'—'} &middot; Tercatat: ${fmt(r.progress_total)}</div>
  <label for="qty-${r.id}">Qty hari ini</label>
  <input id="qty-${r.id}" type="number" min="0.000001" step="any" inputmode="decimal" data-batch-qty="${r.id}" value="${escapeHtml(keptValues[r.id]||'')}">
  <label for="weather-${r.id}">Cuaca</label>
  <select id="weather-${r.id}" data-batch-weather="${r.id}">
   <option value="">- pilih -</option>
   ${Object.entries(WEATHER_LABELS).map(([v,l])=>`<option value="${v}" ${keptWeather[r.id]===v?'selected':''}>${l}</option>`).join('')}
  </select>
  <label class="photo-input">Foto (opsional, maks 3)</label>
  <input type="file" accept="image/*" capture="environment" data-batch-photo="${r.id}">
  <div class="photo-preview" data-photo-preview="${r.id}">${(stagedPhotos[r.id]||[]).map((p,i)=>`<span class="photo-thumb"><img src="${p.dataUrl}" alt="Foto ${i+1}"><button type="button" data-remove-photo="${r.id}:${i}" aria-label="Hapus foto">×</button></span>`).join('')}</div>
 </div>`).join('')||(query?'<p class="empty">Gak ada yang cocok dengan pencarian.</p>':'<p class="empty">Belum ada breakdown di SMS ini.</p>');
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
 $('#progressSearch').value='';keptValues={};keptWeather={};stagedPhotos={};
 batchDetails=await dailyApi('list_sms_details',{smsId});
 const total=renderBatchList();
 await refreshManpowerForDate();
 $('#progressViewReport').disabled=false;
 status(total+' sub-item tersedia buat diisi progress.');
});
$('#progressSaveAll').onclick=busy($('#progressSaveAll'),async()=>{
 const reportDate=$('#progressBatchDate').value;
 if(!reportDate){status('Isi tanggal dulu.');return;}
 const inputs=[...document.querySelectorAll('[data-batch-qty]')].filter(el=>el.value.trim()!=='');
 if(!inputs.length){status('Belum ada qty yang diisi.');return;}
 let ok=0,fail=0,photoFail=0,firstError='';
 for(const el of inputs){
  const detailId=el.dataset.batchQty;
  const qty=Number(el.value);
  if(!Number.isFinite(qty)||qty<=0){fail++;if(!firstError)firstError='Qty tidak valid pada salah satu baris.';continue}
  const weatherEl=document.querySelector('[data-batch-weather="'+detailId+'"]');
  const weather=weatherEl?weatherEl.value:'';
  try{
   const saved=await dailyApi('save_progress',{detailId,reportDate,qty,weather});
   ok++;el.value='';
   for(const p of stagedPhotos[detailId]||[]){
    try{await dailyApi('add_progress_photo',{progressId:saved.id,photoData:p.dataUrl.split(',')[1],mimeType:p.mimeType})}
    catch(err){photoFail++}
   }
   delete stagedPhotos[detailId];delete keptWeather[detailId];
  }
  catch(err){fail++;if(!firstError)firstError=err.message}
 }
 await $('#progressLoadDetails').onclick();
 status(ok+' progress tersimpan'+(photoFail?', '+photoFail+' foto gagal upload':'')+(fail?', '+fail+' gagal ('+firstError+')':'.'));
});

// --- Daily Report (baca-saja): rekap qty+cuaca+foto per sub-item, buat SMS+tanggal ini ---
let lastReportContext=null;
$('#progressViewReport').onclick=busy($('#progressViewReport'),async()=>{
 const smsId=$('#progressSms').value,reportDate=$('#progressBatchDate').value;
 if(!smsId||!reportDate){status('Pilih SMS dan tanggal dulu.');return}
 const rows=await dailyApi('read_daily_report',{smsId,reportDate});
 rows.forEach(r=>{const detail=batchDetails.find(d=>d.id===r.detail_id);r._path=detail?pathFor(batchDetails,detail):r.description});
 lastReportContext={
  woLabel:$('#progressWo').selectedOptions[0]?.textContent||'-',
  smsLabel:$('#progressSms').selectedOptions[0]?.textContent||'-',
  reportDate,rows
 };
 $('#dailyReportView').innerHTML=rows.length?rows.map(r=>`<div class="report-card">
   <div class="pc-item">${escapeHtml(r.item_code)} — ${escapeHtml(r.item_description)}</div>
   <div class="pc-path">${escapeHtml(r._path)}</div>
   <div class="pc-meta">Qty: ${fmt(r.qty)} ${escapeHtml(r.unit||'')} &middot; Oleh: ${escapeHtml(r.recorded_by_name||'-')} &middot; ${new Date(r.created_at).toLocaleTimeString('id-ID',{hour:'2-digit',minute:'2-digit'})}</div>
   ${r.weather?`<span class="rc-weather">${escapeHtml(WEATHER_LABELS[r.weather]||r.weather)}</span>`:''}
   ${r.notes?`<div class="pc-path">Catatan: ${escapeHtml(r.notes)}</div>`:''}
   ${r.photos&&r.photos.length?`<div class="rc-photos">${r.photos.map(p=>`<img src="data:${escapeHtml(p.mimeType)};base64,${p.photoData}" alt="Foto progress">`).join('')}</div>`:''}
  </div>`).join(''):'<p class="empty">Belum ada progress tercatat di tanggal ini.</p>';
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

async function buildDailyReportDoc(){
 if(!lastReportContext)throw Error('Muat Daily Report dulu.');
 if(!window.jspdf)throw Error('Library PDF belum termuat, coba refresh halaman.');
 const {jsPDF}=window.jspdf;
 const doc=new jsPDF({unit:'pt',format:'a4'});
 const pageWidth=doc.internal.pageSize.getWidth(),pageHeight=doc.internal.pageSize.getHeight();
 const margin=40;let y=margin;
 function ensureSpace(h){if(y+h>pageHeight-margin){doc.addPage();y=margin}}
 doc.setFontSize(16);doc.text('Daily Report — BIMA SPMS',margin,y);y+=22;
 doc.setFontSize(10);
 doc.text('WO: '+lastReportContext.woLabel,margin,y);y+=14;
 doc.text('SMS: '+lastReportContext.smsLabel,margin,y);y+=14;
 doc.text('Tanggal: '+lastReportContext.reportDate,margin,y);y+=18;
 doc.setDrawColor(200);doc.line(margin,y,pageWidth-margin,y);y+=16;
 if(!lastReportContext.rows.length){doc.text('Belum ada progress tercatat di tanggal ini.',margin,y)}
 for(const r of lastReportContext.rows){
  ensureSpace(50);
  doc.setFontSize(11);doc.setFont(undefined,'bold');
  doc.text(String(r.item_code+' — '+r.item_description),margin,y);y+=14;
  doc.setFont(undefined,'normal');doc.setFontSize(9);
  doc.text('Breakdown: '+r._path,margin,y);y+=12;
  doc.text('Qty: '+fmt(r.qty)+' '+(r.unit||'')+'   Cuaca: '+(WEATHER_LABELS[r.weather]||'-')+'   Oleh: '+(r.recorded_by_name||'-'),margin,y);y+=12;
  if(r.notes){doc.text('Catatan: '+r.notes,margin,y);y+=12}
  if(r.photos&&r.photos.length){
   const imgSize=90;let x=margin;
   ensureSpace(imgSize+10);
   for(const p of r.photos){
    if(x+imgSize>pageWidth-margin){x=margin;y+=imgSize+10;ensureSpace(imgSize+10)}
    try{doc.addImage('data:'+p.mimeType+';base64,'+p.photoData,'JPEG',x,y,imgSize,imgSize)}catch(e){}
    x+=imgSize+10;
   }
   y+=imgSize+14;
  }
  y+=6;doc.setDrawColor(230);doc.line(margin,y,pageWidth-margin,y);y+=14;
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
