import {downloadWorkbook,printPrivateTable} from './spreadsheet.js';

const names={listening:'🎧 Listening – الاستماع',speaking:'🎙️ Speaking – التحدث',reading:'📖 Reading – القراءة',writing:'✍️ Writing – الكتابة'};
const levels={beginner:'مبتدئ',intermediate:'متوسط',advanced:'متقدم'};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(label,action)=>`<button type="button" class="action secondary" data-act="${action}">${label}</button>`;
const opts=entries=>entries.map(([v,k])=>`<option value="${esc(v)}">${esc(k)}</option>`).join('');
const objective=k=>['reading','listening'].includes(k);
function progressView(rows=[]){
  const root=document.createElement('div');
  const people=[...new Map(rows.map(r=>[r.student_key||r.class_name+' '+r.full_name,r])).entries()];
  root.innerHTML='<h3>تقدم المهارات الأربع</h3>'+(people.length>1?`<label>الطالبة <select>${opts(people.map(([id,r],i)=>[i,r.full_name+' — '+r.class_name]))}</select></label>`:'')+'<div data-charts></div>'+button('طباعة / حفظ PDF','print')+button('Excel','export');
  let sheet;
  function render(){
    const who=people[Number(root.querySelector('select')?.value||0)]?.[0];
    const scoped=rows.filter(r=>(r.student_key||r.class_name+' '+r.full_name)===who);
    const pct=r=>r.total?Math.round(r.completed*100/r.total):0;
    sheet=[['الطالبة','الفصل','المهارة','الإنجاز ٪','المكتمل','المتبقي','متوسط الدرجة'],...scoped.map(r=>[r.full_name,r.class_name,names[r.skill],pct(r),r.completed,r.total-r.completed,r.average??'—']),[],['المهارة','تاريخ المحاولة','متوسط الدرجة اليومي'],...scoped.flatMap(r=>(r.trend||[]).map(([d,v])=>[names[r.skill],d,v]))];
    root.querySelector('[data-charts]').innerHTML=scoped.map(r=>`<article class="secure-card"><h3>${names[r.skill]}</h3><p>مكتمل ${r.completed} من ${r.total} · المتبقي ${r.total-r.completed} · متوسط الدرجة ${r.average??'—'}</p><label>نسبة الإنجاز ${pct(r)}٪ <progress value="${r.completed}" max="${r.total||1}"></progress></label>${(r.trend||[]).map(([d,v])=>`<p>${esc(d)} <meter min="0" max="100" value="${v}"></meter> ${v}٪</p>`).join('')}</article>`).join('')||'<p>لا توجد بيانات متاحة.</p>';
  }
  root.onchange=render;render();
  root.querySelector('[data-act=print]').onclick=()=>printPrivateTable('آفاق الطلاقة — تقرير المهارات',sheet);
  root.querySelector('[data-act=export]').onclick=()=>downloadWorkbook('Fluency-Horizons.xlsx','تقدم المهارات',sheet);
  return root;
}
function mountFluency(root,{rpc,teacher=false,classes=[],students=[],readFile}){
  root.innerHTML='<p lang="en" dir="ltr">Four Skills, One Journey to Excellence</p><div class="nav">'+Object.entries(names).map(([k,n])=>`<button class="tile" data-skill="${k}">${n}</button>`).join('')+'</div>'+button('لوحة تقدم المهارات','progress')+'<p role="status" data-note></p><div data-out></div>';
  const out=root.querySelector('[data-out]'),note=root.querySelector('[data-note]');
  const media=id=>id?button('فتح المرفق','media-'+id):'';
  let skill,items=[],version=0;
  function display(el,blob){
    const url=URL.createObjectURL(blob);el.src=url;
    const observer=new MutationObserver(()=>{if(!el.isConnected||el.src!==url){URL.revokeObjectURL(url);observer.disconnect()}});
    observer.observe(root.parentNode||document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
    el.addEventListener('emptied',()=>{if(el.src!==url)URL.revokeObjectURL(url)},{once:true});
  }
  async function list(){
    const seq=++version;out.replaceChildren();note.textContent='جارٍ التحميل…';
    const data=await rpc('list',{skill});if(seq!==version||!root.isConnected)return;items=data||[];note.textContent='';
    out.innerHTML=`<h3>${names[skill]}</h3>`+(teacher?button('إضافة تدريب أسبوعي','new'):'')+items.map((t,i)=>`<article class="secure-card" data-index="${i}"><h3>${esc(t.title)}</h3><p>${levels[t.level]} · ${t.published?'منشور':'غير منشور'}</p><div class="flex">${teacher?[['معاينة','preview'],['تعديل','edit'],['نسخ','copy'],[t.published?'إيقاف النشر':'نشر','publish'],['تقييم المحاولات','reviews'],['حذف','archive']].map(([n,k])=>button(n,k)).join(''):button('فتح التدريب والنتائج','open')}</div></article>`).join('')+(items.length?'':'<p>لا توجد تدريبات مضافة لهذه المهارة.</p>');
  }
  function editor(t={},copy=false){
    const choices=(key,label,rows)=>`<label>${label}<select multiple size="4" name="${key}">${opts(rows)}</select></label>`;
    out.innerHTML=button('العودة للتدريبات','back')+'<form class="secure-card"><label>عنوان التدريب <input name="title" maxlength="200" required></label><label>المستوى <select name="level">'+opts(Object.entries(levels))+'</select></label><label>النص أو التعليمات بالإنجليزية <textarea name="prompt" maxlength="16000" required></textarea></label><label>موعد التسليم <input type="datetime-local" name="due"></label><label>عدد المحاولات <input name="attempts" type="number" min="1" max="30" required></label><label>المرفق (حتى 1.5 ميغابايت) <input name="file" type="file" accept="'+(skill==='listening'?'audio/*':'.pdf,.png,.jpg,.jpeg,.m4a,.mp3,.ogg,.wav,.webm')+'"></label>'+media(t.file_id)+'<label>المرحلة <select name="grade"><option value="">الكل</option>'+opts([...new Set(classes.map(c=>c.grade_level))].map(n=>[n,n]))+'</select></label>'+choices('classes','الفصول المستهدفة',classes.map(c=>[c.id,c.name]))+choices('students','أو طالبات محددات',students.map(s=>[s.id,s.full_name+' — '+(classes.find(c=>c.id===s.class_id)?.name||'')]))+(objective(skill)?'<div data-questions></div>'+button('إضافة سؤال','question'):'')+'<button class="action">حفظ التدريب</button></form>';
    const f=out.querySelector('form'),e=f.elements;
    e.title.value=(t.title||'')+(copy?' — نسخة':'');e.prompt.value=t.prompt||'';e.level.value=t.level||'beginner';e.attempts.value=t.attempts||1;
    if(t.due_at){const d=new Date(t.due_at);e.due.value=new Date(+d-d.getTimezoneOffset()*60000).toISOString().slice(0,16)}
    for(const o of e.students.options)o.selected=!copy&&t.targets?.includes(o.value);
    e.grade.onchange=()=>{for(const select of [e.classes,e.students])for(const o of select.options){
      const id=select===e.classes?o.value:students.find(s=>s.id===o.value)?.class_id;
      o.hidden=!!e.grade.value&&classes.find(c=>c.id===id)?.grade_level!==e.grade.value;if(o.hidden)o.selected=false}};
    function question(q={}){
      const field=document.createElement('fieldset');
      field.innerHTML='<legend>سؤال الفهم</legend><label>السؤال <input required></label><label>الخيارات، كل خيار في سطر <textarea required></textarea></label><label>رقم الخيار الصحيح <input type="number" min="1" max="10" required></label>'+button('إزالة السؤال','remove');
      const [prompt,choices,correct]=field.querySelectorAll('input,textarea');prompt.value=q.prompt||'';choices.value=(q.choices||[]).join('\n');correct.value=q.choices?q.choices.indexOf(q.correct)+1:1;
      field.querySelector('button').onclick=()=>field.remove();f.querySelector('[data-questions]').append(field);
    }
    if(objective(skill)){(t.questions?.length?t.questions:[{}]).forEach(question);f.querySelector('[data-act=question]').onclick=()=>question()}
    f.onsubmit=async ev=>{
      ev.preventDefault();const submit=ev.submitter;submit.disabled=true;
      try{
        const questions=[...f.querySelectorAll('fieldset')].map(b=>{
          const [p,c,n]=b.querySelectorAll('input,textarea');const choices=c.value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
          if(choices.length<2||choices.length>10||!choices[n.value-1]||new Set(choices).size!==choices.length)throw Error('راجعي خيارات السؤال ورقم الإجابة الصحيحة');
          return {prompt:p.value,choices,correct:choices[n.value-1]};
        });
        const selected=s=>[...s.selectedOptions].map(o=>o.value);
        await rpc(copy?'copy':'save',{id:t.id,revision:t.revision,title:e.title.value,skill,level:e.level.value,prompt:e.prompt.value,questions,attempts:+e.attempts.value,due_at:e.due.value?new Date(e.due.value).toISOString():null,classes:selected(e.classes),students:selected(e.students),...await readFile(e.file.files[0])});
        if(f.isConnected){await list();note.textContent='حُفظ التدريب'}
      }catch(error){note.textContent=error.message}finally{submit.disabled=false}
    };
  }
  function work(t,review){
    return (t.work||[]).map(w=>`<article class="secure-card"><strong>${esc(w.name)} · المحاولة ${w.attempt}</strong><p>${w.score==null?'بانتظار تقييم المعلمة':w.score+'٪'}</p><p dir="auto">${esc(Array.isArray(w.answers)?w.answers.join(' · '):w.answers)}</p>${media(w.file_id)}<p>${esc(w.feedback)}</p>${review&&!objective(skill)?`<form data-review="${esc(w.id)}"><label>الدرجة من 100 <input type="number" min="0" max="100" required name="score" value="${w.score??''}"></label><label>التغذية الراجعة <textarea name="feedback" maxlength="4000">${esc(w.feedback)}</textarea></label><button class="action">حفظ التقييم</button></form>`:''}</article>`).join('')||'<p>لا توجد محاولات بعد.</p>';
  }
  function exercise(t,preview){
    const eligible=!preview&&t.published&&t.work.length<t.attempts&&(!t.due_at||Date.parse(t.due_at)>Date.now());
    out.innerHTML=button('العودة للتدريبات','back')+`<div class="secure-card"><h3>${esc(t.title)}</h3><p>${levels[t.level]} · المحاولات ${t.attempts}${t.due_at?' · التسليم '+esc(new Date(t.due_at).toLocaleString('ar-SA')):''}</p><p dir="auto" style="white-space:pre-wrap">${esc(t.prompt)}</p>${media(t.file_id)}</div><form class="secure-card">`+(objective(skill)?t.questions.map((q,i)=>`<fieldset><legend>${esc(q.prompt)}</legend>${q.choices.map((v,j)=>`<label class="quiz-option"><input required type="radio" name="q${i}" value="${j}"> ${esc(v)}</label>`).join('')}</fieldset>`).join(''):skill==='writing'?'<label>إجابتك <textarea name="answer" dir="auto" maxlength="16000" required></textarea></label>':'<label>رفع تسجيل صوتي <input name="voice" type="file" accept="audio/*"></label>'+button('بدء التسجيل','record')+'<audio controls hidden></audio>')+(eligible?'<button class="action">تسليم المحاولة</button>':'')+'</form>'+(!preview?work(t,false):'');
    const f=out.querySelector('form'),rec=f.querySelector('[data-act=record]');let recorder,recorded;
    if(rec)rec.onclick=async()=>{
      try{
        if(recorder?.state==='recording'){recorder.stop();return}
        if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)throw Error('يمكنك رفع ملف صوتي من هذا المتصفح');
        rec.disabled=true;const stream=await navigator.mediaDevices.getUserMedia({audio:true});const stop=()=>stream.getTracks().forEach(x=>x.stop());
        if(!f.isConnected||!f.getClientRects().length){stop();return}
        try{recorder=new MediaRecorder(stream);recorder.start()}catch(error){stop();throw error}
        const chunks=[];const observer=new MutationObserver(()=>{if((!f.isConnected||!f.getClientRects().length)&&recorder.state==='recording')recorder.stop()});
        observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class','hidden']});
        const timer=setTimeout(()=>{if(recorder.state==='recording')recorder.stop()},60000);
        recorder.ondataavailable=e=>chunks.push(e.data);
        recorder.onstop=()=>{clearTimeout(timer);observer.disconnect();stop();if(!f.isConnected)return;const mime=recorder.mimeType.split(';')[0];recorded=new File(chunks,'voice.'+(mime.includes('mp4')?'m4a':mime.includes('ogg')?'ogg':'webm'),{type:mime});rec.textContent='إعادة التسجيل';const a=f.querySelector('audio');display(a,recorded);a.hidden=false};
        rec.textContent='إيقاف التسجيل';
      }catch(error){note.textContent=error.message}finally{rec.disabled=false}
    };
    f.onsubmit=async ev=>{
      ev.preventDefault();if(!eligible)return;
      const submit=ev.submitter;submit.disabled=true;
      try{
        if(recorder?.state==='recording')throw Error('أوقفي التسجيل قبل تسليمه');
        const data=new FormData(f);
        const answers=objective(skill)?t.questions.map((q,i)=>q.choices[Number(data.get('q'+i))]):data.get('answer');
        const result=await rpc('submit',{id:t.id,answers,...await readFile(f.elements.voice?.files[0]||recorded)});
        if(f.isConnected){await list();note.textContent=result.score==null?'حُفظت المحاولة للمراجعة':'درجتك '+result.score+'٪'}
      }catch(error){note.textContent=error.message}finally{submit.disabled=false}
    };
  }
  root.onclick=async ev=>{
    const b=ev.target.closest('button');if(!b)return;
    try{
      if(b.dataset.skill){skill=b.dataset.skill;await list();return}
      const action=b.dataset.act;
      if(action==='back'){await list();return}
      if(action==='new'){editor();return}
      if(action==='progress'){const seq=++version;out.replaceChildren();const rows=await rpc('progress',{});if(seq===version)out.replaceChildren(progressView(rows));return}
      if(action?.startsWith('media-')){
        const file=await rpc('file',{id:action.slice(6)});if(!b.isConnected)return;
        const blob=new Blob([Uint8Array.from(atob(file.body),c=>c.charCodeAt(0))],{type:file.mime});
        if(file.mime.startsWith('audio/')||file.mime.startsWith('image/')){const el=document.createElement(file.mime.startsWith('audio/')?'audio':'img');el.controls=true;el.alt='مرفق التدريب';el.style.maxWidth='100%';b.replaceWith(el);display(el,blob)}
        else{const link=document.createElement('a');const url=URL.createObjectURL(blob);link.href=url;link.download=file.mime==='video/mp4'?'attachment.mp4':'attachment.pdf';link.click();setTimeout(()=>URL.revokeObjectURL(url),30000)}return;
      }
      const entry=b.closest('[data-index]');if(!entry)return;const t=items[Number(entry.dataset.index)];
      if(action==='edit'||action==='copy')editor(t,action==='copy');
      if(action==='open'||action==='preview')exercise(t,action==='preview');
      if(action==='publish'||action==='archive'){
        if(action==='archive'&&!confirm('حذف التدريب من القائمة وحفظ النتائج السابقة؟'))return;b.disabled=true;
        await rpc(action,{id:t.id,revision:t.revision,published:!t.published});await list();
      }
      if(action==='reviews'){
        out.innerHTML=button('العودة للتدريبات','back')+work(t,true);
        for(const f of out.querySelectorAll('[data-review]'))f.onsubmit=async e=>{e.preventDefault();const submit=e.submitter;submit.disabled=true;try{await rpc('review',{id:f.dataset.review,score:+f.elements.score.value,feedback:f.elements.feedback.value});await list();note.textContent='حُفظ التقييم'}catch(error){note.textContent=error.message}finally{submit.disabled=false}};
      }
    }catch(error){note.textContent=error.message;b.disabled=false}
  };
}

export {mountFluency,progressView};
