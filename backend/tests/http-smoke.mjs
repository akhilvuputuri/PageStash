import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const directory=await mkdtemp(join(tmpdir(),'offline-reader-smoke-'));
const password=randomUUID();
const origin='http://127.0.0.1:8789';
const child=spawn(process.execPath,['dist/main.js'],{env:{...process.env,NODE_ENV:'development',HOST:'127.0.0.1',PORT:'8789',PUBLIC_URL:origin,DEV_AUTH:'true',DEV_EMAIL:'reader@example.test',DEV_PASSWORD:password,DATA_DIRECTORY:directory,DATABASE_URL:''},stdio:['ignore','ignore','pipe']});
let childError='';child.stderr.on('data',chunk=>{childError+=chunk.toString()});
async function api(path,body,token,method=body?'POST':'GET'){
 const response=await fetch(origin+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:body?JSON.stringify(body):undefined});
 assert.ok(response.ok,`HTTP ${response.status} for ${path.split('/').slice(0,3).join('/')}`);return response.json();
}
try{
 let healthy=false;
 for(let i=0;i<100;i++){try{healthy=(await fetch(origin+'/health')).ok;if(healthy)break;}catch{}await new Promise(r=>setTimeout(r,100));}
 assert.ok(healthy,'Server did not start: '+childError);
 const session=await api('/v1/session',{email:'reader@example.test',password});
 const credential=await api('/v1/connections',{label:'Smoke assistant'},session.token);
 const saved=await api('/v1/saves/document',{title:'Smoke reading brief',markdown:'# Prepared brief\nThis text will be read offline.',sources:['https://example.com/'],idempotency_key:randomUUID()},credential.token);
 let status;
 for(let i=0;i<40;i++){status=await api('/v1/saves/'+saved.submission_id,undefined,credential.token);if(status.status==='ready')break;await new Promise(r=>setTimeout(r,250));}
 assert.equal(status.status,'ready');
 const page=await api('/v1/library?cursor=0',undefined,session.token);
 const item=page.items.find(i=>i.id===saved.submission_id);assert.ok(item);assert.equal(item.assets.length,1);
 const asset=item.assets[0];const response=await fetch(asset.url);assert.ok(response.ok);const bytes=Buffer.from(await response.arrayBuffer());
 assert.equal(bytes.length,asset.size);assert.equal(createHash('sha256').update(bytes).digest('hex'),asset.sha256);assert.match(bytes.toString(),/Agent-created brief/);
 const denied=await fetch(origin+'/v1/library',{headers:{Authorization:`Bearer ${credential.token}`}});assert.equal(denied.status,403);
 await api('/v1/items/'+item.id,{progress:0.6,collections:['Smoke']},session.token,'PATCH');
 const updated=await api('/v1/library?cursor='+page.cursor,undefined,session.token);assert.equal(updated.items[0].progress,0.6);
 console.log('HTTP smoke passed: login, credential, async brief, verified download, edit sync, restricted agent.');
}finally{
 child.kill('SIGTERM');await new Promise(resolve=>{if(child.exitCode!==null)resolve();else child.once('exit',resolve)});await rm(directory,{recursive:true,force:true});
}
