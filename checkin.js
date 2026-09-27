'use strict';
// Tab "Check-in Tim" di progress.html (dulu halaman terpisah manpower.html). Numpang login,
// WO (#progressWo), rpc/manpowerApi/busy/status dari progress.js -- script ini di-load sesudahnya.
const FACE_MATCH_THRESHOLD=0.5;
const FACE_MODEL_URL='https://cdn.jsdelivr.net/gh/justadudewhohacks/face-api.js/weights';
const CHECKIN_LIBS={
 jsQR:'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
 faceapi:'https://cdn.jsdelivr.net/npm/face-api.js@0.22.2/dist/face-api.min.js'
};

// Library kamera (face-api ~1 MB) baru dimuat pas dipakai, biar tab Progress tetap ringan.
const libLoads={};
function loadLib(name){
 if(window[name])return Promise.resolve();
 if(!libLoads[name])libLoads[name]=new Promise((resolve,reject)=>{
  const s=document.createElement('script');s.src=CHECKIN_LIBS[name];
  s.onload=()=>resolve();s.onerror=()=>{delete libLoads[name];reject(Error('Gagal memuat library '+name+', cek koneksi.'))};
  document.head.append(s);
 });
 return libLoads[name];
}

// --- Tab ---
let activeTab='progress';
const TABS={dashboard:['#tabDashboard','#dashboardPane'],progress:['#tabProgress','#progressPane'],checkin:['#tabCheckin','#checkinPane']};
function showTab(tab,refresh=true){
 activeTab=tab;
 for(const [name,[tabId,paneId]] of Object.entries(TABS)){
  $(paneId).hidden=tab!==name;
  $(tabId).classList.toggle('active',tab===name);$(tabId).setAttribute('aria-selected',String(tab===name));
 }
 $('#woBar').hidden=tab==='dashboard'; // Dashboard pilih project sendiri, bukan WO
 try{history.replaceState(null,'',tab==='progress'?location.pathname+location.search:'#'+tab)}catch(err){}
 if(tab!=='checkin'||!refresh)stopMpCamera();
 if(!refresh)return;
 if(tab==='checkin')enterCheckin();
 else if(tab==='dashboard')enterDashboard();
 else refreshManpowerForDate();
}
for(const name of Object.keys(TABS))$(TABS[name][0]).onclick=()=>showTab(name);

// --- Glue Dashboard (dashboard.js) buat halaman ini ---
window.dashboardOpenWo=async woId=>{
 if(await selectProgressWo(woId)){showTab('progress');window.scrollTo({top:0,behavior:'smooth'})}
};
// Pas login selesai (progressSection jadi kelihatan) dan tab aktif Dashboard, langsung muat.
new MutationObserver(()=>{if(!$('#progressSection').hidden&&activeTab==='dashboard')enterDashboard()})
 .observe($('#progressSection'),{attributes:true,attributeFilter:['hidden']});
$('#logout').addEventListener('click',()=>resetDashboard());

// PIC/Foreman udah login pakai username+password -- itu cukup buat identitas DIA SENDIRI, jadi
// begitu buka tab Check-in dengan WO terpilih, dia otomatis check-in (sekali per WO per buka
// halaman). Sengaja bukan pas pilih WO: yang cuma buka Progress/laporan gak ikut tercatat hadir.
const selfCheckinDone=new Set();
async function enterCheckin(){
 const woId=$('#progressWo').value;
 resetManpowerForm();
 $('#mpPickWo').hidden=!!woId;
 if(!woId||!opSession){$('#mpActiveList').innerHTML='<p class="empty">Pilih WO buat lihat tim yang sedang check-in.</p>';return}
 try{await refreshActiveList()}catch(err){status(err.message)}
 if(selfCheckinDone.has(woId))return;
 selfCheckinDone.add(woId);
 try{
  const result=await manpowerApi('checkin_self',{woId});
  if(result.status==='ok'){status('Kamu ('+result.employeeName+') otomatis check-in di WO ini.');await refreshActiveList()}
  else if(result.status==='elsewhere')status('Kamu masih check-in di WO lain -- check-out dulu kalau mau pindah.');
 }catch(err){selfCheckinDone.delete(woId)}
}
$('#progressWo').addEventListener('change',()=>{$('#mpResult').textContent='';if(activeTab==='checkin')enterCheckin();else resetManpowerForm()});
$('#logout').addEventListener('click',()=>{
 selfCheckinDone.clear();resetManpowerForm();setMode('checkin');
 $('#mpResult').textContent='';$('#mpPickWo').hidden=false;
 $('#mpActiveList').innerHTML='<p class="empty">Pilih WO buat lihat tim yang sedang check-in.</p>';
 showTab('progress',false);
});

// --- Mode: Check In / Check Out (dipilih dulu, sebelum identifikasi) ---
let mpMode='checkin';
function setMode(mode){
 mpMode=mode;
 $('#mpModeIn').className=mode==='checkin'?'primary':'';
 $('#mpModeOut').className=mode==='checkout'?'primary':'';
}
$('#mpModeIn').onclick=()=>setMode('checkin');
$('#mpModeOut').onclick=()=>setMode('checkout');

function showOnly(id){
 for(const x of ['mpMethodCard','mpPinCard','mpCamCard'])$('#'+x).hidden=(x!==id);
}
function resetManpowerForm(){
 stopMpCamera();
 $('#mpPinInput').value='';$('#mpPinStatus').textContent='';
 $('#mpCamStatus').textContent='';
 $('#mpMethodCard').hidden=true;$('#mpPinCard').hidden=true;$('#mpCamCard').hidden=true;
 if($('#progressWo').value)$('#mpMethodCard').hidden=false;
}
function showResult(ok,text){
 $('#mpResult').textContent=(ok?'✅ ':'❌ ')+text;
 $('#mpResult').style.color=ok?'var(--success)':'var(--danger)';
}
async function afterCheckinChange(name){
 showResult(true,name+' berhasil '+(mpMode==='checkin'?'check-in':'check-out')+'.');
 resetManpowerForm();
 await refreshActiveList();
 refreshManpowerForDate();
}

// Satu titik eksekusi buat ketiga metode -- begitu identitas didapat (QR/wajah/PIN),
// langsung checkin/checkout, TIDAK ada langkah minta PIN lagi sesudahnya.
async function performByQrCode(qr){
 const woId=$('#progressWo').value;
 const action=mpMode==='checkin'?'checkin_by_qrcode':'checkout_by_qrcode';
 const data=mpMode==='checkin'?{woId,qrCode:qr}:{qrCode:qr};
 const result=await manpowerApi(action,data);
 return result.employeeName;
}
async function performByPin(pin){
 const woId=$('#progressWo').value;
 const action=mpMode==='checkin'?'checkin_by_pin':'checkout_by_pin';
 const data=mpMode==='checkin'?{woId,pin}:{pin};
 const result=await manpowerApi(action,data);
 return result.employeeName;
}

$('#mpMethodPin').onclick=()=>{showOnly('mpPinCard');$('#mpPinLabel').textContent=mpMode==='checkin'?'Anggota tim ketik PIN sendiri untuk Check In.':'Anggota tim ketik PIN sendiri untuk Check Out.';$('#mpPinInput').value='';$('#mpPinStatus').textContent='';$('#mpPinInput').focus()};
$('#mpCancelMethod1').onclick=()=>showOnly('mpMethodCard');
$('#mpCancelMethod2').onclick=()=>{stopMpCamera();showOnly('mpMethodCard')};

$('#mpPinSubmit').onclick=busy($('#mpPinSubmit'),async()=>{
 const pin=$('#mpPinInput').value.trim();
 $('#mpPinStatus').textContent='';
 if(!/^\d+$/.test(pin)){$('#mpPinStatus').textContent='PIN harus angka.';return}
 try{await afterCheckinChange(await performByPin(pin))}
 catch(err){$('#mpPinStatus').textContent=err.message}
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

// --- Metode: Scan QR Code ---
$('#mpMethodQr').onclick=async()=>{
 mpCamMode='qr';
 showOnly('mpCamCard');
 $('#mpCamLabel').textContent='Arahkan QR badge karyawan ke kamera.';
 $('#mpCamScan').hidden=true;$('#mpCamStatus').textContent='Menyiapkan kamera...';
 try{await loadLib('jsQR');await startMpCamera()}catch(err){$('#mpCamStatus').textContent='Gagal akses kamera: '+err.message;return}
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
    try{await afterCheckinChange(await performByQrCode(raw.toUpperCase()))}
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
 await loadLib('faceapi');
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
  await afterCheckinChange(await performByQrCode(best.qrCodeId));
 }catch(err){$('#mpCamStatus').textContent='❌ '+err.message}
 finally{$('#mpCamScan').disabled=false}
};

async function refreshActiveList(){
 const woId=$('#progressWo').value;if(!woId)return;
 const rows=await manpowerApi('active_checkins',{woId});
 $('#mpActiveList').innerHTML=rows.map(r=>`<div class="mp-card"><span class="mp-name">${escapeHtml(r.employee_name)}</span><span class="mp-time">Masuk ${new Date(r.check_in_at).toLocaleTimeString('id-ID',{hour:'2-digit',minute:'2-digit'})}</span></div>`).join('')||'<p class="empty">Belum ada yang check-in di WO ini.</p>';
}

// Tab awal dari link: progress.html#dashboard / #checkin (manpower.html lama -> #checkin).
if(location.hash==='#checkin')showTab('checkin');
else if(location.hash==='#dashboard')showTab('dashboard');
