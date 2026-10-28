import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { configuration, databaseConnection } from "./config.js";
import { migrate, openDatabase } from "./db.js";
import { storage } from "./storage.js";
import { Service } from "./service.js";
import { buildServer } from "./server.js";
import { ImportWorker } from "./worker.js";
import { openRouterModel } from "./reading-context.js";

const config = configuration();
await mkdir(config.dataDirectory, { recursive: true });
const db = await openDatabase(
  databaseConnection(),
  join(config.dataDirectory, "database"),
);
await migrate(db);
const service = new Service(
  db,
  config,
  storage(config),
  undefined,
  config.openRouterKey
    ? openRouterModel(config.openRouterKey, config.contextModel)
    : undefined,
);
const worker = new ImportWorker(
  {
    runOne: () => service.runOne(),
    cleanup: async () => {
      await db.query("DELETE FROM download_grants WHERE expires_at<now()");
      await db.query("DELETE FROM oauth_codes WHERE expires_at<now()");
      await db.query("DELETE FROM credentials WHERE expires_at<now()");
      await service.purgeTrash();
      // A connection whose last credential expired keeps no opt-in grants.
      await db.query(
        "DELETE FROM connection_grants g WHERE NOT EXISTS(SELECT 1 FROM credentials c WHERE c.owner_id=g.owner_id AND c.connection_id=g.connection_id)",
      );
    },
  },
  {},
  () => console.error("Worker cycle failed; durable jobs will retry."),
);
service.onQueued = () => worker.wake();
// Reading context for newly prepared articles and the backfill, one at a time. It wakes when an
// import finishes, then paces itself; an idle check every 10 minutes picks up retries.
const contextWorker = new ImportWorker(
  { runOne: () => service.runContextJob(), cleanup: async () => {} },
  { idleMs: 600_000, busyMs: 5_000, retryMs: 60_000, batchSize: 1, cleanupMs: Number.MAX_SAFE_INTEGER },
  () => console.error("Reading-context cycle failed; it will retry."),
);
service.onPrepared = () => contextWorker.wake();
const app = await buildServer(service);
let stopping = false;
await app.listen({ host: config.host, port: config.port });
worker.start();
if (config.openRouterKey) contextWorker.start();
console.log(
  `PageStash backend listening on ${config.host}:${config.port}`,
);
for (const signal of ["SIGINT", "SIGTERM"] as const)
  process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    await app.close();
    // Platform termination can interrupt an import; its durable lease permits recovery.
    await Promise.race([
      Promise.all([worker.stop(), contextWorker.stop()]),
      new Promise((resolve) => setTimeout(resolve, 15_000)),
    ]);
    await db.close();
    process.exit(0);
  });
