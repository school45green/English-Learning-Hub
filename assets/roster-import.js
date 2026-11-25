const pdfLibrary = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@5.6.205';
const maxFileBytes = 8 * 1024 * 1024;
const maxXmlBytes = 4 * 1024 * 1024;
const maxNames = 500;
const utf8 = new TextDecoder('utf-8', { fatal: true });

// This Arial PDF template uses CID numbers in place of Unicode. The table
// maps glyphs to Arabic letters without retaining any document content.
const arialLetters = 'أؤ·····ئ·ااب·ب·ةةت·ت·ث·ث·ججج·ححح·خخخ·د·ذ·ر·ز·س·س·ش·ش·ص·ص·ض·ض·ط···ظ····ععع··غغف·ففققققك·ك·ل·للم·م·ن·ن·ههههو·ىىييي·············';
const arialSpecial = new Map([
  [751,'ء'], [752,'ـ'], [776,'ە'], [815,'ك'], [821,'ي'], [822,'ي'],
  [896,'ء'], [897,'آ'], [898,'آ'], [899,'أ'], [1013,'لآ'], [1014,'لآ'],
  [1015,'لأ'], [1016,'لأ'], [1017,'لإ'], [1019,'لا'], [1020,'لا'],
  [1320,'ٮ'], [1321,'ى'], [1324,'ٯ'], [1336,'ٓ'], [1337,'ٔ'], [1338,'ٕ'],
  [1466,'ڡ'], [1551,'ں'], [1567,'ہ'], [1643,'ہ'], [1644,'ہ'],
  [3020,'الله'], [3021,'ريال'], [3415,' ّٰ'], [3869,'محمد'],
  [3870,'صلى الله عليه وسلم'], [3872,'جل جلاله'],
]);

const arabicName = /^[\p{Script=Arabic}\p{M} ]+$/u;
const spaces = value => value.normalize('NFC').trim().replace(/\s+/gu, ' ');
const arabicDigits = value => value.replace(/[٠-٩۰-۹]/gu, digit => String(digit.codePointAt(0) % 16));
const arabicLetters = value => value.replace(/[یکھ]/gu, letter => ({'ی':'ي','ک':'ك','ھ':'ه'})[letter]);

function readArial(value) {
  if (/^[\p{Script=Arabic}\p{M}\s]+$/u.test(value)) return spaces(value);
  let text = '';
  for (const symbol of Array.from(value).reverse()) {
    if (symbol === '\x03' || /\s/u.test(symbol)) {
      text += ' ';
      continue;
    }
    const id = symbol.codePointAt(0);
    const letter = arialSpecial.get(id) ?? arialLetters[id - 900];
    if (!letter || letter === '·') return '';
    text += letter;
  }
  return spaces(arabicLetters(text));
}

function recordName(result, rawName, label) {
  const name = spaces(rawName);
  if (!arabicName.test(name) || name.split(' ').length < 2 || name.length > 200 || /\p{N}/u.test(name)) {
    result.issues.push(`${label} يحتاج مراجعة الاسم في الملف.`);
    return;
  }
  result.names.push(name);
}

function grouping(items) {
  const lines = new Map();
  for (const item of items) {
    if (!item.str?.trim()) continue;
    const key = Math.round(item.transform[5] * 2);
    if (!lines.has(key)) lines.set(key, []);
    lines.get(key).push(item);
  }
  return Array.from(lines).sort(([a], [b]) => b-a).map(([, line]) =>
    line.sort((a,b) => a.transform[4]-b.transform[4]));
}

async function readPdf(bytes) {
  const pdfjs = await import(`${pdfLibrary}/legacy/build/pdf.mjs`);
  pdfjs.GlobalWorkerOptions.workerSrc = `${pdfLibrary}/legacy/build/pdf.worker.mjs`;
  const loading = pdfjs.getDocument({
    data: bytes, disableFontFace: true, useSystemFonts: false,
    isEvalSupported: false, enableXfa: false,
    stopAtErrors: true,
    standardFontDataUrl: `${pdfLibrary}/standard_fonts/`,
  });
  const result = { names: [], issues: [], classHint: null };
  try {
    const document = await loading.promise;
    if (document.numPages > 20) throw new Error('الملف يتجاوز 20 صفحة.');
    let expected = 1;
    for (let number=1; number<=document.numPages; number++) {
      const page = await document.getPage(number);
      const { items } = await page.getTextContent({ disableNormalization: true });
      const lines = grouping(items);
      let gradeLevel, section;
      let foundRows = 0;
      for (const line of lines) {
        const texts = line.map(item => item.str.trim());
        const decoded = texts.map(readArial);
        if (decoded.includes('الصف')) {
          if (decoded.includes('الأول الثانوي')) gradeLevel = 'أول ثانوي';
          if (decoded.includes('الثالث الثانوي')) gradeLevel = 'ثالث ثانوي';
        }
        if (decoded.includes('الفصل')) {
          const number = texts.map(arabicDigits).find(text => /^[0-9]{1,2}$/.test(text));
          if (number) section = Number(number);
        }
        const serial = arabicDigits(texts.at(-1));
        const position = texts.findIndex(text => /^[0-9]{10}$/.test(arabicDigits(text)));
        if (position < 1 || !/^[0-9]{1,3}$/.test(serial)) continue;
        const index = Number(serial);
        if (position !== texts.length - 2 || index !== expected) {
          result.issues.push(`الصفحة ${number} – راجعي تسلسل الصفوف قرب الرقم ${expected}.`);
        }
        expected = index + 1;
        foundRows++;
        const beforeId = decoded.slice(0,position);
        const name = beforeId.every(Boolean) ? beforeId.reverse().join(' ') : '';
        recordName(result, name, `الصفحة ${number} – الصف ${index}`);
      }
      if (!foundRows) result.issues.push(`الصفحة ${number} – لم يمكن قراءة صفوف الكشف.`);
      if (!gradeLevel || !section) {
        result.issues.push(`الصفحة ${number} – راجعي اسم الصف ورقم الفصل في الكشف.`);
      } else if (result.classHint &&
        (result.classHint.gradeLevel !== gradeLevel || result.classHint.section !== section)) {
        result.issues.push(`الصفحة ${number} – الصف أو الفصل يختلف عن الصفحة السابقة.`);
      } else {
        result.classHint = { gradeLevel, section };
      }
      page.cleanup();
    }
    return result;
  } finally {
    await loading.destroy();
  }
}

// Reads only the XML members needed for a workbook. ZIP64, encrypted files,
// external relationships and workbook macros are outside the supported format.
function openZip(bytes) {
  const view = new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const u16 = offset => view.getUint16(offset,true);
  const u32 = offset => view.getUint32(offset,true);
  const fail = () => { throw new Error('تعذّر قراءة بنية ملف Excel.'); };
  let end = -1;
  for (let cursor=bytes.length-22; cursor>=Math.max(0,bytes.length-65557); cursor--) {
    if (u32(cursor)===0x06054b50 && cursor+22+u16(cursor+20)===bytes.length) {
      end=cursor;
      break;
    }
  }
  if (end<0 || u16(end+4)!==0 || u16(end+6)!==0 || u16(end+8)!==u16(end+10)) fail();
  const count=u16(end+10);
  let offset=u32(end+16);
  const directoryEnd=offset+u32(end+12);
  const members=new Map();
  if (count>500 || directoryEnd>end) fail();
  for (let index=0; index<count; index++) {
    if (offset+46>directoryEnd || u32(offset)!==0x02014b50) fail();
    const nameLength=u16(offset+28);
    const next=offset+46+nameLength+u16(offset+30)+u16(offset+32);
    if (next>directoryEnd || (u16(offset+8)&1)!==0 || u16(offset+34)!==0) fail();
    const name=utf8.decode(bytes.subarray(offset+46,offset+46+nameLength));
    if (members.has(name)) fail();
    members.set(name,{ method:u16(offset+10), length:u32(offset+24),
      compressed:u32(offset+20), local:u32(offset+42) });
    offset=next;
  }
  return {
    has: name => members.has(name),
    async read(name) {
      const entry=members.get(name);
      if (!entry || entry.local+30>directoryEnd || u32(entry.local)!==0x04034b50 ||
        entry.length>maxXmlBytes) fail();
      const start=entry.local+30+u16(entry.local+26)+u16(entry.local+28);
      if (start+entry.compressed>directoryEnd) fail();
      const data=bytes.subarray(start,start+entry.compressed);
      if (entry.method===0 && entry.length===data.length) return utf8.decode(data);
      if (entry.method!==8 || !globalThis.DecompressionStream) fail();
      const stream=new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
      const reader=stream.getReader();
      const pieces=[];
      let total=0;
      try {
        for (;;) {
          const { value, done }=await reader.read();
          if (done) break;
          total+=value.length;
          if (total>entry.length || total>maxXmlBytes) fail();
          pieces.push(value);
        }
      } finally {
        await reader.cancel();
      }
      if (total!==entry.length) fail();
      const inflated=new Uint8Array(total);
      let position=0;
      for (const piece of pieces) {
        inflated.set(piece,position);
        position+=piece.length;
      }
      return utf8.decode(inflated);
    },
  };
}

const descendants = (element, tag) => Array.from(element.getElementsByTagNameNS('*',tag));
const stringValue = element => descendants(element,'t')
  .filter(text => text.parentElement.localName!=='rPh')
  .map(text => text.textContent).join('');

async function readXml(zip, name) {
  const raw=await zip.read(name);
  if (/<!DOCTYPE|<!ENTITY/i.test(raw)) throw new Error('بنية ملف Excel غير مدعومة.');
  const doc=new DOMParser().parseFromString(raw,'application/xml');
  if (descendants(doc,'parsererror').length) throw new Error('تعذّر قراءة ورقة Excel.');
  return doc;
}

async function readExcel(bytes) {
  const zip=openZip(bytes);
  const workbook=await readXml(zip,'xl/workbook.xml');
  const first=descendants(workbook,'sheet')[0];
  if (!first) throw new Error('لا توجد ورقة عمل في الملف.');
  const relationId=Array.from(first.attributes).find(attribute => attribute.localName==='id')?.value;
  const relations=await readXml(zip,'xl/_rels/workbook.xml.rels');
  const relation=descendants(relations,'Relationship').find(item => item.getAttribute('Id')===relationId);
  const target=relation?.getAttribute('Target')??'';
  const path=target.startsWith('/')?target.slice(1):`xl/${target}`;
  if (relation?.getAttribute('TargetMode')==='External' || !/^xl\/worksheets\/[A-Za-z0-9_.-]+\.xml$/.test(path)) {
    throw new Error('تعذّر العثور على ورقة العمل الأولى في Excel.');
  }
  const sheet=await readXml(zip,path);
  const shared=zip.has('xl/sharedStrings.xml')
    ? descendants(await readXml(zip,'xl/sharedStrings.xml'),'si').map(stringValue) : [];
  const cellText = cell => {
    if (descendants(cell,'f').length) return '';
    const type=cell.getAttribute('t');
    if (type==='inlineStr') return stringValue(cell);
    const value=descendants(cell,'v')[0]?.textContent??'';
    if (type==='s') return /^[0-9]+$/.test(value)?shared[Number(value)]??'':'';
    return type==='str'?value:'';
  };
  const rows=descendants(sheet,'row');
  const headings=new Set(['الاسم','اسم الطالبة','اسم الطالبه','الاسم الكامل','الاسم الثلاثي','الاسم الرباعي','اسم الطالبة الكامل']);
  let header=-1, column='';
  for (let index=0; index<Math.min(rows.length,15); index++) {
    const candidates=descendants(rows[index],'c').filter(cell => headings.has(spaces(cellText(cell))));
    if (!candidates.length) continue;
    if (candidates.length!==1) throw new Error('توجد عدة أعمدة بأسماء متطابقة في رأس القائمة.');
    column=candidates[0].getAttribute('r')?.match(/^[A-Z]+/)?.[0];
    header=index;
    break;
  }
  if (!column || header<0) throw new Error('أضيفي عنوان «اسم الطالبة» إلى عمود الأسماء في ورقة Excel الأولى.');
  const result={ names:[],issues:[],classHint:null };
  for (const row of rows.slice(header+1)) {
    const cells=descendants(row,'c');
    const cell=cells.find(item => item.getAttribute('r')?.match(/^[A-Z]+/)?.[0]===column);
    const value=cell?cellText(cell):'';
    if (!value && !cells.some(item => item.textContent.trim())) continue;
    recordName(result,value,`صف Excel رقم ${row.getAttribute('r')??'؟'}`);
  }
  return result;
}

/** Parse a locally selected file without uploading it or retaining identifiers. */
export async function parseRosterFile(file) {
  if (!file || file.size===0 || file.size>maxFileBytes) {
    throw new Error('اختاري ملف كشف حجمه 8 ميغابايت أو أقل.');
  }
  const bytes=new Uint8Array(await file.arrayBuffer());
  const ext=file.name.split('.').pop().toLowerCase();
  const result=ext==='pdf'?await readPdf(bytes)
    : ext==='xlsx'?await readExcel(bytes):null;
  if (!result) throw new Error('الملفات المدعومة هي PDF وExcel بصيغة XLSX.');
  if (!result.names.length && !result.issues.length) {
    throw new Error('لم يُعثر على أسماء في الملف.');
  }
  if (result.names.length>maxNames) throw new Error('الحد الأقصى 500 اسم لكل ملف.');
  if (new Set(result.names).size!==result.names.length) {
    result.issues.push('توجد أسماء متطابقة داخل الملف. راجعي الصفوف قبل الاستيراد.');
  }
  return result;
}
