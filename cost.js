'use strict';
// Menu "06 Cost vs Progress": biaya resource yang kepakai per WO Kerja (manpower dari check-in WO x rate
// Fusion 4, material dari pemakaian x harga PO SMMS) dibanding earned value dari akumulasi Daily Progress.
// Semua angka dihitung server (op_cost). Butuh PIC 'Operational Cost'. Dimuat sesudah connection.js &
// dashboard.js -- numpang $, rpc, busy, status, escapeHtml, rupiah, rupiahFull, pct, parseDate, fmtDate, DAY_MS.
async function costApi(action,data={}){if(!opSession)throw Error('Login terlebih dahulu.');return rpc('op_cost',{p_token:opSession.token,p_action:action,p_data:data})}
let costProjectsLoaded=false,costRows=null,costOpenWo='',costLoadVersion=0;
const costDetailCache=new Map();
const costKindLabel={DIRECT:'Direct',INDIRECT:'Indirect / PMT',OVERHEAD:'Overhead'};
const num=v=>Number(v)||0;
const hours=v=>num(v).toLocaleString('id-ID',{maximumFractionDigits:1})+' jam';
const cpiText=(earned,cost)=>cost>0?(earned/cost).toLocaleString('id-ID',{minimumFractionDigits:2,maximumFractionDigits:2}):'—';
// Selisih negatif = biaya di atas nilai progress: tanda + warna + kata, gak cuma warna.
const diffHtml=(earned,cost)=>{const d=earned-cost;if(!cost&&!earned)return '<span class="cost-muted">—</span>';return d<0?`<span class="cost-bad">▼ ${rupiah(-d)} <small>rugi</small></span>`:`<span class="cost-good">▲ ${rupiah(d)} <small>untung</small></span>`};

const prevCostTab=tab;
tab=function(name){
 prevCostTab(name);
 if(!canOpenPage(name))return;
 $('#cost').hidden=name!=='cost';
 if(name!=='cost')return;
 $('#contractBinding').hidden=true;$('#contractContext').hidden=true;
 $('#pageEyebrow').textContent='COST CONTROL';$('#pageTitle').textContent='Cost vs Progress';
 $('#pageDescription').textContent='Biaya resource terpakai per WO dibanding nilai progress yang udah dicapai.';
 enterCost();
};

async function enterCost(){
 if(!opSession)return;
 if(costProjectsLoaded){if($('#costProject').value)await loadCostProject();return}
 try{
  const rows=await costApi('projects');
  $('#costProject').innerHTML='<option value="">Pilih project</option>'+rows.map(p=>`<option value="${escapeHtml(p.id)}">${escapeHtml(p.code+' — '+p.name)} (${p.woCount} WO)</option>`).join('');
  costProjectsLoaded=true;
  let remembered='';try{remembered=localStorage.getItem('opCostProject')||''}catch(err){}
  const pick=rows.some(p=>p.id===remembered)?remembered:(rows.length===1?rows[0].id:'');
  if(pick){$('#costProject').value=pick;await loadCostProject()}
 }catch(err){$('#costTable').innerHTML='<p class="empty">Gagal memuat project: '+escapeHtml(err.message)+'</p>'}
}
$('#costProject').addEventListener('change',()=>{try{localStorage.setItem('opCostProject',$('#costProject').value)}catch(err){}costOpenWo='';loadCostProject()});
$('#costRefresh').onclick=busy($('#costRefresh'),async()=>{costDetailCache.clear();if(!costProjectsLoaded)await enterCost();else await loadCostProject()});

async function loadCostProject(){
 const version=++costLoadVersion,projectId=$('#costProject').value;
 costRows=null;$('#costSummary').innerHTML='';$('#costDetail').innerHTML='';
 if(!projectId){$('#costTable').innerHTML='<p class="empty">Pilih project buat lihat biaya vs progress per WO.</p>';return}
 $('#costTable').innerHTML='<p class="empty">Memuat...</p>';
 try{
  const rows=await costApi('project',{projectId});
  if(version!==costLoadVersion)return;
  costRows=rows.map(r=>({...r,value:num(r.value),earned:num(r.earned),mp_hours:num(r.mp_hours),mp_cost:num(r.mp_cost),mp_unpriced_hours:num(r.mp_unpriced_hours),material_cost:num(r.material_cost),material_unpriced:num(r.material_unpriced)}));
  renderCost();
  if(costOpenWo&&costRows.some(r=>r.id===costOpenWo))openCostWo(costOpenWo);else costOpenWo='';
 }catch(err){if(version===costLoadVersion)$('#costTable').innerHTML='<p class="empty">Gagal memuat: '+escapeHtml(err.message)+'</p>'}
}

function renderCost(){
 const rows=costRows||[];
 const t=rows.reduce((a,r)=>({value:a.value+r.value,earned:a.earned+r.earned,mp:a.mp+r.mp_cost,mat:a.mat+r.material_cost,unpriced:a.unpriced+r.mp_unpriced_hours+r.material_unpriced}),{value:0,earned:0,mp:0,mat:0,unpriced:0});
 const cost=t.mp+t.mat;
 $('#costSummary').innerHTML=`<div class="db-tiles cost-tiles">
  <div class="db-tile"><span class="db-tile-label">Nilai progress (earned)</span><span class="db-tile-value">${rupiah(t.earned)}</span><small>${t.value?pct(t.earned/t.value*100)+' dari nilai WO '+rupiah(t.value):'Belum ada nilai SMS'}</small></div>
  <div class="db-tile"><span class="db-tile-label">Biaya resource</span><span class="db-tile-value">${rupiah(cost)}</span><small>Manpower ${rupiah(t.mp)} · Material ${rupiah(t.mat)}</small></div>
  <div class="db-tile"><span class="db-tile-label">Selisih (earned − biaya)</span><span class="db-tile-value">${diffHtml(t.earned,cost)}</span><small>WO Indirect/PMT gak punya nilai progress, jadi murni biaya</small></div>
  <div class="db-tile"><span class="db-tile-label">CPI (earned ÷ biaya)</span><span class="db-tile-value">${cpiText(t.earned,cost)}</span><small>&gt; 1 = biaya masih di bawah nilai progress</small></div>
 </div>${t.unpriced?'<p class="banner">Ada resource yang belum ada harganya (karyawan tanpa payroll/kontrak Fusion 4, atau material tanpa harga PO) -- dihitung Rp 0. Cek kolom Manpower/Material yang bertanda ⚠.</p>':''}`;
 if(!rows.length){$('#costTable').innerHTML='<p class="empty">Belum ada WO Kerja di project ini.</p>';return}
 $('#costTable').innerHTML=`<div class="table-wrap"><table class="cost-table"><thead><tr>
  <th>WO</th><th class="num">Nilai WO</th><th class="num">Progress</th><th class="num">Earned</th><th class="num">Manpower</th><th class="num">Material</th><th class="num">Total biaya</th><th class="num">Selisih</th><th class="num">CPI</th></tr></thead><tbody>
  ${rows.map(r=>{const c=r.mp_cost+r.material_cost;return `<tr data-cost-wo="${escapeHtml(r.id)}" class="${r.id===costOpenWo?'cost-open':''}" tabindex="0">
   <td><strong>${escapeHtml(r.number)}</strong> <span class="tag">${escapeHtml(costKindLabel[r.kind]||r.kind||'-')}</span><small>${escapeHtml(r.title||'')}</small></td>
   <td class="num">${r.value?rupiah(r.value):'—'}</td>
   <td class="num">${r.value?pct(r.earned/r.value*100):'—'}</td>
   <td class="num">${rupiah(r.earned)}</td>
   <td class="num">${rupiah(r.mp_cost)}<small>${hours(r.mp_hours)}${r.mp_unpriced_hours?' · ⚠ '+hours(r.mp_unpriced_hours)+' tanpa rate':''}</small></td>
   <td class="num">${rupiah(r.material_cost)}${r.material_unpriced?'<small>⚠ '+r.material_unpriced+' tanpa harga</small>':''}</td>
   <td class="num"><strong>${rupiah(c)}</strong></td>
   <td class="num">${diffHtml(r.earned,c)}</td>
   <td class="num">${cpiText(r.earned,c)}</td></tr>`}).join('')}
 </tbody></table></div>`;
 $('#costTable').querySelectorAll('[data-cost-wo]').forEach(tr=>{
  const go=()=>openCostWo(tr.dataset.costWo===costOpenWo?'':tr.dataset.costWo);
  tr.onclick=go;tr.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();go()}};
 });
}

async function openCostWo(woId){
 costOpenWo=woId;
 $('#costTable').querySelectorAll('[data-cost-wo]').forEach(tr=>tr.classList.toggle('cost-open',tr.dataset.costWo===woId));
 const box=$('#costDetail');
 if(!woId){box.innerHTML='';return}
 const wo=(costRows||[]).find(r=>r.id===woId);if(!wo)return;
 box.innerHTML='<p class="empty">Memuat detail '+escapeHtml(wo.number)+'...</p>';
 try{
  if(!costDetailCache.has(woId))costDetailCache.set(woId,await costApi('wo_detail',{woId}));
  if(costOpenWo!==woId)return;
  renderCostDetail(box,wo,costDetailCache.get(woId));
  box.scrollIntoView({block:'nearest',behavior:'smooth'});
 }catch(err){box.innerHTML='<p class="empty">Gagal memuat detail: '+escapeHtml(err.message)+'</p>'}
}

function renderCostDetail(box,wo,d){
 const mp=d.manpower||[],mat=d.material||[];
 box.innerHTML=`<section class="db-wo cost-detail"><h3>${escapeHtml(wo.number)} <small>${escapeHtml(wo.title||'')}</small></h3>
  <h4>Kumulatif earned vs biaya</h4><div class="cost-chart"></div>
  <div class="cost-breakdown">
   <div><h4>Manpower per kualifikasi</h4>${mp.length?`<div class="table-wrap"><table><thead><tr><th>Kualifikasi</th><th class="num">Orang</th><th class="num">Jam</th><th class="num">Biaya</th></tr></thead><tbody>
    ${mp.map(m=>`<tr><td>${escapeHtml(m.group)}${num(m.unpricedHours)?' <small>⚠ '+hours(m.unpricedHours)+' tanpa rate</small>':''}</td><td class="num">${num(m.people)}</td><td class="num">${hours(m.hours)}</td><td class="num">${rupiahFull(m.cost)}</td></tr>`).join('')}
   </tbody></table></div>`:'<p class="empty">Belum ada check-in manpower.</p>'}</div>
   <div><h4>Material terpakai</h4>${mat.length?`<div class="table-wrap"><table><thead><tr><th>Item</th><th class="num">Qty</th><th class="num">Harga PO</th><th class="num">Biaya</th></tr></thead><tbody>
    ${mat.map(m=>`<tr><td>${escapeHtml(m.item||'-')}</td><td class="num">${num(m.qty).toLocaleString('id-ID')} ${escapeHtml(m.unit||'')}</td><td class="num">${m.unitPrice==null?'⚠ —':rupiahFull(m.unitPrice)}</td><td class="num">${rupiahFull(m.cost)}</td></tr>`).join('')}
   </tbody></table></div>`:'<p class="empty">Belum ada pemakaian material.</p>'}</div>
  </div></section>`;
 renderCostChart(box.querySelector('.cost-chart'),wo,d.series||[]);
}

// Dua garis kumulatif, satu sumbu Rp: Earned (series-1) vs Biaya = manpower + material (series-2).
function renderCostChart(el,wo,series){
 const pts=series.map(s=>({d:parseDate(s.date),earned:num(s.earned),cost:num(s.manpower)+num(s.material),mp:num(s.manpower),mat:num(s.material)}));
 if(!pts.length){el.innerHTML='<p class="empty">Belum ada progress maupun biaya tercatat.</p>';return}
 let x0=pts[0].d,x1=pts[pts.length-1].d;if(x1<=x0){x0=new Date(+x0-DAY_MS);x1=new Date(+x1+DAY_MS)}
 const top=Math.max(1,...pts.map(p=>Math.max(p.earned,p.cost)))*1.1;
 const W=560,H=240,m={l:64,r:78,t:14,b:26},iw=W-m.l-m.r,ih=H-m.t-m.b;
 const X=d=>m.l+(d-x0)/(x1-x0)*iw,Y=v=>m.t+ih-v/top*ih;
 const line=k=>pts.map((p,i)=>(i?'L':'M')+X(p.d).toFixed(1)+' '+Y(p[k]).toFixed(1)).join(' ');
 const grid=[0,.25,.5,.75,1].map(f=>`<line x1="${m.l}" x2="${W-m.r}" y1="${Y(top*f)}" y2="${Y(top*f)}" class="db-grid"/><text x="${m.l-6}" y="${Y(top*f)+4}" class="db-axis" text-anchor="end">${rupiah(top*f)}</text>`).join('');
 const xTicks=(+x1===+x0?[x0]:[x0,new Date((+x0 + +x1)/2),x1]).map((d,i,a)=>`<text x="${X(d)}" y="${H-6}" class="db-axis" text-anchor="${a.length===1?'middle':['start','middle','end'][i]}">${fmtDate(d)}</text>`).join('');
 const last=pts[pts.length-1];
 // Label ujung garis; kalau dua nilainya mepet, geser biar gak numpuk.
 let yE=Y(last.earned)+4,yC=Y(last.cost)+4;if(Math.abs(yE-yC)<14){if(yE<=yC)yC=yE+14;else yE=yC+14}
 el.innerHTML=`<div class="db-legend"><span><i class="db-key db-key-real"></i>Earned (nilai progress)</span><span><i class="db-key cost-key-cost"></i>Biaya resource</span></div>
  <div class="db-svg-wrap"><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHtml(wo.number)}: earned ${rupiah(last.earned)}, biaya ${rupiah(last.cost)} per ${fmtDate(last.d)}">
   ${grid}${xTicks}
   <path d="${line('cost')}" class="db-line cost-line-cost"/>
   <path d="${line('earned')}" class="db-line db-line-real"/>
   ${pts.map(p=>`<circle cx="${X(p.d)}" cy="${Y(p.cost)}" r="4" class="cost-dot-cost"/><circle cx="${X(p.d)}" cy="${Y(p.earned)}" r="4" class="db-dot"/>`).join('')}
   <text x="${X(last.d)+8}" y="${yE}" class="db-label">${rupiah(last.earned)}</text>
   <text x="${X(last.d)+8}" y="${yC}" class="db-label">${rupiah(last.cost)}</text>
   <line class="db-cross" y1="${m.t}" y2="${m.t+ih}" visibility="hidden"/>
   <rect x="${m.l}" y="${m.t}" width="${iw}" height="${ih}" fill="transparent" class="db-hit"/>
  </svg><div class="db-tip" hidden></div></div>`;
 const svg=el.querySelector('svg'),cross=el.querySelector('.db-cross'),tip=el.querySelector('.db-tip'),hit=svg.querySelector('.db-hit');
 hit.addEventListener('pointermove',ev=>{
  const r=svg.getBoundingClientRect(),sx=(ev.clientX-r.left)/r.width*W,at=+x0+(sx-m.l)/iw*(x1-x0);
  let p=pts[0];for(const q of pts)if(Math.abs(q.d-at)<Math.abs(p.d-at))p=q;
  const x=X(p.d);cross.setAttribute('x1',x);cross.setAttribute('x2',x);cross.setAttribute('visibility','visible');
  tip.hidden=false;tip.replaceChildren();
  const head=document.createElement('strong');head.textContent=p.d.toLocaleDateString('id-ID',{weekday:'short',day:'numeric',month:'short',year:'numeric'});tip.append(head);
  for(const [cls,label,v] of [['db-key db-key-real','Earned',p.earned],['db-key cost-key-cost','Biaya',p.cost],['','· Manpower',p.mp],['','· Material',p.mat]]){
   const row=document.createElement('div');if(cls){const key=document.createElement('i');key.className=cls;row.append(key)}
   row.append(document.createTextNode(label+': '+rupiahFull(v)));tip.append(row);
  }
  const left=x/W*r.width;tip.style.left=Math.min(Math.max(left-80,0),r.width-170)+'px';
 });
 hit.addEventListener('pointerleave',()=>{cross.setAttribute('visibility','hidden');tip.hidden=true});
}

// ---------- Register Alat (Tools / Heavy Equipment dari PO SMMS) ----------
// RENTAL: rate/jam = harga PO / pembagi (jam per satuan sewa). ASET: rate/jam = harga PO / (bulan penyusutan x 200 jam).
let equipRows=null;
const ASSET_HOURS_PER_MONTH=200;
function costShowView(view){
 $('#costMain').hidden=view!=='main';$('#costEquip').hidden=view!=='equip';
 $('#costViewMain').classList.toggle('active',view==='main');$('#costViewEquip').classList.toggle('active',view==='equip');
 if(view==='equip'&&!equipRows)loadEquip();
}
$('#costViewMain').onclick=()=>costShowView('main');
$('#costViewEquip').onclick=()=>costShowView('equip');
async function loadEquip(){
 $('#equipTable').innerHTML='<p class="empty">Memuat...</p>';
 try{equipRows=await costApi('equipment_list');renderEquip()}
 catch(err){$('#equipTable').innerHTML='<p class="empty">Gagal memuat: '+escapeHtml(err.message)+'</p>'}
}
$('#equipRefresh').onclick=busy($('#equipRefresh'),loadEquip);
$('#equipSearch').oninput=()=>renderEquip();
$('#equipFilter').onchange=()=>renderEquip();
function equipRate(price,own,div){
 price=Number(price);div=Number(div);
 if(!own||!(div>0)||!Number.isFinite(price))return null;
 return price/(own==='ASSET'?div*ASSET_HOURS_PER_MONTH:div);
}
const divisorHint=(own,unit)=>own==='ASSET'?'bulan penyusutan':own==='RENTAL'?'jam per '+(unit||'satuan'):'';
function renderEquip(){
 if(!equipRows)return;
 const q=$('#equipSearch').value.trim().toLowerCase(),f=$('#equipFilter').value;
 const rows=equipRows.filter(r=>(!f||(f==='UNSET'?!r.confirmed:r.ownership===f))&&(!q||[r.description,r.po_number,r.item_group].join(' ').toLowerCase().includes(q)));
 const unconfirmed=equipRows.filter(r=>!r.confirmed).length,noDiv=equipRows.filter(r=>!r.divisor).length;
 if(!equipRows.length){$('#equipTable').innerHTML='<p class="empty">Belum ada PO SMMS grup Tools / Heavy Equipment.</p>';return}
 const notes=[unconfirmed?`${unconfirmed} item masih <b>saran otomatis</b> -- cek lalu klik Konfirmasi.`:'',noDiv?`${noDiv} item pembaginya masih kosong (Aset: isi durasi penyusutan) -- rate per jamnya belum bisa dihitung.`:''].filter(Boolean);
 $('#equipTable').innerHTML=(notes.length?`<p class="banner">${notes.join('<br>')}</p>`:'')+`<div class="table-wrap"><table class="equip-table"><thead><tr>
  <th>Alat</th><th>PO</th><th class="num">Qty PO / diterima</th><th class="num">Harga satuan PO</th><th>Status</th><th>Pembagi</th><th class="num">Rate / jam</th><th></th></tr></thead><tbody>
  ${rows.map(r=>{const id=escapeHtml(String(r.po_detail_id)),own=r.ownership||'';return `<tr data-equip="${id}">
   <td><strong>${escapeHtml(r.description||'-')}</strong><small>${escapeHtml(r.item_group||'')}</small></td>
   <td>${escapeHtml(r.po_number||'-')}<small>${escapeHtml(r.po_status||'')}</small></td>
   <td class="num">${num(r.qty).toLocaleString('id-ID')} / ${num(r.qty_received).toLocaleString('id-ID')} ${escapeHtml(r.unit||'')}</td>
   <td class="num">${r.unit_price==null?'⚠ —':rupiahFull(r.unit_price)}<small>per ${escapeHtml(r.unit||'satuan')}</small></td>
   <td><select data-equip-own aria-label="Status ${escapeHtml(r.description||'')}"><option value="RENTAL" ${own==='RENTAL'?'selected':''}>Rental</option><option value="ASSET" ${own==='ASSET'?'selected':''}>Aset</option></select>
    <small>${r.confirmed?'✓ Dikonfirmasi':'<span class="equip-auto">Saran otomatis</span>'}${r.req_duration?' · request '+num(r.req_duration).toLocaleString('id-ID')+' '+escapeHtml(r.req_dur_unit||''):''}</small></td>
   <td><input data-equip-div type="number" min="0.01" step="any" value="${r.divisor??''}" placeholder="${own==='RENTAL'&&r.default_divisor?r.default_divisor:''}" ${own?'':'disabled'} aria-label="Pembagi"><small data-equip-hint>${escapeHtml(divisorHint(own,r.unit))}</small></td>
   <td class="num" data-equip-rate>${r.rate_per_hour==null?'<span class="cost-muted">—</span>':rupiahFull(r.rate_per_hour)}</td>
   <td><button type="button" data-equip-save ${r.confirmed?'disabled':''}>${r.confirmed?'Simpan':'Konfirmasi'}</button></td></tr>`}).join('')||'<tr><td colspan="8" class="empty">Gak ada alat yang cocok.</td></tr>'}
 </tbody></table></div>`;
 $('#equipTable').querySelectorAll('tr[data-equip]').forEach(tr=>{
  const r=equipRows.find(x=>String(x.po_detail_id)===tr.dataset.equip),own=tr.querySelector('[data-equip-own]'),div=tr.querySelector('[data-equip-div]'),save=tr.querySelector('[data-equip-save]');
  const refresh=()=>{
   const o=own.value;div.disabled=!o;
   div.placeholder=o==='RENTAL'&&r.default_divisor?String(r.default_divisor):'';
   tr.querySelector('[data-equip-hint]').textContent=divisorHint(o,r.unit);
   const rate=equipRate(r.unit_price,o,div.value);
   tr.querySelector('[data-equip-rate]').innerHTML=rate==null?'<span class="cost-muted">—</span>':rupiahFull(rate);
   save.disabled=r.confirmed&&(o||'')===(r.ownership||'')&&String(div.value)===String(r.divisor??'');
   save.textContent=r.confirmed?'Simpan':'Konfirmasi';
  };
  own.onchange=()=>{
   if(own.value==='RENTAL'){div.value=r.suggested_divisor??r.default_divisor??''}
   else div.value='';
   refresh();
  };
  div.oninput=refresh;
  save.onclick=busy(save,async()=>{
   if(own.value&&!(Number(div.value)>0)){status('Isi pembagi dulu (lebih dari 0).');div.focus();return}
   const saved=await costApi('equipment_save',{poDetailId:r.po_detail_id,ownership:own.value,divisor:own.value?div.value:''});
   Object.assign(r,saved);status('Tersimpan: '+(r.description||'alat')+'.');renderEquip();
  });
 });
}

function resetCost(){equipRows=null;costShowView('main');costProjectsLoaded=false;costRows=null;costOpenWo='';costDetailCache.clear();costLoadVersion++;$('#costProject').innerHTML='<option value="">Pilih project</option>';$('#costSummary').innerHTML='';$('#costDetail').innerHTML='';$('#costTable').innerHTML='<p class="empty">Pilih project buat lihat biaya vs progress per WO.</p>'}
$('#logout').addEventListener('click',resetCost);
