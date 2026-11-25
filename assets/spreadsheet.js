const encoder = new TextEncoder();
const spreadsheetType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

const xml = value => String(value ?? '')
  .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, '')
  .replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;'
  })[char]);

function columnName(index) {
  let name = '';
  while (index >= 0) {
    name = String.fromCharCode(65 + index % 26) + name;
    index = Math.floor(index / 26) - 1;
  }
  return name;
}

const crcTable = Array.from({length: 256}, (_, value) => {
  for (let bit = 0; bit < 8; bit++) {
    value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  }
  return value >>> 0;
});

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = (value >>> 8) ^ crcTable[(value ^ byte) & 255];
  return (value ^ 0xffffffff) >>> 0;
}

function zipHeader(size, values) {
  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  for (const [offset, width, value] of values) {
    if (width === 4) view.setUint32(offset, value, true);
    else view.setUint16(offset, value, true);
  }
  return new Uint8Array(buffer);
}

function zipStored(files) {
  const localRecords = [];
  const centralDirectory = [];
  let offset = 0;
  let directorySize = 0;
  for (const [path, content] of files) {
    const name = encoder.encode(path);
    const data = encoder.encode(content);
    const crc = crc32(data);
    const local = zipHeader(30, [
      [0, 4, 0x04034b50], [4, 2, 20], [12, 2, 33], [14, 4, crc],
      [18, 4, data.length], [22, 4, data.length], [26, 2, name.length]
    ]);
    const central = zipHeader(46, [
      [0, 4, 0x02014b50], [4, 2, 20], [6, 2, 20], [14, 2, 33],
      [16, 4, crc], [20, 4, data.length], [24, 4, data.length],
      [28, 2, name.length], [42, 4, offset]
    ]);
    localRecords.push(local, name, data);
    centralDirectory.push(central, name);
    offset += local.length + name.length + data.length;
    directorySize += central.length + name.length;
  }
  return [...localRecords, ...centralDirectory, zipHeader(22, [
    [0, 4, 0x06054b50], [8, 2, files.length], [10, 2, files.length],
    [12, 4, directorySize], [16, 4, offset]
  ])];
}

export function buildWorkbook(title, rows) {
  const heading = String(title).replace(/[\\/?:*\[\]]/g, ' ').trim().slice(0, 31) || 'البيانات';
  const sheetRows = rows.map((row, rowIndex) => {
    const r = rowIndex + 1;
    const cells = row.map((value, colIndex) => {
      const id = columnName(colIndex) + r;
      if (typeof value === 'number' && Number.isFinite(value)) return `<c r="${id}"><v>${value}</v></c>`;
      return `<c r="${id}" t="inlineStr"><is><t xml:space="preserve">${xml(value)}</t></is></c>`;
    }).join('');
    return `<row r="${r}">${cells}</row>`;
  }).join('');
  return new Blob(zipStored([
    ['[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'],
    ['_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'],
    ['xl/workbook.xml', `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="${xml(heading)}" sheetId="1" r:id="rId1"/></sheets></workbook>`],
    ['xl/_rels/workbook.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'],
    ['xl/worksheets/sheet1.xml', `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0" rightToLeft="1"/></sheetViews><sheetData>${sheetRows}</sheetData></worksheet>`]
  ]), {type: spreadsheetType});
}

export function downloadWorkbook(filename, title, rows) {
  const url = URL.createObjectURL(buildWorkbook(title, rows));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename.endsWith('.xlsx') ? filename : filename + '.xlsx';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function printPrivateTable(title, rows) {
  const frame = document.createElement('iframe');
  frame.title = 'معاينة الطباعة';
  frame.style.cssText = 'position:fixed;width:1px;height:1px;bottom:0;right:0;border:0';
  frame.setAttribute('sandbox', 'allow-same-origin allow-modals');
  frame.onload = () => {
    const page = frame.contentWindow;
    page.addEventListener('afterprint', () => frame.remove(), {once: true});
    page.focus();
    page.print();
  };
  frame.srcdoc = `<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
    <title>${xml(title)}</title><style>
    body{font:13px system-ui;margin:18px;color:#14251f}
    table{border-collapse:collapse;width:100%;table-layout:auto}
    th,td{border:1px solid #bbc9c2;padding:7px;text-align:start;overflow-wrap:anywhere}
    thead{display:table-header-group} tr{break-inside:avoid}
    </style><h1>${xml(title)}</h1><table><thead><tr>
    ${rows[0].map(cell => `<th scope="col">${xml(cell)}</th>`).join('')}
    </tr></thead><tbody>
    ${rows.slice(1).map(row => '<tr>' + row.map(cell => `<td>${xml(cell)}</td>`).join('') + '</tr>').join('')}
    </tbody></table></html>`;
  document.body.append(frame);
}
