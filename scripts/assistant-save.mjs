#!/usr/bin/env node
import {readFile} from 'node:fs/promises';
const [command,...args]=process.argv.slice(2);
const origin=process.env.READER_URL,token=process.env.READER_AGENT_TOKEN;
if(!origin?.startsWith('https://') || !token)throw new Error('Set HTTPS READER_URL and READER_AGENT_TOKEN in the assistant environment.');
let path,method='POST',payload;
if(command==='link' && args.length===2){path='/v1/saves/link';payload={url:args[0],idempotency_key:args[1]};}
else if(command==='document' && args.length>=3){path='/v1/saves/document';payload={markdown:await readFile(args[0],'utf8'),title:args[1],idempotency_key:args[2],sources:args.slice(3)};}
else if(command==='status' && /^[a-f0-9-]{36}$/i.test(args[0]??'')){path='/v1/saves/'+args[0];method='GET';}
else throw new Error('Usage: link URL REQUEST_ID | document FILE TITLE REQUEST_ID [SOURCE_URL...] | status UUID');
const response=await fetch(new URL(path,origin),{method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:payload?JSON.stringify(payload):undefined,signal:AbortSignal.timeout(30_000)});
const result=await response.json();if(!response.ok){console.error(JSON.stringify(result));process.exitCode=1;}else console.log(JSON.stringify(result));
