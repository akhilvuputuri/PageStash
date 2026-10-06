import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { configuration } from "./config.js";
import { migrate, openDatabase } from "./db.js";
import { storage } from "./storage.js";
import { Service } from "./service.js";
import { buildServer } from "./server.js";

const config = configuration();
await mkdir(config.dataDirectory, { recursive: true });
const db = await openDatabase(
  process.env.DATABASE_URL,
  join(config.dataDirectory, "database"),
);
await migrate(db);
const service = new Service(db, config, storage(config));
const app = await buildServer(service);
let running = false,
  stopping = false;
const timer = setInterval(async () => {
  if (running || stopping) return;
  running = true;
  try {
    for (
      let count = 0;
      count < 3 && !stopping && (await service.runOne());
      count++
    ) {}
    await db.query("DELETE FROM download_grants WHERE expires_at<now()");
    await db.query("DELETE FROM oauth_codes WHERE expires_at<now()");
    await db.query("DELETE FROM credentials WHERE expires_at<now()");
  } catch {
    console.error("Worker cycle failed; durable jobs will retry.");
  } finally {
    running = false;
  }
}, 1500);
await app.listen({ host: config.host, port: config.port });
console.log(
  `Offline Reader backend listening on ${config.host}:${config.port}`,
);
for (const signal of ["SIGINT", "SIGTERM"] as const)
  process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    await app.close();
    // Finish the current import within its bounded network time. Render shutdown policy must allow this.
    const deadline = Date.now() + 15_000;
    while (running && Date.now() < deadline)
      await new Promise((resolve) => setTimeout(resolve, 100));
    await db.close();
    process.exit(0);
  });
