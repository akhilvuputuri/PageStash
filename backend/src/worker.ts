export interface WorkerTasks {
  runOne(): Promise<boolean>;
  cleanup(): Promise<void>;
}
export interface WorkerOptions {
  idleMs: number;
  busyMs: number;
  retryMs: number;
  cleanupMs: number;
  batchSize: number;
}

/** Single import worker. Saves wake it immediately; idle polling only recovers durable jobs. */
export class ImportWorker {
  private timer?: ReturnType<typeof setTimeout>;
  private current?: Promise<void>;
  private stopped = true;
  private requested = false;
  private nextCleanup = 0;
  private readonly options: WorkerOptions;

  constructor(
    private readonly tasks: WorkerTasks,
    options: Partial<WorkerOptions> = {},
    private readonly onError = () => {},
  ) {
    this.options = {
      idleMs: 60_000,
      busyMs: 1500,
      retryMs: 15_000,
      cleanupMs: 3_600_000,
      batchSize: 3,
      ...options,
    };
  }
  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.schedule(0);
  }
  wake() {
    if (this.stopped) return;
    this.requested = true;
    if (!this.current) this.schedule(0);
  }
  async stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    await this.current;
  }
  private schedule(delay: number) {
    if (this.stopped) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      this.current = this.tick().finally(() => {
        this.current = undefined;
      });
    }, delay);
    this.timer.unref();
  }
  private async tick() {
    this.requested = false;
    let delay = this.options.idleMs;
    try {
      let processed = 0;
      while (
        !this.stopped &&
        processed < this.options.batchSize &&
        (await this.tasks.runOne())
      )
        processed++;
      if (processed === this.options.batchSize) delay = this.options.busyMs;
      if (!this.stopped && Date.now() >= this.nextCleanup) {
        await this.tasks.cleanup();
        this.nextCleanup = Date.now() + this.options.cleanupMs;
      }
    } catch {
      this.onError();
      delay = this.options.retryMs;
    }
    // A save can arrive while an empty claim query is in flight. Preserve that wake-up.
    this.schedule(this.requested ? 0 : delay);
  }
}
