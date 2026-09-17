(function(root){
'use strict';
const text=v=>v==null?'':String(v).trim();
function number(v,locale='en'){if(v==null||v==='')return null;if(typeof v==='number')return Number.isFinite(v)?v:NaN;let s=text(v).replace(/\s/g,'');s=locale==='id'?s.replace(/\./g,'').replace(',','.'):s.replace(/,/g,'');return /^[-+]?\d+(\.\d+)?$/.test(s)?Number(s):NaN;}
function parse(rows,map,options={}){
 const result=[],issues=[],skipped=[],seen=new Set();let stack=[],rate='STANDARD',seq=0;
 const start=options.start??4;
 for(let ri=start;ri<rows.length;ri++){
  const r=rows[ri]||[],get=k=>map[k]>=0?r[map[k]]:undefined;
  let code=text(get('code')),description=text(get('description'));const unit=text(get('unit')),price=number(get('price'),options.locale),qty=number(get('qty'),options.locale),amount=number(get('amount'),options.locale);
  if(!code&&!description&&!unit&&price===null)continue;
  const label=description||code;
  if(/^(SUB\s*TOTAL|GRAND\s*TOTAL|PROVISION\s*SUM)/i.test(label)||/^(SUB\s*TOTAL|GRAND\s*TOTAL|PROVISION\s*SUM)/i.test(code)){skipped.push({row:ri+1,label});continue;}
  const isGroup=price===null&&!unit&&qty===null;
  if(isGroup){
   let level;
   if(/^PAKET\s+PEKERJAAN/i.test(label)){level=0;rate='STANDARD';}
   else{const m=label.match(/P-[IVX]+\.?\s*Unit\s+(\d+(?:\.\d+)*)/i);if(m){level=m[1].split('.').length;rate='STANDARD';}else{level=Math.max(1,...stack.filter(x=>x.explicit).map(x=>x.level+1));}}
   const explicit=/^PAKET\s+PEKERJAAN|P-[IVX]+\.?\s*Unit/i.test(label);
   if(/standby/i.test(label))rate='STANDBY';else if(/tarif kerja/i.test(label))rate='WORKING';else if(!explicit)rate='STANDARD';
   while(stack.length&&stack.at(-1).level>=level)stack.pop();
   const item={id:'row-'+(ri+1),code:'GROUP-'+(++seq),description:label,rowKind:'GROUP',parentId:stack.at(-1)?.id||null,level,sourceRow:ri+1,explicit,unit:null,price:null,qty:null,rate};
   result.push(item);stack.push(item);continue;
  }
  if(!code){code='ITEM-'+(ri+1);issues.push({row:ri+1,severity:'warning',message:'Kode dibuat otomatis: '+code});}
  if(seen.has(code))issues.push({row:ri+1,severity:'error',message:'Kode item duplikat: '+code});seen.add(code);
  if(!description)issues.push({row:ri+1,severity:'error',message:'Uraian item kosong'});
  if(!unit)issues.push({row:ri+1,severity:'error',message:'Satuan kosong'});
  if(price===null||!Number.isFinite(price)||price<0)issues.push({row:ri+1,severity:'error',message:'Harga tidak valid'});
  if(qty!==null&&(!Number.isFinite(qty)||qty<0))issues.push({row:ri+1,severity:'error',message:'Qty tidak valid'});
  if(Number.isFinite(amount)&&Number.isFinite(qty)&&Number.isFinite(price)&&Math.abs(amount-qty*price)>.011)issues.push({row:ri+1,severity:'warning',message:'Nilai sumber berbeda dengan qty × harga'});
  result.push({id:'row-'+(ri+1),code,description,rowKind:'ITEM',parentId:stack.at(-1)?.id||null,level:stack.length?stack.at(-1).level+1:0,unit,price,qty,amount,rate,sourceRow:ri+1});
 }
 return {items:result,issues,skipped};
}
function ancestors(item,items){let current=item;const names=[],seen=new Set();while(current?.parentId){if(seen.has(current.parentId))throw Error('Hierarki berulang');seen.add(current.parentId);current=items.find(i=>i.id===current.parentId);if(current)names.unshift(current.description);}return names;}
const api={parse,number,ancestors};if(typeof module!=='undefined')module.exports=api;else root.Commercial=api;
})(globalThis);

