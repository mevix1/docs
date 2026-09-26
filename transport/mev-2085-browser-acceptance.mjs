import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'

const url = process.env.TARGET_URL || 'http://127.0.0.1:4173/'
const out = process.env.EVIDENCE_DIR || '/mnt/data/mev2085-evidence/browser'
mkdirSync(out, { recursive: true })
const chromePath = process.env.CHROME_PATH || spawnSync('bash',['-lc','command -v chromium || command -v google-chrome || command -v chromium-browser'],{encoding:'utf8'}).stdout.trim()
if (!chromePath) throw new Error('Chromium not found')
const profile = mkdtempSync(path.join(tmpdir(),'mev2085-chrome-'))
const chrome = spawn(chromePath,[
  '--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage',
  '--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'
],{stdio:['ignore','ignore','pipe']})
let chromeErr=''; chrome.stderr.on('data',d=>chromeErr+=d)

async function waitFile(p, ms=15000){const s=Date.now();while(Date.now()-s<ms){try{return readFileSync(p,'utf8')}catch{await sleep(100)}}throw new Error('timeout '+p)}
class CDP{
  constructor(ws){this.wsUrl=ws;this.id=1;this.pending=new Map();this.handlers=new Map()}
  async open(){this.ws=new WebSocket(this.wsUrl);await new Promise((res,rej)=>{this.ws.addEventListener('open',res,{once:true});this.ws.addEventListener('error',rej,{once:true})});this.ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id){const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);m.error?p.reject(new Error(JSON.stringify(m.error))):p.resolve(m.result||{})}else for(const h of this.handlers.get(m.method)||[])h(m.params||{})})}
  send(method,params={}){const id=this.id++;return new Promise((resolve,reject)=>{this.pending.set(id,{resolve,reject});this.ws.send(JSON.stringify({id,method,params}))})}
  on(method,h){const a=this.handlers.get(method)||[];a.push(h);this.handlers.set(method,a)}
  close(){this.ws?.close()}
}
const cases=[], pageErrors=[], consoleErrors=[], failed=[], requests=[]
const pass=(name,detail=true)=>cases.push({name,status:'PASS',detail})
const check=(value,name,detail='')=>{if(!value)throw new Error(name+(detail?': '+JSON.stringify(detail):''));pass(name,detail||true)}
let cdp
try{
  const [port]= (await waitFile(path.join(profile,'DevToolsActivePort'))).trim().split(/\r?\n/)
  const target=await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`,{method:'PUT'}).then(async r=>{if(!r.ok)throw new Error('target '+r.status);return r.json()})
  cdp=new CDP(target.webSocketDebuggerUrl);await cdp.open()
  cdp.on('Runtime.exceptionThrown',p=>pageErrors.push(p.exceptionDetails?.text||'exception'))
  cdp.on('Log.entryAdded',p=>{if(p.entry?.level==='error')consoleErrors.push(p.entry.text)})
  cdp.on('Network.loadingFailed',p=>failed.push(p.errorText))
  cdp.on('Network.requestWillBeSent',p=>requests.push(p.request.url))
  await Promise.all(['Page.enable','Runtime.enable','Log.enable','Network.enable'].map(m=>cdp.send(m)))
  const evaljs=async expression=>{const r=await cdp.send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(r.exceptionDetails.text||'eval');return r.result?.value}
  const wait=async(expr,ms=15000)=>{const s=Date.now();while(Date.now()-s<ms){if(await evaljs(expr))return;await sleep(100)}throw new Error('wait '+expr)}
  const key=async(key,code,vk)=>{const down={type:'keyDown',key,code,windowsVirtualKeyCode:vk,nativeVirtualKeyCode:vk};if(key==='Enter'){down.text='\r';down.unmodifiedText='\r'}else if(key===' '){down.text=' ';down.unmodifiedText=' '}await cdp.send('Input.dispatchKeyEvent',down);await sleep(80);await cdp.send('Input.dispatchKeyEvent',{type:'keyUp',key,code,windowsVirtualKeyCode:vk,nativeVirtualKeyCode:vk});await sleep(180)}
  const button=t=>`Array.from(document.querySelectorAll('button')).find(n=>n.textContent.trim()===${JSON.stringify(t)})`
  const summary=t=>`Array.from(document.querySelectorAll('summary')).find(n=>n.textContent.trim()===${JSON.stringify(t)})`

  await cdp.send('Emulation.setDeviceMetricsOverride',{width:1280,height:900,deviceScaleFactor:1,mobile:false})
  await cdp.send('Page.navigate',{url});await wait("document.readyState==='complete'&&!!document.querySelector('h1')");await sleep(400)
  const initial=await evaljs(`(()=>({heading:document.querySelector('h1')?.textContent.trim(),body:document.body.innerText,diag:document.querySelector('.consumer-diagnostics')?.open,tech:document.querySelector('.consumer-technical')?.open,primary:${button('Проверить настройки')}?.getBoundingClientRect().top,diagTop:document.querySelector('.consumer-diagnostics')?.getBoundingClientRect().top,sw:document.documentElement.scrollWidth,iw:innerWidth}))()`)
  check(initial.heading==='Настройки ресурсов','plain task heading',initial.heading)
  check(!/Private package|MEV-\d+|Переключить pending|Переключить ошибку/i.test(initial.body),'no internal jargon on primary screen')
  check(initial.diag===false&&initial.tech===false,'optional disclosures closed by default')
  check(initial.primary<initial.diagTop,'primary flow precedes diagnostics')
  check(initial.sw<=initial.iw,'wide no horizontal overflow',initial)

  const before=await evaljs("document.querySelector('[role=checkbox]')?.getAttribute('aria-checked')")
  await evaljs("document.querySelector('[role=checkbox]').focus()");await key(' ','Space',32)
  const after=await evaljs("document.querySelector('[role=checkbox]')?.getAttribute('aria-checked')")
  check(before!==after,'checkbox works by keyboard',`${before}->${after}`)

  check((await evaljs("Array.from(document.querySelectorAll('[role=radio]')).filter(n=>n.getAttribute('aria-disabled')!=='true').length"))>=2,'enabled resource options present')
  await evaljs("Array.from(document.querySelectorAll('[role=radio]')).find(n=>n.getAttribute('aria-disabled')!=='true').focus()");await key('ArrowDown','ArrowDown',40)
  await wait("document.querySelector('.selection-summary')?.textContent.includes('Общая библиотека команды')");pass('radio changes by ArrowDown')

  await evaljs(`${button('Проверить настройки')}.focus()`);await key('Enter','Enter',13)
  await wait("document.querySelector('[role=status]')?.textContent.includes('Настройки проверены локально')");pass('primary action reports local success')

  await evaljs(`${summary('Проверить дополнительные состояния')}.focus()`);await key('Enter','Enter',13)
  check(await evaljs("document.querySelector('.consumer-diagnostics').open")===true,'diagnostics open by keyboard')
  await evaljs(`${button('Удалить выбранный вариант')}.focus()`);await key('Enter','Enter',13)
  await evaljs(`${button('Проверить настройки')}.focus()`);await key('Enter','Enter',13)
  await wait("document.querySelector('[role=status]')?.textContent.includes('Не удалось проверить настройки')");pass('missing resource gives recoverable error')

  await evaljs(`${button('Сбросить изменения')}.focus()`);await key('Enter','Enter',13)
  await wait("document.querySelector('.selection-summary')?.textContent.includes('Документы текущего проекта')")
  check(await evaljs("document.querySelector('[role=status]')?.textContent.includes('Изменения ещё не проверены')")===true,'reset restores initial state')

  await evaljs(`${summary('О комплекте и границах')}.focus()`);await key('Enter','Enter',13)
  check(await evaljs("document.querySelector('.consumer-technical').open")===true,'technical details open by keyboard')
  check(await evaljs("document.querySelector('.consumer-technical').innerText.includes('Серверное сохранение')")===true,'technical boundary available on demand')

  await cdp.send('Emulation.setDeviceMetricsOverride',{width:390,height:900,deviceScaleFactor:1,mobile:false});await sleep(350)
  const narrow=await evaljs(`(()=>({sw:document.documentElement.scrollWidth,iw:innerWidth,clipped:Array.from(document.querySelectorAll('button,summary,[role=radio],[role=checkbox],[role=switch]')).filter(n=>{const r=n.getBoundingClientRect();return r.left<-.5||r.right>innerWidth+.5}).map(n=>n.textContent?.trim()||n.getAttribute('role'))}))()`)
  check(narrow.sw<=narrow.iw,'390px no horizontal overflow',narrow)
  check(narrow.clipped.length===0,'390px interactive controls contained',narrow.clipped)
  const shot=await cdp.send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});writeFileSync(path.join(out,'consumer-390.png'),Buffer.from(shot.data,'base64'))
  const version=await cdp.send('Browser.getVersion')
  const allowedHost=new URL(url).hostname;const external=requests.filter(u=>{try{const p=new URL(u);return p.hostname!==allowedHost&&p.protocol!=='data:'}catch{return true}})
  check(pageErrors.length===0,'no page exceptions',pageErrors);check(consoleErrors.length===0,'no console errors',consoleErrors);check(failed.length===0,'no failed requests',failed);check(external.length===0,'no external requests',external)
  const result={status:'PASS_MEV_2085_CONSUMER_BROWSER',url,browser:version.product,cases,pageErrors,consoleErrors,failedRequests:failed,externalRequests:external,boundaries:['local-only action','no backend persistence','not live ChatGPT','not screen-reader/IME certification','not physical device/mobile certification','not public registry release']}
  writeFileSync(path.join(out,'browser-result.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result))
}catch(e){const result={status:'FAIL_MEV_2085_CONSUMER_BROWSER',error:String(e?.stack||e),cases,pageErrors,consoleErrors,failedRequests:failed,chromeStderr:chromeErr.slice(-4000)};writeFileSync(path.join(out,'browser-result.json'),JSON.stringify(result,null,2)+'\n');console.error(JSON.stringify(result));process.exitCode=1}
finally{cdp?.close();chrome.kill('SIGTERM');await sleep(200);rmSync(profile,{recursive:true,force:true})}
