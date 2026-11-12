const portalEscape = value => String(value ?? "").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const kzDate = new Intl.DateTimeFormat("ru-RU",{timeZone:"Asia/Almaty",dateStyle:"short",timeStyle:"short"});
const stamp = seconds => kzDate.format(seconds*1000);
const money = value => Number(value).toLocaleString("ru-RU")+" ₸";
const durationText = seconds => seconds%86400===0 ? (seconds/86400)+" дн." : (seconds/3600)+" ч";
function dashboardView(root, admin, request, refresh, editProfile) {
  let data, selected=admin?"@owner":"", filter="", page=0;
  const h=portalEscape;
  function paint(){
    const accounts=data.accounts;
    const account=accounts.find(a=>a.uid===selected);
    const keys=data.keys.filter(k=>!selected || (selected==="@owner" ? k.owner : k.uid===selected));
    const sales=data.sales.filter(s=>!selected || (selected==="@owner" ? s.owner : s.uid===selected));
    const sum=field=>sales.reduce((v,s)=>v+Number(s[field]||0),0);
    const now=data.started??Date.now()/1000;
    function state(k){
      if(k.revoked)return "Отозван";
      if(k.expires!==null && k.expires<=now)return "Истёк";
      if(!k.devices)return "Без устройства";
      return k.used ? "Активен" : "Устройства отключены";
    }
    const states=["Активен","Без устройства","Истёк","Отозван","Устройства отключены"];
    const visible=keys.filter(k=>!filter||state(k)===filter);
    page=Math.min(page,Math.max(0,Math.ceil(visible.length/25)-1));
    const metrics=[["Продано сегодня",sum("today")],["За 7 дней",sum("week")],["Всего продаж",sum("total")],["Сумма закупок",money(sum("amount"))],["Активные ключи",keys.filter(k=>state(k)==="Активен").length],["Без устройства",keys.filter(k=>state(k)==="Без устройства").length]];
    if(admin && (!selected || selected==="@owner")){
      metrics.push(["Ручная выдача сегодня",data.manual.today],["Ручная выдача за 7 дней",data.manual.week],["Всего выдано вручную",data.manual.total]);
    }
    if(account)metrics.unshift(["Баланс",money(account.balance)]);
    root.innerHTML=`
      ${admin?`<details class="controls" ${selected?"open":""}><summary>Реселлеры · ${accounts.length}</summary><div class="profiles"><button data-uid="@owner" aria-pressed="${selected==='@owner'}">Моя статистика</button><button data-uid="" aria-pressed="${selected===''}">Общая статистика</button><button data-act="add">＋ Добавить реселлера</button>${accounts.map(a=>`<button class="profile" data-uid="${h(a.uid)}" aria-pressed="${a.uid===selected}">${h(a.name||"Реселлер "+a.uid)}<small>${money(a.balance)} · ${a.enabled?"API включён":"API выключен"}</small></button>`).join("")}</div></details>`:""}
      <div class="bar"><h2>${h(account?.name || (account?"Реселлер "+account.uid:(selected==="@owner"?"Моя статистика":"Общая статистика")))}</h2>${admin&&account?'<button data-act="profile">Изменить профиль и цены</button>':''}</div>
      <div class="metrics">${metrics.map(([label,n])=>`<div class="metric"><small>${label}</small><strong>${n}</strong></div>`).join("")}</div>
      <small>${selected==="@owner"?"Заказы основного бота от покупателей без API реселлера.":"Продажи по заказам бота и API."} Ручная выдача показана отдельно. Сумма — платежи в системе, ручные оплаты учитываются по факту заказов. Сегодня и последние 7 календарных дней по времени Астаны.${sum("undated")?" Без даты продажи: "+sum("undated")+".":""}</small>
      <section><div class="bar"><h2>Ключи · ${keys.length}</h2><label>Статус<select id="key-filter"><option value="">Все статусы</option>${states.map(s=>`<option ${s===filter?"selected":""}>${s}</option>`).join("")}</select></label></div>
      <div class="table"><table><thead><tr><th>Ключ</th><th>Срок</th><th>Состояние</th><th>Окончание · Астана</th></tr></thead><tbody>
      ${visible.slice(page*25,page*25+25).map(k=>`<tr><td><details><summary>Ключ №${k.id}${k.suffix?" · …"+h(k.suffix):""}</summary><p>Создан ${stamp(k.created)}</p>${k.revealable?`<button data-show="${k.id}">Показать ключ</button><code class="key"></code>`:"Полный номер сохранён только у получателя."}
      ${admin?`<div class="actions"><button data-edit="${k.id}">Изменить</button>${k.revoked?"":`<button data-revoke="${k.id}">Отозвать</button>`}<button class="danger" data-delete="${k.id}">Удалить</button></div>${(data.devices||[]).filter(d=>d.license===k.id).map(d=>`<p><code>${h(d.device)}</code> ${d.blocked?"Отключено":`<button data-block="${k.id}" data-device="${h(d.device)}">Отключить</button>`}</p>`).join("")}`:""}</details></td>
      <td data-label="Срок">${durationText(k.lifetime)}</td><td data-label="Статус">${state(k)} · ${k.used}/${k.seats}</td><td data-label="До">${k.expires===null?"С первой активации":stamp(k.expires)}</td></tr>`).join("")}</tbody></table></div>
      ${visible.length?"":"<p>Нет ключей с таким статусом.</p>"}
      ${visible.length>25?`<div class="actions"><button data-step="-1" ${page===0?"disabled":""}>Назад</button>${page+1} / ${Math.ceil(visible.length/25)}<button data-step="1" ${(page+1)*25>=visible.length?"disabled":""}>Далее</button></div>`:""}</section><p role="alert" class="error"></p>`;
    root.querySelector("select").onchange=e=>{filter=e.target.value;page=0;paint()};
  }
  root.onclick=async e=>{
    const b=e.target.closest("button"); if(!b)return;
    try{
      const d=b.dataset;
      if("uid" in d){selected=d.uid;filter="";page=0;paint();return}
      if(d.step){page+=Number(d.step);paint();return}
      if(d.show){const r=await request("show/"+d.show);b.nextElementSibling.textContent=r.key;b.hidden=true;return}
      if(!admin)return;
      if(d.act==="add"){editProfile({uid:"",name:"",prices:"{}"});return}
      if(d.act==="profile"){editProfile(data.accounts.find(a=>a.uid===selected));return}
      const id=d.edit||d.revoke||d.delete||d.block;
      const key=data.keys.find(k=>k.id===Number(id));
      if(!key)return;
      if(d.edit){
        const hours=prompt("Общий срок в часах. Окончание сдвинется на разницу.",key.lifetime/3600);
        if(hours===null)return;
        const seats=prompt("Сколько устройств разрешить?",key.seats);
        if(seats===null)return;
        await request("keys/"+id+"/edit","POST",{hours:Number(hours),seats:Number(seats)});
      }else{
        if(!confirm(d.delete?"Удалить ключ №"+id+" навсегда?":d.block?"Отключить это устройство?":"Отозвать ключ №"+id+"?"))return;
        await request("keys/"+id+(d.revoke?"/revoke":d.block?"/devices/"+encodeURIComponent(d.device)+"/block":""),d.delete?"DELETE":"POST");
      }
      await refresh();
    }catch(error){root.querySelector('[role="alert"]').textContent=error.message}
  };
  return next=>{data=next;if(!admin)selected=data.accounts[0]?.uid||"";paint()};
}
