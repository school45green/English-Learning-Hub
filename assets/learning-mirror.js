import {printPrivateTable} from './spreadsheet.js';

const moods=[['😍','فهمت الدرس واستمتعت.'],['😊','فهمت الدرس جيدًا.'],['😕','أحتاج إلى مزيد من التدريب.'],['😔','أحتاج إلى إعادة الشرح.']];
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(label,key)=>`<button type="button" class="action secondary" data-mirror="${key}">${label}</button>`;
const title=l=>`${l.title} · ${l.course} · الوحدة ${l.unit} · الأسبوع ${l.week}`;
const counts=l=>l.counts||[0,0,0,0];
const percentages=l=>{
  const n=counts(l).reduce((a,b)=>a+b,0);
  return counts(l).map(c=>n?Math.round(c*1000/n)/10:0);
};

function mountMirror(root,{rpc,teacher=false,report=null}){
  const admin=report!==null;
  const reads=teacher||admin;
  root.innerHTML=`<p lang="en" dir="ltr">Self-Reflection – Learning Mirror</p>
    <div class="flex" data-filters></div><div class="nav" data-lessons></div>
    <p role="status" aria-live="polite" data-status></p>
    <div data-current></div>`;
  const filters=root.querySelector('[data-filters]');
  const grid=root.querySelector('[data-lessons]');
  const current=root.querySelector('[data-current]');
  const status=root.querySelector('[data-status]');
  let lessons=[],loaded=false;
  const visible=()=>lessons.filter(l=>[...filters.querySelectorAll('select')].every(s=>!s.value||String(l[s.name])===s.value));
  const row=l=>[l.course,`${l.unit} · ${l.unit_title}`,l.week,l.title,counts(l).reduce((a,b)=>a+b,0),...percentages(l).map(v=>v+'٪'),l.reflection,l.action];
  const headers=['المقرر','الوحدة','الأسبوع','الدرس','المشاركات',...moods.map(m=>m.join(' ')),'تأمل المعلمة','إجراء التحسين'];
  const print=(rows)=>printPrivateTable('الثانوية الخامسة والأربعون — التأمل الذاتي في دروس اللغة الإنجليزية',[headers,...rows.map(row)]);
  function draw(){
    current.replaceChildren();
    const list=visible();
    grid.innerHTML=list.map(l=>`<button type="button" class="tile" data-mirror="${esc(l.id)}"><span aria-hidden="true">${l.voted?'✅':'🪞'}</span> <b lang="en" dir="ltr">${esc(l.title)}</b><small style="display:block">${esc(l.course)} · الوحدة ${l.unit} · الأسبوع ${l.week}</small></button>`).join('');
    status.textContent=list.length?'':'لا توجد دروس مطابقة.';
  }
  function lessonView(l){
    grid.hidden=true;
    filters.hidden=true;
    current.innerHTML=button('العودة إلى الدروس','back')+`<div class="secure-card"><h3 tabindex="-1">${esc(title(l))}</h3><p lang="en" dir="ltr">${esc(l.unit_title)}</p>`+
      (reads?`<h4>نتائج لوحة المشاعر</h4><p>المشاركات ${counts(l).reduce((a,b)=>a+b,0)}</p><div>${percentages(l).map((v,i)=>`<p><label>${moods[i].join(' ')} · ${v}٪ <meter min="0" max="100" value="${v}">${v}٪</meter></label></p>`).join('')}</div>`+
        (teacher&&l.suggestions?.length?`<details><summary>اقتراحات الطالبات</summary><ul>${l.suggestions.map(s=>`<li>${esc(s)}</li>`).join('')}</ul></details>`:'')+
        (teacher?`<form><label>تأملي الذاتي في ضوء آراء الطالبات <textarea name="reflection" rows="2" maxlength="1000">${esc(l.reflection)}</textarea></label><label>الإجراء الذي سأتخذه لتحسين الدرس القادم <textarea name="action" rows="2" maxlength="1000">${esc(l.action)}</textarea></label><button class="action">حفظ التأمل والإجراء</button></form>`:
        `<h4>تأمل المعلمة</h4><p>${esc(l.reflection||'—')}</p><h4>إجراء التحسين</h4><p>${esc(l.action||'—')}</p>`)+button('طباعة هذا الدرس / حفظ PDF','lesson-print')
        :`<h4 lang="en" dir="ltr">How was your learning experience today?</h4>`+
        (l.voted?'<p>تم حفظ رأيك لهذا الدرس. 🌟</p>':`<div class="nav">${moods.map(([emoji,label],i)=>`<button type="button" class="tile" data-feeling="${i+1}" style="border-inline-start:4px solid ${['#dcaa38','#6ab194','#ca924c','#9982b6'][i]}"><span aria-hidden="true">${emoji}</span> ${label}</button>`).join('')}</div>`)+
        (l.voted?`<form><label>ما الذي تتمنين تحسينه في الدرس القادم؟ <span>اختياري · دون كتابة اسمكِ</span><textarea name="suggestion" maxlength="240" rows="2"></textarea></label><button class="action">حفظ الاقتراح</button></form>`:''))+'</div>';
    current.querySelector('h3').focus();
    current.querySelector('[data-mirror=back]').onclick=()=>{grid.hidden=false;filters.hidden=false;draw();grid.querySelector('button')?.focus()};
    const printButton=current.querySelector('[data-mirror=lesson-print]');
    if(printButton)printButton.onclick=()=>print([l]);
    for(const b of current.querySelectorAll('[data-feeling]')){
      b.onclick=async()=>{
        const group=[...current.querySelectorAll('[data-feeling]')];
        group.forEach(x=>x.disabled=true);status.textContent='جارٍ الحفظ…';
        try{
          await rpc('vote',{id:l.id,feeling:+b.dataset.feeling});l.voted=true;
          if(b.isConnected){lessonView(l);status.textContent='حُفظ رأيكِ.'}
        }catch(error){if(b.isConnected){status.textContent=error.message;group.forEach(x=>x.disabled=false)}}
      };
    }
    const form=current.querySelector('form');
    if(form)form.onsubmit=async e=>{
      e.preventDefault();
      const save=e.submitter;save.disabled=true;
      const data=Object.fromEntries(new FormData(form));
      try{
        await rpc(teacher?'notes':'suggest',{id:l.id,...data});
        if(teacher)Object.assign(l,data);
        if(form.isConnected){status.textContent=teacher?'حُفظ التأمل والإجراء.':'حُفظ اقتراحكِ.';if(!teacher)form.remove()}
      }catch(error){if(form.isConnected)status.textContent=error.message}
      finally{save.disabled=false}
    };
  }
  grid.onclick=e=>{
    const target=e.target.closest('[data-mirror]');if(target){status.textContent='';lessonView(lessons.find(l=>l.id===target.dataset.mirror))}
  };
  async function load(){
    if(loaded)return;
    status.textContent='جارٍ تحميل الدروس…';
    try{
      lessons=admin?report:await rpc(teacher?'report':'lessons',{});
      if(!root.isConnected)return;
      loaded=true;
      const groups=[['course','الصف',l=>l.course==='Mega Goal 1'?'أول ثانوي':l.course==='Mega Goal 3'?'ثالث ثانوي':l.course],['unit','الوحدة',l=>l.unit],['week','الأسبوع الدراسي',l=>l.week]];
      filters.innerHTML=groups.map(([key,label,display])=>`<label>${label}<select name="${key}"><option value="">الكل</option>${[...new Map(lessons.map(l=>[l[key],display(l)]))].map(([k,v])=>`<option value="${esc(k)}">${esc(v)}</option>`).join('')}</select></label>`).join('')+(reads?button('طباعة التقرير / حفظ PDF','print'):'');
      filters.onchange=draw;
      const printer=filters.querySelector('[data-mirror=print]');if(printer)printer.onclick=()=>print(visible());
      draw();
    }catch(error){
      if(!root.isConnected)return;
      status.textContent=error.message;
      current.innerHTML=button('إعادة المحاولة','retry');
      current.querySelector('button').onclick=()=>{current.replaceChildren();void load()};
    }
  }
  void load();
}

export {mountMirror};
