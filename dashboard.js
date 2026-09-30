'use strict';
// Dashboard: pilih project -> progress per WO (realisasi vs rencana) + kurva-S & rincian item.
// Dipakai dua halaman: menu "05 Dashboard" di index.html (panel desktop) dan tab Dashboard di
// progress.html (HP). Butuh global $, escapeHtml, rpc, opSession, busy, status dari halamannya
// + elemen #dbProject/#dbRefresh/#dbSummary/#dbWoList. Halaman boleh pasang
// window.dashboardOpenWo(woId) buat tombol "Buka Progress".
async function dashboardApi(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_dashboard',{p_token:opSession.token,p_action:action,p_data:data})}
const DAY_MS=86400000;
const pct=v=>(v==null?'—':(Math.round(v*10)/10).toLocaleString('id-ID',{minimumFractionDigits:1,maximumFractionDigits:1})+'%');
const rupiah=v=>{const n=Number(v)||0;if(n>=1e9)return 'Rp '+(n/1e9).toLocaleString('id-ID',{maximumFractionDigits:2})+' M';if(n>=1e6)return 'Rp '+(n/1e6).toLocaleString('id-ID',{maximumFractionDigits:1})+' jt';return 'Rp '+n.toLocaleString('id-ID')};
// Nilai progres (earned value) ditampilkan penuh sampai rupiah, bukan "jt", biar bisa dicocokkan ke tagihan.
const rupiahFull=v=>'Rp '+Math.round(Number(v)||0).toLocaleString('id-ID');
const parseDate=s=>s?new Date(s+'T00:00:00'):null;
const fmtDate=d=>d.toLocaleDateString('id-ID',{day:'numeric',month:'short'});
// Deviasi lebih buruk dari ini (poin %) dianggap terlambat.
const LATE_THRESHOLD=-5;

// Rencana linier: 0% di Mulai WO, 100% di Akhir WO. null kalau tanggal WO belum diisi.
function planAt(wo,date){
 const s=parseDate(wo.startDate),e=parseDate(wo.endDate);
 if(!s||!e||e<=s)return null;
 return Math.min(100,Math.max(0,(date-s)/(e-s)*100));
}

let dbProjectsLoaded=false,dbData=null,dbLoadVersion=0;
const dbDetailCache=new Map();

// Search box No./Judul WO -- dibikin di sini (bukan di HTML) biar sama persis di dua halaman.
// Filter cuma nyembunyiin kartu, jadi kurva-S yang lagi kebuka gak ketutup pas ngetik.
const dbSearchWrap=document.createElement('div');
dbSearchWrap.className='db-search';dbSearchWrap.hidden=true;
dbSearchWrap.innerHTML='<input id="dbSearch" type="search" placeholder="🔍 Cari No. WO atau judul WO..." autocomplete="off" aria-label="Cari No. WO atau judul WO"><span id="dbSearchCount" class="db-hint" role="status"></span>';
$('#dbWoList').before(dbSearchWrap);
function applyWoFilter(){
 if(!dbData)return;
 const q=$('#dbSearch').value.trim().toLowerCase();
 let shown=0;
 document.querySelectorAll('#dbWoList .db-wo').forEach(card=>{
  const w=dbData.wos.find(x=>x.id===card.dataset.wo);
  const match=!q||(w.number+' '+(w.title||'')).toLowerCase().includes(q);
  card.hidden=!match;if(match)shown++;
 });
 let none=$('#dbNoMatch');
 if(!none){none=document.createElement('p');none.id='dbNoMatch';none.className='empty';$('#dbWoList').append(none)}
 none.hidden=shown>0||!dbData.wos.length;
 none.textContent='Gak ada WO yang cocok dengan "'+$('#dbSearch').value.trim()+'".';
 $('#dbSearchCount').textContent=q?shown+' dari '+dbData.wos.length+' WO':'';
}
$('#dbSearch').addEventListener('input',applyWoFilter);
async function enterDashboard(){
 if(!opSession)return;
 if(!dbProjectsLoaded){
  try{
   const rows=await dashboardApi('projects');
   $('#dbProject').innerHTML='<option value="">Pilih project</option>'+rows.map(p=>`<option value="${escapeHtml(p.id)}">${escapeHtml(p.code+' — '+p.name)} (${p.woCount} WO)</option>`).join('');
   dbProjectsLoaded=true;
   let remembered='';try{remembered=localStorage.getItem('opDashboardProject')||''}catch(err){}
   const pick=rows.some(p=>p.id===remembered)?remembered:(rows.length===1?rows[0].id:'');
   if(pick){$('#dbProject').value=pick;await loadProjectDashboard()}
  }catch(err){$('#dbWoList').innerHTML='<p class="empty">Gagal memuat project: '+escapeHtml(err.message)+'</p>'}
 }else if($('#dbProject').value)await loadProjectDashboard();
}
$('#dbProject').addEventListener('change',()=>{try{localStorage.setItem('opDashboardProject',$('#dbProject').value)}catch(err){}loadProjectDashboard()});
$('#dbRefresh').onclick=busy($('#dbRefresh'),async()=>{dbDetailCache.clear();if(!dbProjectsLoaded)await enterDashboard();else await loadProjectDashboard()});

async function loadProjectDashboard(){
 const version=++dbLoadVersion,projectId=$('#dbProject').value;
 dbData=null;$('#dbSummary').innerHTML='';dbSearchWrap.hidden=true;$('#dbSearchCount').textContent='';
 if(!projectId){$('#dbWoList').innerHTML='<p class="empty">Pilih project buat lihat progress per WO.</p>';return}
 $('#dbWoList').innerHTML='<p class="empty">Memuat...</p>';
 try{
  const data=await dashboardApi('project',{projectId});
  if(version!==dbLoadVersion)return;
  dbData=data;renderDashboard();
 }catch(err){if(version===dbLoadVersion)$('#dbWoList').innerHTML='<p class="empty">Gagal memuat: '+escapeHtml(err.message)+'</p>'}
}

function woStatus(wo,today){
 const real=wo.progress*100,plan=planAt(wo,today);
 if(plan==null)return {plan,dev:null,cls:'none',label:'Rencana belum ada — isi Mulai/Akhir WO di Detail Laporan'};
 const dev=real-plan;
 if(dev<LATE_THRESHOLD)return {plan,dev,cls:'late',label:'⚠ Terlambat '+pct(-dev)};
 return {plan,dev,cls:'ok',label:(dev>=0?'✓ Lebih cepat '+pct(dev):'✓ Sesuai rencana ('+pct(dev)+')')};
}

function renderDashboard(){
 const today=parseDate(dbData.today),wos=dbData.wos;
 dbSearchWrap.hidden=!wos.length;
 if(!wos.length){$('#dbWoList').innerHTML='<p class="empty">Project ini belum punya WO.</p>';return}
 const totalValue=wos.reduce((a,w)=>a+Number(w.value||0),0);
 const projectProgress=totalValue>0?wos.reduce((a,w)=>a+w.progress*Number(w.value||0),0)/totalValue*100:wos.reduce((a,w)=>a+w.progress,0)/wos.length*100;
 const earnedValue=wos.reduce((a,w)=>a+w.progress*Number(w.value||0),0);
 const lateCount=wos.filter(w=>woStatus(w,today).cls==='late').length;
 const teamToday=wos.reduce((a,w)=>a+Number(w.teamToday||0),0);
 $('#dbSummary').innerHTML=`<div class="db-tiles">
  <div class="db-tile"><span class="db-tile-label">Progress project</span><span class="db-tile-value">${pct(projectProgress)}</span></div>
  <div class="db-tile"><span class="db-tile-label">Nilai progres</span><span class="db-tile-value">${rupiah(earnedValue)}</span><small class="db-tile-sub">dari ${rupiah(totalValue)} nilai WO</small></div>
  <div class="db-tile"><span class="db-tile-label">WO terlambat</span><span class="db-tile-value">${lateCount} <small>dari ${wos.length}</small></span></div>
  <div class="db-tile"><span class="db-tile-label">Tim hadir hari ini</span><span class="db-tile-value">${teamToday} <small>orang</small></span></div>
 </div>`;
 const working=wos.filter(w=>w.releaseRole!=='RELEASED'),released=wos.filter(w=>w.releaseRole==='RELEASED');
 const group=(title,list)=>list.length?`<div class="db-wo-group"><h3 class="db-group-title">${escapeHtml(title)} (${list.length})</h3><div class="db-wo-grid">${list.map(w=>woCardHtml(w,today)).join('')}</div></div>`:'';
 $('#dbWoList').classList.toggle('db-grouped',working.length>0&&released.length>0);
 $('#dbWoList').innerHTML=group('WO Kerja (Internal)',working)+group('WO Released',released);
 applyWoFilter();
}
function woCardHtml(w,today){
 const st=woStatus(w,today),real=w.progress*100;
 return `<article class="db-wo" data-wo="${escapeHtml(w.id)}">
  <div class="db-wo-head"><div><div class="pc-item">${escapeHtml(w.number)}</div><div class="pc-path">${escapeHtml(w.title||'-')}</div></div><span class="tag">${escapeHtml(w.status)}</span></div>
  <div class="db-bar" role="img" aria-label="Realisasi ${pct(real)}${st.plan!=null?', rencana '+pct(st.plan):''}">
   <div class="db-bar-fill" style="width:${Math.min(100,real)}%"></div>
   ${st.plan!=null?`<div class="db-bar-plan" style="left:${st.plan}%" title="Rencana hari ini ${pct(st.plan)}"></div>`:''}
  </div>
  <div class="db-wo-nums"><span><strong>${pct(real)}</strong> realisasi</span>${st.plan!=null?`<span>${pct(st.plan)} rencana</span>`:''}</div>
  <div class="db-wo-nums db-wo-money"><span><strong>${rupiahFull(w.progress*Number(w.value||0))}</strong></span>${st.plan!=null?`<span>${rupiahFull(st.plan/100*Number(w.value||0))}</span>`:''}</div>
  <div class="db-status db-status-${st.cls}">${escapeHtml(st.label)}</div>
  <div class="pc-meta">Nilai WO ${rupiahFull(w.value)} · ${w.itemCount} item · Tim hari ini ${w.teamToday} orang · Update terakhir ${w.lastProgressDate?fmtDate(parseDate(w.lastProgressDate)):'belum ada'}${w.startDate&&w.endDate?' · '+fmtDate(parseDate(w.startDate))+' – '+fmtDate(parseDate(w.endDate)):''}</div>
  ${w.itemsNoBreakdown?`<p class="db-warn">⚠ ${w.itemsNoBreakdown} item belum ada breakdown ber-target, dihitung 0%.</p>`:''}
  <div class="db-actions"><button type="button" data-db-detail="${escapeHtml(w.id)}">Kurva-S &amp; item ▾</button><button type="button" class="primary" data-db-open="${escapeHtml(w.id)}">Buka Progress →</button></div>
  <div class="db-detail" hidden></div>
 </article>`;
}

$('#dbWoList').addEventListener('click',async e=>{
 const openBtn=e.target.closest('[data-db-open]');
 if(openBtn){if(window.dashboardOpenWo)await window.dashboardOpenWo(openBtn.dataset.dbOpen);return}
 const detailBtn=e.target.closest('[data-db-detail]');
 if(!detailBtn)return;
 const card=detailBtn.closest('.db-wo'),box=card.querySelector('.db-detail'),woId=detailBtn.dataset.dbDetail;
 if(!box.hidden){box.hidden=true;detailBtn.textContent='Kurva-S & item ▾';return}
 box.hidden=false;detailBtn.textContent='Tutup ▴';
 box.innerHTML='<p class="empty">Memuat...</p>';
 try{
  if(!dbDetailCache.has(woId))dbDetailCache.set(woId,await dashboardApi('wo_detail',{woId}));
  renderWoDetail(box,dbData.wos.find(w=>w.id===woId),dbDetailCache.get(woId));
 }catch(err){box.innerHTML='<p class="empty">Gagal memuat: '+escapeHtml(err.message)+'</p>'}
});

// Pilih WO di dropdown #progressWo halaman ini (muat daftar WO dulu kalau belum ada).
// Dipakai glue tiap halaman buat tombol "Buka Progress". true kalau WO ketemu.
async function selectProgressWo(woId){
 if(![...$('#progressWo').options].some(o=>o.value===woId))await $('#progressLoadWos').onclick();
 // Dropdown WO difilter per project -- kalau WO-nya dari project lain, pindahin Kode project dulu.
 if(![...$('#progressWo').options].some(o=>o.value===woId)&&typeof progressWoProjectOf==='function'){
  const code=progressWoProjectOf(woId);if(code&&$('#projectCode').value!==code){$('#projectCode').value=code;$('#projectCode').dispatchEvent(new Event('change'));renderProgressWoOptions()}
 }
 if(![...$('#progressWo').options].some(o=>o.value===woId)){status('WO tidak ada di daftar WO kamu.');return false}
 if($('#progressWo').value!==woId){$('#progressWo').value=woId;$('#progressWo').dispatchEvent(new Event('change'))}
 return true;
}
function resetDashboard(){
 dbProjectsLoaded=false;dbData=null;dbDetailCache.clear();dbLoadVersion++;
 $('#dbSearch').value='';$('#dbSearchCount').textContent='';dbSearchWrap.hidden=true;
 $('#dbProject').innerHTML='<option value="">Pilih project</option>';$('#dbSummary').innerHTML='';
 $('#dbWoList').innerHTML='<p class="empty">Pilih project buat lihat progress per WO.</p>';
}

// Satu item = satu blok bertumpuk (bukan baris tabel) biar muat di kartu sempit & HP.
// progress null = item belum punya breakdown ber-target.
function itemBlock(code,description,weight,progress,earned,amount,isTotal=false){
 return `<div class="db-item${isTotal?' db-item-total':''}">
  <div class="db-item-head"><strong>${escapeHtml(code)}</strong>${description?` <span class="pc-path">${escapeHtml(description)}</span>`:''}</div>
  <div class="db-item-stats">
   <div><span>Bobot</span><b>${pct(weight)}</b></div>
   <div><span>Progress</span><b>${progress==null?'—':pct(progress)}</b>${progress==null?'<small>belum ada breakdown</small>':''}</div>
   <div><span>Nilai progres</span><b>${rupiahFull(earned)}</b><small>dari ${rupiahFull(amount)}</small></div>
  </div>
  ${progress==null?'':`<div class="db-mini"><div style="width:${Math.min(100,progress)}%"></div></div>`}
 </div>`;
}
function renderWoDetail(box,wo,detail){
 const today=parseDate(dbData.today);
 box.innerHTML=`<h3 class="db-sub">Kurva-S (kumulatif)</h3><div class="db-chart"></div>
  <h3 class="db-sub">Progress per item</h3>
  <div class="db-items">
  ${detail.items.map(i=>itemBlock(i.code,i.description,i.weight*100,i.leafCount?i.progress*100:null,Number(i.amount||0)*(i.progress||0),i.amount)).join('')}
  ${itemBlock('Total WO','',100,wo.progress*100,wo.progress*Number(wo.value||0),wo.value,true)}
  </div>`;
 renderSCurve(box.querySelector('.db-chart'),wo,detail.series,today);
}

// Kurva-S: Realisasi (slot 1) vs Rencana (slot 2), satu sumbu 0-100%, crosshair + tooltip.
function renderSCurve(el,wo,series,today){
 const start=parseDate(wo.startDate),end=parseDate(wo.endDate),hasPlan=planAt(wo,today)!=null;
 const pts=series.map(s=>({d:parseDate(s.date),v:s.progress*100}));
 let x0=hasPlan?start:(pts[0]?.d||today),x1=hasPlan?end:(pts.length?pts[pts.length-1].d:today);
 if(pts.length){x0=new Date(Math.min(x0,pts[0].d));x1=new Date(Math.max(x1,pts[pts.length-1].d))}
 if(x1<=x0)x1=new Date(+x0+DAY_MS);
 const real=(hasPlan&&(!pts.length||pts[0].d>start)?[{d:start,v:0}]:[]).concat(pts);
 if(!real.length){el.innerHTML='<p class="empty">Belum ada progress tercatat.</p>';return}
 const W=480,H=220,m={l:40,r:16,t:14,b:26},iw=W-m.l-m.r,ih=H-m.t-m.b;
 const X=d=>m.l+(d-x0)/(x1-x0)*iw,Y=v=>m.t+ih-v/100*ih;
 const path=a=>a.map((p,i)=>(i?'L':'M')+X(p.d).toFixed(1)+' '+Y(p.v).toFixed(1)).join(' ');
 const grid=[0,25,50,75,100].map(v=>`<line x1="${m.l}" x2="${W-m.r}" y1="${Y(v)}" y2="${Y(v)}" class="db-grid"/><text x="${m.l-6}" y="${Y(v)+4}" class="db-axis" text-anchor="end">${v}%</text>`).join('');
 const xTicks=[x0,new Date((+x0 + +x1)/2),x1].map((d,i)=>`<text x="${X(d)}" y="${H-6}" class="db-axis" text-anchor="${['start','middle','end'][i]}">${fmtDate(d)}</text>`).join('');
 const todayLine=today>=x0&&today<=x1?`<line x1="${X(today)}" x2="${X(today)}" y1="${m.t}" y2="${m.t+ih}" class="db-today"/><text x="${X(today)+4}" y="${m.t+10}" class="db-axis">Hari ini</text>`:'';
 const last=real[real.length-1];
 el.innerHTML=`<div class="db-legend"><span><i class="db-key db-key-real"></i>Realisasi</span>${hasPlan?'<span><i class="db-key db-key-plan"></i>Rencana</span>':''}</div>
  <div class="db-svg-wrap"><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Kurva-S ${escapeHtml(wo.number)}: realisasi ${pct(last.v)}${hasPlan?', rencana hari ini '+pct(planAt(wo,today)):''}">
   ${grid}${xTicks}${todayLine}
   ${hasPlan?`<path d="M${X(start)} ${Y(0)} L${X(end)} ${Y(100)}" class="db-line db-line-plan"/>`:''}
   <path d="${path(real)}" class="db-line db-line-real"/>
   ${pts.map(p=>`<circle cx="${X(p.d)}" cy="${Y(p.v)}" r="4" class="db-dot"/>`).join('')}
   <text x="${Math.min(X(last.d)+6,W-m.r-40)}" y="${Y(last.v)-8}" class="db-label">${pct(last.v)}</text>
   <line class="db-cross" y1="${m.t}" y2="${m.t+ih}" visibility="hidden"/>
   <rect x="${m.l}" y="${m.t}" width="${iw}" height="${ih}" fill="transparent" class="db-hit"/>
  </svg><div class="db-tip" hidden></div></div>`;
 const svg=el.querySelector('svg'),cross=el.querySelector('.db-cross'),tip=el.querySelector('.db-tip');
 const valueAt=d=>{let v=null;for(const p of real)if(p.d<=d)v=p.v;return v};
 const lastReal=last.d;
 svg.querySelector('.db-hit').addEventListener('pointermove',ev=>{
  const r=svg.getBoundingClientRect(),sx=(ev.clientX-r.left)/r.width*W;
  const d=new Date(+x0+Math.round(((sx-m.l)/iw*(x1-x0))/DAY_MS)*DAY_MS);
  if(d<x0||d>x1)return;
  const x=X(d);cross.setAttribute('x1',x);cross.setAttribute('x2',x);cross.setAttribute('visibility','visible');
  const rv=d<=lastReal?valueAt(d):null,pv=hasPlan?planAt(wo,d):null;
  tip.hidden=false;tip.replaceChildren();
  const head=document.createElement('strong');head.textContent=d.toLocaleDateString('id-ID',{weekday:'short',day:'numeric',month:'short',year:'numeric'});tip.append(head);
  for(const [k,label,v] of [['real','Realisasi',rv],['plan','Rencana',pv]]){
   if(k==='plan'&&!hasPlan)continue;
   const row=document.createElement('div');const key=document.createElement('i');key.className='db-key db-key-'+k;
   row.append(key,document.createTextNode(label+': '+(v==null?'—':pct(v))));tip.append(row);
  }
  const left=x/W*r.width;tip.style.left=Math.min(Math.max(left-70,0),r.width-150)+'px';
 });
 svg.querySelector('.db-hit').addEventListener('pointerleave',()=>{cross.setAttribute('visibility','hidden');tip.hidden=true});
}
