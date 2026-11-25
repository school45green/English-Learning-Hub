import {readPdfLines} from './roster-import.js';

export async function readWorksheet(file) {
  if (!file?.size || file.size > 8 * 1024 * 1024) throw new Error('اختاري ملف PDF أو TXT لا يتجاوز 8 ميغابايت.');
  const ext = file.name.split('.').pop().toLowerCase();
  const lines = ext === 'pdf' ? await readPdfLines(file) : ext === 'txt' ? (await file.text()).split(/\r?\n/) : [];
  const questions = [];
  let current;
  for (const line of lines.map(line => line.trim()).filter(Boolean)) {
    const prompt = line.match(/^\d{1,3}[.)-]\s*(.+)$/);
    const option = line.match(/^([A-D])[.)-]\s*(.+)$/i);
    const answer = line.match(/^(?:answer|key)\s*:\s*([A-D]|true|false)\s*$/i);
    if (prompt) {
      current = {prompt: prompt[1].slice(0, 500), choices: []};
      questions.push(current);
    } else if (current && option) {
      current.choices[option[1].toUpperCase().charCodeAt(0) - 65] = option[2].slice(0, 300);
    } else if (current && answer) {
      const key = answer[1].toLowerCase();
      current.boolean = key === 'true' || key === 'false';
      current.correct = current.boolean ? Number(key === 'false') : key.charCodeAt(0) - 97;
    }
  }
  if (!questions.length || questions.length > 100) throw new Error('يلزم من 1 إلى 100 سؤال مرقّم في ملف نصي أو PDF قابل لتحديد النص.');
  return questions;
}
