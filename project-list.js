'use strict';
// Browser-safe publishable key. No service-role credential belongs in this file.
const OP_CONFIG={url:'https://nhmpwjriextmbotmvvbu.supabase.co',key:'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz'};
const $=s=>document.querySelector(s);
const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let opSession=null;
function status(s){$('#status').textContent=s}
async function rpc(name,params){const response=await fetch(OP_CONFIG.url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:OP_CONFIG.key,'Content-Type':'application/json'},body:JSON.stringify(params)});const body=await response.json().catch(()=>null);if(!response.ok)throw Error(body?.message||'Koneksi gagal ('+response.status+')');return body}
async function api(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_api',{p_token:opSession.token,p_action:action,p_data:data})}
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
  const allowed=(result.pic||[]).some(x=>['all','operational wo','operational master komersial'].includes(String(x).trim().toLowerCase()));
  if(!allowed)throw Error('Akun ini belum diizinkan akses Data Proyek.');
  opSession=result;
  $('#employeePassword').value='';
  $('#loginSection').hidden=true;$('#projectSection').hidden=false;
  $('#identity').textContent='Masuk: '+opSession.name;$('#logout').hidden=false;
  status('Login berhasil.');
 }catch(err){$('#loginError').textContent=err.message;$('#employeePassword').value=''}
 finally{b.disabled=false}
};
$('#logout').onclick=async()=>{
 try{if(opSession)await rpc('op_logout',{p_token:opSession.token})}catch(err){}
 opSession=null;
 $('#loginSection').hidden=false;$('#projectSection').hidden=true;
 $('#identity').textContent='Belum login';$('#logout').hidden=true;
 $('#projectSearch').value='';projectRows=[];editingProjectId=null;
 $('#projectList').innerHTML='<p class="empty">Klik Muat buat lihat daftar proyek.</p>';
 $('#projectEditCard').hidden=true;
 status('Sudah keluar.');
};

let projectRows=[],editingProjectId=null;
function renderProjectList(){
 const query=$('#projectSearch').value.trim().toLowerCase();
 const rows=query?projectRows.filter(p=>(p.code+' '+p.name).toLowerCase().includes(query)):projectRows;
 $('#projectList').innerHTML=rows.length?rows.map(p=>`<div class="progress-card">
  <div class="pc-item">${escapeHtml(p.code)} — ${escapeHtml(p.name)}</div>
  <div class="pc-meta">
   Owner: ${escapeHtml(p.client||'Belum diisi')}<br>
   Kontraktor: ${escapeHtml(p.contractorName||'Belum diisi')}<br>
   Konsultan: ${escapeHtml(p.supervisorConsultant||'Belum diisi')}
  </div>
  <button type="button" class="primary" data-edit-project="${p.id}">Edit</button>
 </div>`).join(''):'<p class="empty">Gak ada proyek yang cocok.</p>';
}
$('#btnLoadProjects').onclick=busy($('#btnLoadProjects'),async()=>{
 projectRows=await api('list_projects');
 renderProjectList();
 status(projectRows.length+' proyek tersedia.');
});
$('#projectSearch').addEventListener('input',renderProjectList);
$('#projectList').addEventListener('click',e=>{
 const btn=e.target.closest('[data-edit-project]');
 if(!btn)return;
 const project=projectRows.find(p=>p.id===btn.dataset.editProject);
 if(!project)return;
 editingProjectId=project.id;
 $('#projectEditTitle').textContent='Edit Info Proyek — '+project.code+' / '+project.name;
 $('#peClient').value=project.client||'';
 $('#peContractor').value=project.contractorName||'';
 $('#peConsultant').value=project.supervisorConsultant||'';
 $('#projectEditStatus').textContent='';
 $('#projectEditCard').hidden=false;
 $('#projectEditCard').scrollIntoView({behavior:'smooth',block:'start'});
});
$('#btnCancelEdit').onclick=()=>{$('#projectEditCard').hidden=true;editingProjectId=null};
$('#btnSaveProjectInfo').onclick=busy($('#btnSaveProjectInfo'),async()=>{
 if(!editingProjectId){$('#projectEditStatus').textContent='Pilih proyek dulu.';return}
 await api('save_project_info',{
  projectId:editingProjectId,
  client:$('#peClient').value.trim(),
  contractorName:$('#peContractor').value.trim(),
  supervisorConsultant:$('#peConsultant').value.trim()
 });
 $('#projectEditStatus').textContent='Tersimpan.';
 projectRows=await api('list_projects');
 renderProjectList();
});
