const assert=require('node:assert/strict');
const C=require('../commercial.js');
const XLSX=require('../vendor/xlsx.full.min.js');
const fs=require('node:fs');
const file=process.argv[2];
if(file){const w=XLSX.read(fs.readFileSync(file),{type:'buffer'});const rows=XLSX.utils.sheet_to_json(w.Sheets[w.SheetNames[0]],{header:1,raw:true,defval:null,blankrows:true});const p=C.parse(rows,{code:0,description:1,unit:3,qty:4,price:5,amount:6},{start:4});assert.equal(p.items.filter(i=>i.rowKind==='ITEM').length,262);assert.equal(p.issues.filter(i=>i.severity==='error').length,0);assert.equal(p.items.find(i=>i.code==='2.3.2').price,2497741.0541747184);assert.equal(p.items.find(i=>i.code==='3.2.1.36').rate,'STANDBY');assert.equal(p.items.find(i=>i.code==='3.2.1.1').rate,'WORKING');assert(C.ancestors(p.items.find(i=>i.code==='3.2.1.1'),p.items).includes('Tarif Kerja Peralatan'));console.log('SmallPipeline: 262 items, preserved precision, hierarchy and working/standby OK');}
assert.equal(C.number('1.234,56','id'),1234.56);assert.equal(C.number('1,234.56','en'),1234.56);assert(Number.isNaN(C.number('bad')));
const p=C.parse([['1','A','m',1,2],['1','B','m',1,3]],{code:0,description:1,unit:2,qty:3,price:4},{start:0});assert(p.issues.some(i=>i.message.includes('duplikat')));console.log('Validation and locale tests OK');
