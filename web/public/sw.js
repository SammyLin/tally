// Web Push only (no caching/offline): show the notification, focus or open Tally on click.
self.addEventListener('push',e=>{
  let m={};try{m=e.data.json()}catch{}
  e.waitUntil(self.registration.showNotification(m.title||'Tally',
    {body:m.body||'',data:{url:m.url||'/'},icon:'/icon-192.png',badge:'/icon-192.png',tag:m.tag}));
});
self.addEventListener('notificationclick',e=>{
  e.notification.close();
  const url=new URL(e.notification.data?.url||'/',self.location.origin).href;
  e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(ws=>{
    const w=ws.find(w=>new URL(w.url).origin===self.location.origin);
    if(!w)return clients.openWindow(url);
    // the page sets location itself (hash routing; WindowClient.navigate needs a controlled client and is patchy on iOS)
    w.postMessage({open:url});
    return w.focus();
  }));
});
