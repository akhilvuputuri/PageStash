import { mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { supabaseHeaders, type Config } from "./config.js";

export interface Storage {
  put(key: string, bytes: Buffer, mime: string): Promise<void>;
  get(key: string): Promise<Buffer>;
  remove(keys: string[]): Promise<void>;
  purgeOwner(owner: string): Promise<void>;
}
export function storage(config: Config): Storage {
  if (!config.devAuth) {
    const url = `${config.supabaseURL}/storage/v1/object/${config.bucket}`;
    const headers = supabaseHeaders(config.serviceKey!);
    return {
      async put(key, bytes, mime) {
        const r = await fetch(`${url}/${key}`, {
          method: "POST",
          headers: { ...headers, "Content-Type": mime, "x-upsert": "true" },
          body: new Uint8Array(bytes),
          signal: AbortSignal.timeout(30_000),
        });
        if (!r.ok) throw new Error("Private storage upload failed.");
      },
      async get(key) {
        const r = await fetch(`${url}/${key}`, {
          headers,
          signal: AbortSignal.timeout(30_000),
        });
        if (!r.ok) throw new Error("Private storage download failed.");
        return Buffer.from(await r.arrayBuffer());
      },
      async remove(keys) {
        if (!keys.length) return;
        const r = await fetch(url, {
          method: "DELETE",
          headers: { ...headers, "Content-Type": "application/json" },
          body: JSON.stringify({ prefixes: keys }),
          signal: AbortSignal.timeout(30_000),
        });
        if (!r.ok) throw new Error("Private storage deletion failed.");
      },
      async purgeOwner(owner) {
        const keys:string[]=[];
        async function list(prefix:string) {
          for(let offset=0;;offset+=1000) {
            const r=await fetch(`${config.supabaseURL}/storage/v1/object/list/${config.bucket}`,{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({prefix,limit:1000,offset}),signal:AbortSignal.timeout(30_000)});
            if(!r.ok)throw new Error('Private storage listing failed.');
            const objects=await r.json() as {name:string;id:string|null}[];
            for(const object of objects) {const key=`${prefix}/${object.name}`;if(object.id)keys.push(key);else await list(key);}
            if(objects.length<1000)break;
          }
        }
        await list(owner);
        for(let i=0;i<keys.length;i+=1000)await this.remove(keys.slice(i,i+1000));
      },
    };
  }
  const root = join(config.dataDirectory, "files");
  return {
    async put(key, bytes) {
      const path = join(root, key);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, bytes);
    },
    async get(key) {
      return readFile(join(root, key));
    },
    async remove(keys) {
      for (const key of keys) await rm(join(root, key), { force: true });
    },
    async purgeOwner(owner) {await rm(join(root,owner),{recursive:true,force:true});},
  };
}
