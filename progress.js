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
function busy(button,fn){return async()=>{button.disabled=true;try{await fn()}catch(err){status(err.message)}finally{button.disabled=false}}}

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
 $('#progressLoadSms').disabled=true;$('#progressLoadDetails').disabled=true;$('#progressSaveAll').disabled=true;
 $('#progressBatchList').innerHTML='<p class="empty">Pilih WO dan SMS, lalu muat breakdown.</p>';
 status('Sudah keluar.');
};

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
});
$('#progressLoadSms').onclick=busy($('#progressLoadSms'),async()=>{
 const woId=$('#progressWo').value;if(!woId)return;
 const rows=await api('list_sms',{woId});
 $('#progressSms').disabled=false;
 $('#progressSms').innerHTML='<option value="">Pilih SMS tersimpan</option>'+rows.map(r=>`<option value="${r.id}">${escapeHtml(r.number+' Rev '+r.revision+' · '+r.status)}</option>`).join('');
 status(rows.length+' SMS tersedia untuk WO ini.');
});
$('#progressSms').addEventListener('change',()=>{$('#progressLoadDetails').disabled=!$('#progressSms').value});
$('#progressLoadDetails').onclick=busy($('#progressLoadDetails'),async()=>{
 const smsId=$('#progressSms').value;if(!smsId)return;
 if(!$('#progressBatchDate').value)$('#progressBatchDate').value=new Date().toISOString().slice(0,10);
 batchDetails=await dailyApi('list_sms_details',{smsId});
 const leaves=batchDetails.filter(r=>r.row_kind==='ITEM');
 $('#progressBatchList').innerHTML=leaves.map(r=>`<div class="progress-card">
  <div class="pc-item">${escapeHtml(r.item_code)} — ${escapeHtml(r.item_description)}</div>
  <div class="pc-path">${escapeHtml(pathFor(batchDetails,r))}</div>
  <div class="pc-meta">Satuan: ${escapeHtml(r.unit||'-')} &middot; Target: ${r.qty!=null?fmt(r.qty):'—'} &middot; Tercatat: ${fmt(r.progress_total)}</div>
  <label for="qty-${r.id}">Qty hari ini</label>
  <input id="qty-${r.id}" type="number" min="0.000001" step="any" inputmode="decimal" data-batch-qty="${r.id}">
 </div>`).join('')||'<p class="empty">Belum ada breakdown di SMS ini.</p>';
 $('#progressSaveAll').disabled=!leaves.length;
 status(leaves.length+' sub-item tersedia buat diisi progress.');
});
$('#progressSaveAll').onclick=busy($('#progressSaveAll'),async()=>{
 const reportDate=$('#progressBatchDate').value;
 if(!reportDate){status('Isi tanggal dulu.');return;}
 const inputs=[...document.querySelectorAll('[data-batch-qty]')].filter(el=>el.value.trim()!=='');
 if(!inputs.length){status('Belum ada qty yang diisi.');return;}
 let ok=0,fail=0,firstError='';
 for(const el of inputs){
  const qty=Number(el.value);
  if(!Number.isFinite(qty)||qty<=0){fail++;if(!firstError)firstError='Qty tidak valid pada salah satu baris.';continue}
  try{await dailyApi('save_progress',{detailId:el.dataset.batchQty,reportDate,qty});ok++;el.value=''}
  catch(err){fail++;if(!firstError)firstError=err.message}
 }
 await $('#progressLoadDetails').onclick();
 status(ok+' progress tersimpan'+(fail?', '+fail+' gagal ('+firstError+')':'.'));
});
