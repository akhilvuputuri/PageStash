/**
 * Child-process entry for one extraction, forked by extract-sandbox.ts with a heap limit, a minimal
 * environment and no stdout or stderr. Protocol over the IPC channel: the child sends
 * `{ ready: true }` once its modules have loaded, receives one SandboxRequest, sends one SandboxReply
 * and exits. It never fetches anything and holds no credentials.
 */
import { failureReply, runRequest, tooComplex } from "./extract-dom.js";
import { REPLY_LIMIT, type SandboxRequest } from "./extract-sandbox.js";

// The parent closing the channel (it exited, crashed or gave up) ends this process too.
process.on("disconnect", () => process.exit(0));
process.once("message", async (request: SandboxRequest) => {
  // Backstop in case the parent's own deadline never fires.
  setTimeout(() => process.exit(70), request.deadlineMs + 5_000).unref();
  let reply = await runRequest(request);
  // Bounds what the parent has to receive and parse.
  if (JSON.stringify(reply).length > REPLY_LIMIT) reply = failureReply(tooComplex());
  process.send!(reply, () => process.exit(0));
});
process.send!({ ready: true });
