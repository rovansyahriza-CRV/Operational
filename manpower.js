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
const FACE_MATCH_THRESHOLD=0.5;
const FACE_MODEL_URL="https://cdn.jsdelivr.net/gh/justadudewhohacks/face-api.js/weights";
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
 resetManpowerForm();
 $('#mpMethodCard').hidden=!has;
 if(has)await refreshActiveList();
 else $('#mpActiveList').innerHTML='<p class="empty">Pilih WO buat lihat tim yang sedang check-in.</p>';
});

function showOnly(id){
 for(const x of ['mpMethodCard','mpPinCard','mpCamCard','mpIdentifiedCard'])$('#'+x).hidden=(x!==id);
}

function resetManpowerForm(){
 stopMpCamera();
 $('#mpEmployeeSearch').value='';$('#mpEmployeeId').value='';
 $('#mpEmployeeSuggestions').hidden=true;$('#mpEmployeeSuggestions').replaceChildren();
 $('#mpEmployeeStatus').textContent='';
 $('#mpPin').value='';
 $('#mpActionError').textContent='';
 $('#mpCamStatus').textContent='';
 $('#mpMethodCard').hidden=true;$('#mpPinCard').hidden=true;$('#mpCamCard').hidden=true;$('#mpIdentifiedCard').hidden=true;
 if($('#mpWo').value)$('#mpMethodCard').hidden=false;
}

function setIdentified(id,name){
 $('#mpEmployeeId').value=String(id);
 $('#mpIdentifiedName').textContent='Dipilih: '+name+'. Minta anggota tim masukkan PIN sendiri.';
 stopMpCamera();
 showOnly('mpIdentifiedCard');
 $('#mpPin').value='';$('#mpPin').focus();
}

$('#mpChangeIdentity').onclick=()=>{$('#mpEmployeeId').value='';showOnly('mpMethodCard')};
$('#mpMethodPin').onclick=()=>showOnly('mpPinCard');
$('#mpCancelMethod1').onclick=()=>showOnly('mpMethodCard');
$('#mpCancelMethod2').onclick=()=>{stopMpCamera();showOnly('mpMethodCard')};

// --- Cari anggota tim (metode: Input PIN / cari nama) ---
let mpSearchTimer,mpSearchVersion=0;
$('#mpEmployeeSearch').addEventListener('input',()=>{
 clearTimeout(mpSearchTimer);const version=++mpSearchVersion,query=$('#mpEmployeeSearch').value.trim();
 $('#mpEmployeeSuggestions').replaceChildren();$('#mpEmployeeSuggestions').hidden=true;
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
    button.onclick=()=>{++mpSearchVersion;setIdentified(row.id,row.nama)};
    $('#mpEmployeeSuggestions').append(button);
   }
   $('#mpEmployeeSuggestions').hidden=!$('#mpEmployeeSuggestions').children.length;
  }catch(err){if(version===mpSearchVersion)$('#mpEmployeeStatus').textContent='Pencarian gagal. Ketik ulang untuk mencoba lagi.'}
 },300);
});

// --- Kamera bersama (metode: Scan QR Code / Scan Wajah) ---
const mpVideo=$('#mpVideo'),mpCanvas=$('#mpCanvas');
let mpFacingMode='environment',mpCamMode=null,mpQrScanning=false,mpFaceModelsLoaded=false,mpFaceCache=null;

async function startMpCamera(){
 stopMpCamera(false);
 const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:mpFacingMode}});
 mpVideo.srcObject=stream;
 await mpVideo.play();
}
function stopMpCamera(alsoStopLoops=true){
 if(alsoStopLoops)mpQrScanning=false;
 if(mpVideo.srcObject){mpVideo.srcObject.getTracks().forEach(t=>t.stop());mpVideo.srcObject=null}
}
$('#mpCamSwitch').onclick=async()=>{
 mpFacingMode=mpFacingMode==='user'?'environment':'user';
 try{await startMpCamera()}catch(err){$('#mpCamStatus').textContent='Gagal ganti kamera: '+err.message}
};

async function resolveByQrCode(qr){
 const result=await manpowerApi('find_by_qrcode',{qrCode:qr});
 setIdentified(result.employeeId,result.name);
}

// --- Metode: Scan QR Code ---
$('#mpMethodQr').onclick=async()=>{
 mpCamMode='qr';
 showOnly('mpCamCard');
 $('#mpCamLabel').textContent='Arahkan QR badge karyawan ke kamera.';
 $('#mpCamScan').hidden=true;$('#mpCamStatus').textContent='Menyiapkan kamera...';
 try{await startMpCamera()}catch(err){$('#mpCamStatus').textContent='Gagal akses kamera: '+err.message;return}
 $('#mpCamStatus').textContent='Mencari QR code...';
 mpQrScanning=true;
 scanMpQrLoop();
};
async function scanMpQrLoop(){
 const ctx=mpCanvas.getContext('2d',{willReadFrequently:true});
 while(mpQrScanning&&mpCamMode==='qr'){
  if(mpVideo.readyState===mpVideo.HAVE_ENOUGH_DATA){
   mpCanvas.width=mpVideo.videoWidth;mpCanvas.height=mpVideo.videoHeight;
   ctx.drawImage(mpVideo,0,0,mpCanvas.width,mpCanvas.height);
   const imageData=ctx.getImageData(0,0,mpCanvas.width,mpCanvas.height);
   const code=jsQR(imageData.data,imageData.width,imageData.height,{inversionAttempts:'attemptBoth'});
   if(code&&code.data){
    mpQrScanning=false;
    let raw=code.data.trim();
    try{const url=new URL(raw);const p=url.searchParams.get('QrCodeId')||url.searchParams.get('qrCodeId')||url.searchParams.get('qrcodeid');if(p)raw=p}catch(e){}
    $('#mpCamStatus').textContent='QR terbaca, memverifikasi...';
    try{await resolveByQrCode(raw.toUpperCase())}
    catch(err){$('#mpCamStatus').textContent='❌ '+err.message;mpQrScanning=true;scanMpQrLoop()}
    return;
   }
  }
  await new Promise(r=>setTimeout(r,150));
 }
}

// --- Metode: Scan Wajah ---
async function loadFaceModelsOnce(){
 if(mpFaceModelsLoaded)return;
 await faceapi.nets.tinyFaceDetector.loadFromUri(FACE_MODEL_URL);
 await faceapi.nets.faceLandmark68Net.loadFromUri(FACE_MODEL_URL);
 await faceapi.nets.faceRecognitionNet.loadFromUri(FACE_MODEL_URL);
 mpFaceModelsLoaded=true;
}
$('#mpMethodFace').onclick=async()=>{
 mpCamMode='face';
 showOnly('mpCamCard');
 $('#mpCamLabel').textContent='Posisikan wajah anggota tim di kamera, lalu tekan Scan Sekarang.';
 $('#mpCamScan').hidden=false;$('#mpCamStatus').textContent='Memuat model wajah...';
 try{
  await loadFaceModelsOnce();
  if(!mpFaceCache)mpFaceCache=await rpc('get_all_face_data',{});
 }catch(err){$('#mpCamStatus').textContent='Gagal memuat data wajah: '+err.message;return}
 if(!mpFaceCache||!mpFaceCache.length){$('#mpCamStatus').textContent='Belum ada data wajah terdaftar.';return}
 $('#mpCamStatus').textContent='Menyiapkan kamera...';
 try{await startMpCamera()}catch(err){$('#mpCamStatus').textContent='Gagal akses kamera: '+err.message;return}
 $('#mpCamStatus').textContent='Posisikan wajah, lalu tekan Scan Sekarang.';
};
$('#mpCamScan').onclick=async()=>{
 if(mpCamMode!=='face')return;
 $('#mpCamScan').disabled=true;
 $('#mpCamStatus').textContent='Mendeteksi wajah...';
 try{
  const snap=document.createElement('canvas');
  snap.width=mpVideo.videoWidth||640;snap.height=mpVideo.videoHeight||480;
  snap.getContext('2d').drawImage(mpVideo,0,0,snap.width,snap.height);
  const detection=await faceapi.detectSingleFace(snap,new faceapi.TinyFaceDetectorOptions({inputSize:416,scoreThreshold:0.3})).withFaceLandmarks().withFaceDescriptor();
  if(!detection){$('#mpCamStatus').textContent='Wajah tidak terdeteksi, coba lagi.';return}
  let best=null,bestDistance=Infinity;
  for(const person of mpFaceCache){
   if(!person.descriptor)continue;
   const d=faceapi.euclideanDistance(detection.descriptor,person.descriptor);
   if(d<bestDistance){bestDistance=d;best=person}
  }
  if(!best||bestDistance>FACE_MATCH_THRESHOLD){$('#mpCamStatus').textContent=`Wajah tidak dikenali (jarak terdekat: ${bestDistance.toFixed(3)}). Coba lagi atau pakai metode lain.`;return}
  $('#mpCamStatus').textContent='Wajah cocok, memverifikasi...';
  await resolveByQrCode(best.qrCodeId);
 }catch(err){$('#mpCamStatus').textContent='❌ '+err.message}
 finally{$('#mpCamScan').disabled=false}
};

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
