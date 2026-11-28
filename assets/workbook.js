import {printPrivateTable,downloadWorkbook} from './spreadsheet.js';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(label,action)=>`<button type="button" class="workbook-button" data-workbook="${action}">${label}</button>`;
const imageNames=['sneakers','brand','detergent','shampoo','car'];
const imagePath=name=>new URL('./workbook/'+name+'.webp',import.meta.url).href;
const workbookTitle='الملزمة التفاعلية | Interactive Workbook';

export function workbookReport(rows=[]){
  const root=document.createElement('div');
  root.className='workbook-report';
  const titles=['الطالبة','الفصل','الوحدة','الدرس','المحاولات','المكتملة','أفضل درجة','درجات المحاولات','حالة الدرس'];
  const classes=[...new Set(rows.map(r=>r.class_name))];
  root.innerHTML='<label>الفصل <select><option value="">الكل</option>'+classes.map(c=>`<option>${escape(c)}</option>`).join('')+'</select></label>'+
    '<p data-summary></p><div class="secure-table" data-table></div>'+button('طباعة / حفظ PDF','print')+button('Excel','excel');
  let data=[titles];
  const draw=()=>{
    const chosen=root.querySelector('select').value;
    const visible=rows.filter(r=>!chosen||r.class_name===chosen);
    const published=visible.filter(r=>r.published);
    const done=published.filter(r=>r.completed>0).length;
    root.querySelector('[data-summary]').textContent=visible.length?`الإنجاز ${done} من ${published.length} تكليفًا منشورًا (${published.length?Math.round(done*100/published.length):0}٪)`:'لا توجد نتائج متاحة.';
    data=[titles,...visible.map(r=>[r.full_name,r.class_name,r.unit,r.title,r.attempts,r.completed,r.best==null?'—':r.best+'٪',(r.scores||[]).map(n=>n+'٪').join('، ')||'—',r.published?'منشور':'مغلق'])];
    root.querySelector('[data-table]').innerHTML='<table><thead><tr>'+titles.map(v=>`<th>${escape(v)}</th>`).join('')+'</tr></thead><tbody>'+
      data.slice(1).map(row=>'<tr>'+row.map(v=>`<td>${escape(v)}</td>`).join('')+'</tr>').join('')+'</tbody></table>';
  };
  root.querySelector('select').onchange=draw;draw();
  root.querySelector('[data-workbook=print]').onclick=()=>printPrivateTable(workbookTitle+' — تقرير الإنجاز',data);
  root.querySelector('[data-workbook=excel]').onclick=()=>downloadWorkbook('workbook-results.xlsx','الملزمة',data);
  return root;
}

function chime(){
  try{
    const Audio=window.AudioContext||window.webkitAudioContext;
    if(!Audio)return;
    const audio=new Audio(), gain=audio.createGain();
    gain.gain.setValueAtTime(.12,audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(.001,audio.currentTime+.23);
    gain.connect(audio.destination);
    const tone=audio.createOscillator();
    tone.frequency.setValueAtTime(587.3,audio.currentTime);
    tone.frequency.setValueAtTime(783.99,audio.currentTime+.09);
    tone.connect(gain);tone.start();tone.stop(audio.currentTime+.24);
    tone.onended=()=>{void audio.close()};
  }catch{/* Sound is optional on browsers without audio access. */}
}

export function workbookLink(book,options){
  const entry=document.createElement('button');
  entry.type='button';entry.className='tile';entry.textContent='🛍️ '+workbookTitle;
  entry.onclick=()=>openWorkbook(book,options,entry);
  return entry;
}

function openWorkbook(book,{rpc,teacher=false,classes=[],students=[]},entry){
  const dialog=document.createElement('dialog');
  dialog.className='workbook-dialog';dialog.setAttribute('aria-label',workbookTitle);
  dialog.innerHTML='<header class="workbook-heading"><span>🛒 '+escape(book.course)+' • Unit '+escape(book.unit)+'</span><h2 lang="en">'+escape(book.title)+'</h2>'+
    '<p>'+workbookTitle+'</p>'+button('إغلاق الملزمة','close')+'</header><div class="workbook-content"><p role="status" data-message></p><div data-view></div></div>';
  entry.after(dialog);
  dialog.addEventListener('close',()=>{dialog.remove();if(entry.isConnected)entry.focus()},{once:true});
  dialog.querySelector('[data-workbook=close]').onclick=()=>dialog.close();
  dialog.showModal();
  const view=dialog.querySelector('[data-view]'), message=dialog.querySelector('[data-message]');
  const show=(body)=>{message.textContent='';view.innerHTML=body;dialog.scrollTop=0};
  const query=(action)=>view.querySelector('[data-workbook="'+action+'"]');
  const on=(action,fn)=>{const b=query(action);if(b)b.onclick=async()=>{b.disabled=true;try{await fn()}catch(err){message.textContent=err.message}finally{b.disabled=false}}};
  const call=(op,data={})=>rpc(op,{book:book.id,...data});
  const back=button('العودة إلى دروس الملزمة','home');
  let muted=false;

  function home(){
    show('<div class="nav">'+(book.lessons||[]).map((l,i)=>`<button type="button" class="workbook-tile" data-lesson="${i}"><span>${escape(l.icon)}</span><b lang="en">${escape(l.title)}</b>${teacher?'<small>'+(l.published?'منشور':'مغلق')+'</small>':l.completed?'<small>✅ مكتمل</small>':''}</button>`).join('')+'</div>'+
      button('تقرير الإنجاز','report')+button(muted?'تشغيل صوت الإجابة':'كتم صوت الإجابة','sound'));
    on('sound',()=>{muted=!muted;home()});
    on('report',async()=>{const data=(await call('report')).filter(row=>!row.book||row.book===book.id);show(back+'<h3>تقرير الإنجاز</h3><div data-results></div>');view.querySelector('[data-results]').append(workbookReport(data));on('home',home)});
    for(const b of view.querySelectorAll('[data-lesson]'))b.onclick=async()=>{
      b.disabled=true;
      try{
        const lesson=book.lessons[Number(b.dataset.lesson)];
        if(teacher)edit(await call('edit',{id:lesson.id}),lesson);
        else play(lesson,await call('start',{id:lesson.id}));
      }catch(err){message.textContent=err.message}finally{b.disabled=false}
    };
  }

  function wordCards(l){
    const groups=l.position===1?book.vocabulary:l.position===5?book.vocabulary.slice(-1):[];
    if(!groups.length)return '';
    return '<details class="secure-card"'+(l.position===1?' open':'')+'><summary>🃏 بطاقات المفردات</summary>'+
      groups.map(g=>`<h4 lang="en">${escape(g.group)}</h4><div class="workbook-cards">${g.words.map(w=>`<article><button type="button" class="workbook-button" data-say="${escape(w.word)}" aria-label="نطق ${escape(w.word)}">🔊</button><b lang="en" dir="ltr">${escape(w.word)}</b><p lang="en" dir="ltr">${escape(w.en)}</p><p>${escape(w.ar)}</p></article>`).join('')}</div>`).join('')+'</details>';
  }

  function play(lesson,state,preview=null){
    const errors=state.step-state.score;
    show(back+`<h3 lang="en">${escape(lesson.title)}</h3><div class="workbook-progress"><span aria-label="القلوب"> ${'💗'.repeat(Math.max(0,3-errors))}${'🤍'.repeat(Math.min(3,errors))}</span><label>التقدم ${state.step} / ${state.total} <progress max="${state.total}" value="${state.step}"></progress></label></div>`+
      wordCards(lesson)+(preview?'<p>معاينة المعلمة دون حفظ محاولة</p>':'')+
      (state.completed?`<div class="secure-card"><h3>أحسنتِ! أكملتِ التدريب 🌟</h3><p>النتيجة ${state.score} من ${state.total}</p>${button('إعادة المحاولة','retry')}</div>`:
      `<section class="secure-card" data-question><p>${state.question.type==='image'?'مطابقة الصورة':state.question.type==='match'?'مطابقة المعنى':state.question.type==='correction'?'اختيار التصحيح المناسب':'اختيار من متعدد'}</p>
      <h4 lang="en" dir="ltr">${escape(state.question.prompt)}</h4>${state.question.type==='image'&&imageNames.includes(state.question.image)?`<img class="workbook-picture" src="${imagePath(state.question.image)}" alt="صورة المطابقة، سؤال ${state.step+1}">`:''}
      <div class="workbook-choices" lang="en" dir="ltr">${state.question.choices.map((c,i)=>`<button type="button" class="workbook-button" data-choice="${i}">${escape(c)}</button>`).join('')}</div><p data-feedback role="status"></p><div data-next></div></section>`));
    on('home',home);
    on('retry',async()=>play(lesson,preview?previewState(preview):await call('start',{id:lesson.id,retry:true}),preview));
    for(const b of view.querySelectorAll('[data-say]'))b.onclick=()=>{
      if(!window.speechSynthesis||!window.SpeechSynthesisUtterance){message.textContent='النطق غير متاح في هذا المتصفح.';return}
      const speech=new SpeechSynthesisUtterance(b.dataset.say);speech.lang='en-US';speech.rate=.85;
      window.speechSynthesis.cancel();window.speechSynthesis.speak(speech);
    };
    const choices=[...view.querySelectorAll('[data-choice]')];
    for(const b of choices)b.onclick=async()=>{
      choices.forEach(c=>c.disabled=true);
      try{
        const chosen=state.question.choices[Number(b.dataset.choice)];
        const correct=chosen===state.question.correct;
        const next=preview?{...previewState(preview,state.step+1,state.score+(correct?1:0)),correct,expected:state.question.correct}:
          await call('answer',{id:lesson.id,attempt:state.id,step:state.step,choice:chosen});
        if(next.completed&&!preview)lesson.completed=true;
        if(!b.isConnected)return;
        if(next.correct&&!muted)chime();
        const feedback=view.querySelector('[data-feedback]');
        feedback.textContent=next.correct?'✅ إجابة صحيحة!':'الإجابة المناسبة: '+next.expected;
        view.querySelector('[data-next]').innerHTML=button(next.completed?'عرض النتيجة':'السؤال التالي','next');
        on('next',()=>play(lesson,next,preview));
        query('next').focus();
      }catch(err){if(b.isConnected){message.textContent=err.message;choices.forEach(c=>c.disabled=false)}}
    };
  }

  function previewState(questions,step=0,score=0){
    return {question:questions[step],step,score,total:questions.length,completed:step===questions.length};
  }

  function edit(data,lesson){
    const eligibleClasses=classes.filter(c=>c.course===book.course);
    const pick=(label,name,items,selected,nameOf)=>`<label>${label}<select multiple name="${name}" size="4">${items.map(v=>`<option value="${escape(v.id)}" ${selected.includes(v.id)?'selected':''}>${escape(nameOf(v))}</option>`).join('')}</select></label>`;
    show(back+`<h3 lang="en">${escape(lesson.title)}</h3><form>
      <label><input type="checkbox" name="published" ${data.published?'checked':''}> إتاحة الدرس للطالبات المستهدفات</label>
      <div class="secure-grid">${pick('الفصول','classes',eligibleClasses,data.classes,c=>c.name)}${pick('طالبات محددات','students',students.filter(s=>eligibleClasses.some(c=>c.id===s.class_id)),data.students,s=>s.full_name+' — '+eligibleClasses.find(c=>c.id===s.class_id).name)}</div>
      <div data-editor></div>${button('إضافة سؤال','add')}${button('معاينة التدريب','preview')} <button class="action">حفظ الدرس</button></form>`);
    on('home',home);
    const form=view.querySelector('form'), target=view.querySelector('[data-editor]');
    function add(q={type:'choice',prompt:'',choices:['',''],correct:''}){
      const box=document.createElement('fieldset');box.className='secure-card';
      box.innerHTML='<legend>سؤال</legend><label>النوع <select name="type">'+Object.entries({choice:'اختيار من متعدد',match:'مطابقة معنى',image:'مطابقة صورة',correction:'تصحيح خطأ'}).map(([v,n])=>`<option value="${v}">${n}</option>`).join('')+'</select></label>'+
        '<label data-image>صورة المطابقة <select name="image">'+imageNames.map(n=>`<option>${n}</option>`).join('')+'</select></label>'+
        '<label>نص السؤال <textarea name="prompt" rows="2" maxlength="600" required></textarea></label><label>الخيارات، خيار في كل سطر <textarea name="choices" rows="3" required></textarea></label>'+
        '<label>رقم الخيار الصحيح <input type="number" name="correct" min="1" max="15" required></label>'+button('إزالة السؤال','remove');
      const field=name=>box.querySelector('[name="'+name+'"]');
      field('type').value=q.type;field('image').value=q.image||imageNames[0];field('prompt').value=q.prompt;
      field('choices').value=q.choices.join('\n');field('correct').value=q.choices.indexOf(q.correct)+1||1;
      const update=()=>{box.querySelector('[data-image]').hidden=field('type').value!=='image'};field('type').onchange=update;update();
      box.querySelector('button').onclick=()=>{if(target.children.length>1)box.remove()};target.append(box);
    }
    const extract=()=>{
      if(!form.reportValidity())throw Error('أكملي حقول الأسئلة.');
      return [...target.children].map(box=>{
        const value=name=>box.querySelector('[name="'+name+'"]').value;
        const choices=value('choices').split(/\r?\n/).map(x=>x.trim()).filter(Boolean),correct=choices[+value('correct')-1];
        if(!correct||choices.length<2||choices.length>15||new Set(choices).size!==choices.length)throw Error('راجعي الخيارات ورقم الإجابة الصحيحة.');
        const type=value('type');
        return {type,prompt:value('prompt').trim(),choices,correct,...(type==='image'?{image:value('image')}:{})};
      })
    };
    data.questions.forEach(add);
    on('add',()=>{if(target.children.length<100)add()});
    on('preview',()=>{const q=extract();play(lesson,previewState(q),q)});
    form.onsubmit=async event=>{
      event.preventDefault();const b=event.submitter;b.disabled=true;
      try{
        const selected=key=>[...form.elements[key].selectedOptions].map(o=>o.value);
        const published=form.elements.published.checked;
        await call('save',{id:lesson.id,revision:data.revision,questions:extract(),published,classes:selected('classes'),students:selected('students')});
        lesson.published=published;home();message.textContent='حُفظ الدرس وإعدادات الإتاحة.';
      }catch(err){message.textContent=err.message}finally{b.disabled=false}
    };
  }
  home();
}
