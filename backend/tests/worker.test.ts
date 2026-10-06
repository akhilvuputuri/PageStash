import { test } from "node:test";
import assert from "node:assert/strict";
import { ImportWorker } from "../src/worker.js";

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(condition: () => boolean) {
  for (let i = 0; i < 100; i++) {
    if (condition()) return;
    await pause(5);
  }
  assert.fail("Worker did not make progress.");
}
test("a save wakes the idle worker without repeated cleanup or idle claims", async () => {
  let claims = 0,
    cleanups = 0,
    queued = 0,
    processed = 0;
  const worker = new ImportWorker(
    {
      runOne: async () => {
        claims++;
        if (queued) {
          queued--;
          processed++;
          return true;
        }
        return false;
      },
      cleanup: async () => {
        cleanups++;
      },
    },
    { idleMs: 60_000 },
  );
  worker.start();
  await until(() => cleanups === 1);
  await pause(20);
  assert.equal(claims, 1);
  queued = 1;
  worker.wake();
  await until(() => processed === 1);
  assert.equal(cleanups, 1);
  await worker.stop();
});
test("a save arriving during an empty claim is not lost and workers do not overlap", async () => {
  let release: (() => void) | undefined,
    queued = 0,
    processed = 0,
    active = 0,
    maxActive = 0,
    first = true;
  const worker = new ImportWorker(
    {
      runOne: async () => {
        active++;
        maxActive = Math.max(maxActive, active);
        try {
          if (first) {
            first = false;
            await new Promise<void>((resolve) => {
              release = resolve;
            });
            return false;
          }
          if (queued) {
            queued--;
            processed++;
            return true;
          }
          return false;
        } finally {
          active--;
        }
      },
      cleanup: async () => {},
    },
    { idleMs: 60_000 },
  );
  worker.start();
  await until(() => release !== undefined);
  queued = 1;
  worker.wake();
  worker.wake();
  release!();
  await until(() => processed === 1);
  assert.equal(maxActive, 1);
  await worker.stop();
});
test("database outages retry durable work and shutdown cancels future polls", async () => {
  let attempts = 0,
    errors = 0,
    processed = 0;
  const worker = new ImportWorker(
    {
      runOne: async () => {
        attempts++;
        if (attempts === 1) throw Error("Database unavailable");
        if (!processed) {
          processed++;
          return true;
        }
        return false;
      },
      cleanup: async () => {},
    },
    { retryMs: 5, idleMs: 60_000 },
    () => {
      errors++;
    },
  );
  worker.start();
  await until(() => processed === 1);
  assert.equal(errors, 1);
  await worker.stop();
  const stoppedAt = attempts;
  worker.wake();
  await pause(20);
  assert.equal(attempts, stoppedAt);
});
