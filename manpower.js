'use strict';
// Browser-safe publishable key. No service-role credential belongs in this file.
const OP_CONFIG={url:'https://nhmpwjriextmbotmvvbu.supabase.co',key:'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz'};
const $=s=>document.querySelector(s);
const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let opSession=null;
function status(s){$('#status').textContent=s}
async function rpc(name,params){const response=await fetch(OP_CONFIG.url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:OP_CONFIG.key,'Content-Type':'application/json'},body:JSON.stringify(params)});const body=await response.json().catch(()=>null);if(!response.ok)throw Error(body?.message||'Koneksi gagal ('+response.status+')');return body}
async function api(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_api',{p_token:opSession.token,p_action:action,p_data:data})}
async function manpowerApi(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_manpower',{p_token:opSession.token,p_action:action,p_data:data})}
function busy(button,fn){return async()=>{button.disabled=true;try{await fn()}catch(err){status(err.message)}finally{button.disabled=false}}}

// --- Login (akun PIC/Foreman) ---
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
  if(!allowed)throw Error('Akun ini belum diizinkan akses Operational WO / Team Check-in.');
  opSession=result;
  $('#employeePassword').value='';
  $('#loginSection').hidden=true;$('#manpowerSection').hidden=false;
  $('#identity').textContent='Masuk: '+opSession.name;$('#logout').hidden=false;
  status('Login berhasil.');
 }catch(err){$('#loginError').textContent=err.message;$('#employeePassword').value=''}
 finally{b.disabled=false}
};
$('#logout').onclick=async()=>{
 try{if(opSession)await rpc('op_logout',{p_token:opSession.token})}catch(err){}
 opSession=null;
 $('#loginSection').hidden=false;$('#manpowerSection').hidden=true;
 $('#identity').textContent='Belum login';$('#logout').hidden=true;
 resetManpowerForm();
 $('#mpWo').innerHTML='<option value="">Pilih WO tersimpan</option>';
 $('#mpActiveList').innerHTML='<p class="empty">Pilih WO buat lihat tim yang sedang check-in.</p>';
 status('Sudah keluar.');
};

// --- Pilih WO ---
$('#mpLoadWos').onclick=busy($('#mpLoadWos'),async()=>{
 const rows=await api('list_wo');
 $('#mpWo').innerHTML='<option value="">Pilih WO tersimpan</option>'+rows.map(w=>`<option value="${w.id}">${escapeHtml(w.number+' / '+w.contract_number+' / '+w.status)}</option>`).join('');
 status(rows.length+' WO tersedia.');
});
$('#mpWo').addEventListener('change',async()=>{
 const has=!!$('#mpWo').value;
 $('#mpEmployeeSearch').disabled=!has;
 resetManpowerForm();
 if(has)await refreshActiveList();
 else $('#mpActiveList').innerHTML='<p class="empty">Pilih WO buat lihat tim yang sedang check-in.</p>';
});

function resetManpowerForm(){
 $('#mpEmployeeSearch').value='';$('#mpEmployeeId').value='';
 $('#mpEmployeeSuggestions').hidden=true;$('#mpEmployeeSuggestions').replaceChildren();
 $('#mpEmployeeStatus').textContent='';
 $('#mpPin').value='';$('#mpPin').disabled=true;
 $('#mpCheckIn').disabled=true;$('#mpCheckOut').disabled=true;
 $('#mpActionError').textContent='';
}

// --- Cari anggota tim ---
let mpSearchTimer,mpSearchVersion=0;
$('#mpEmployeeSearch').addEventListener('input',()=>{
 clearTimeout(mpSearchTimer);const version=++mpSearchVersion,query=$('#mpEmployeeSearch').value.trim();
 $('#mpEmployeeId').value='';$('#mpEmployeeSuggestions').replaceChildren();$('#mpEmployeeSuggestions').hidden=true;
 $('#mpPin').disabled=true;$('#mpCheckIn').disabled=true;$('#mpCheckOut').disabled=true;
 $('#mpEmployeeStatus').textContent=query.length<2?'Ketik minimal 2 huruf nama.':'Mencari karyawan...';
 if(query.length<2)return;
 mpSearchTimer=setTimeout(async()=>{
  try{
   const rows=await rpc('search_active_karyawan',{p_query:query});
   if(version!==mpSearchVersion)return;
   const matches=Array.isArray(rows)?rows.slice(0,8):[];
   $('#mpEmployeeStatus').textContent=matches.length?'Pilih nama yang sesuai.':'Nama tidak ditemukan.';
   for(const row of matches){
    if(!/^\d+$/.test(String(row.id))||typeof row.nama!=='string')continue;
    const button=document.createElement('button');
    button.type='button';button.textContent=row.nama+' (ID: '+row.id+')';
    button.onclick=()=>{
     ++mpSearchVersion;$('#mpEmployeeId').value=String(row.id);$('#mpEmployeeSearch').value=row.nama+' (ID: '+row.id+')';
     $('#mpEmployeeSuggestions').hidden=true;$('#mpEmployeeSuggestions').replaceChildren();
     $('#mpEmployeeStatus').textContent='Dipilih. Minta anggota tim masukkan PIN sendiri.';
     $('#mpPin').disabled=false;$('#mpCheckIn').disabled=false;$('#mpCheckOut').disabled=false;$('#mpPin').value='';$('#mpPin').focus();
    };
    $('#mpEmployeeSuggestions').append(button);
   }
   $('#mpEmployeeSuggestions').hidden=!$('#mpEmployeeSuggestions').children.length;
  }catch(err){if(version===mpSearchVersion)$('#mpEmployeeStatus').textContent='Pencarian gagal. Ketik ulang untuk mencoba lagi.'}
 },300);
});

async function refreshActiveList(){
 const woId=$('#mpWo').value;if(!woId)return;
 const rows=await manpowerApi('active_checkins',{woId});
 $('#mpActiveList').innerHTML=rows.map(r=>`<div class="mp-card"><span class="mp-name">${escapeHtml(r.employee_name)}</span><span class="mp-time">Masuk ${new Date(r.check_in_at).toLocaleTimeString('id-ID',{hour:'2-digit',minute:'2-digit'})}</span></div>`).join('')||'<p class="empty">Belum ada yang check-in di WO ini.</p>';
}

$('#mpCheckIn').onclick=busy($('#mpCheckIn'),async()=>{
 const woId=$('#mpWo').value,employeeId=$('#mpEmployeeId').value,pin=$('#mpPin').value.trim();
 $('#mpActionError').textContent='';
 if(!woId){$('#mpActionError').textContent='Pilih WO dulu.';return}
 if(!employeeId){$('#mpActionError').textContent='Pilih anggota tim dulu.';return}
 if(!/^\d+$/.test(pin)){$('#mpActionError').textContent='PIN harus angka.';return}
 try{
  const result=await manpowerApi('checkin',{woId,employeeId,pin});
  status(result.employeeName+' berhasil check-in.');
  resetManpowerForm();
  await refreshActiveList();
 }catch(err){$('#mpActionError').textContent=err.message}
});
$('#mpCheckOut').onclick=busy($('#mpCheckOut'),async()=>{
 const employeeId=$('#mpEmployeeId').value,pin=$('#mpPin').value.trim();
 $('#mpActionError').textContent='';
 if(!employeeId){$('#mpActionError').textContent='Pilih anggota tim dulu.';return}
 if(!/^\d+$/.test(pin)){$('#mpActionError').textContent='PIN harus angka.';return}
 try{
  const result=await manpowerApi('checkout',{employeeId,pin});
  status(result.employeeName+' berhasil check-out.');
  resetManpowerForm();
  await refreshActiveList();
 }catch(err){$('#mpActionError').textContent=err.message}
});
