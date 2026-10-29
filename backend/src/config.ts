export interface Config {
  host: string;
  port: number;
  publicURL: string;
  devAuth: boolean;
  devEmail: string;
  devPassword: string;
  ownerEmail: string;
  supabaseURL?: string;
  anonKey?: string;
  serviceKey?: string;
  bucket: string;
  dataDirectory: string;
  /** OpenRouter key for AI reading context. Without it the feature is off for everyone. */
  openRouterKey?: string;
  contextModel: string;
  /** Generations an owner asks for per UTC day (Generate or Regenerate). Cached results don't count. */
  contextDailyLimit: number;
  /** Generations made in the background, after saves and for the backfill, per account per UTC day. */
  contextBackgroundDailyLimit: number;
  /** Output-token ceiling per call, reasoning included. Only generated tokens are billed. */
  contextMaxTokens: number;
}
export function supabaseHeaders(key: string): Record<string, string> {
  // Modern sb_secret keys are API keys, not JWT bearer tokens.
  return key.startsWith("eyJ")
    ? { apikey: key, Authorization: `Bearer ${key}` }
    : { apikey: key };
}
/** Accept the provider's URI template and a separately entered runtime password. */
export function databaseConnection(env = process.env): string | undefined {
  const template = env.DATABASE_URL;
  if (!template) return undefined;
  if (!template.includes("[YOUR-PASSWORD]")) return template;
  if (!env.DATABASE_PASSWORD)
    throw new Error("Set DATABASE_PASSWORD in runtime secrets.");
  return template.replace(
    "[YOUR-PASSWORD]",
    encodeURIComponent(env.DATABASE_PASSWORD),
  );
}
export function configuration(env = process.env): Config {
  const host = env.HOST ?? "127.0.0.1";
  const publicURL = (env.PUBLIC_URL ?? "http://127.0.0.1:8787").replace(
    /\/$/,
    "",
  );
  const devAuth = env.DEV_AUTH === "true";
  if (
    devAuth &&
    (env.NODE_ENV === "production" ||
      !["127.0.0.1", "localhost", "::1"].includes(host))
  )
    throw new Error(
      "Development authentication is restricted to loopback development servers.",
    );
  if (devAuth && !env.DEV_PASSWORD)
    throw new Error("Set DEV_PASSWORD for local development.");
  if (
    !devAuth &&
    (!env.OWNER_EMAIL ||
      !env.SUPABASE_URL ||
      !env.SUPABASE_ANON_KEY ||
      !env.SUPABASE_SERVICE_KEY ||
      !publicURL.startsWith("https://") ||
      !env.DATABASE_URL)
  )
    throw new Error(
      "Production requires owner email, Supabase credentials, PostgreSQL and an HTTPS PUBLIC_URL.",
    );
  return {
    host,
    port: Number(env.PORT ?? 8787),
    publicURL,
    devAuth,
    devEmail: env.DEV_EMAIL ?? "reader@example.test",
    devPassword: env.DEV_PASSWORD ?? "",
    ownerEmail: (env.OWNER_EMAIL ?? "").toLowerCase(),
    supabaseURL: env.SUPABASE_URL,
    anonKey: env.SUPABASE_ANON_KEY,
    serviceKey: env.SUPABASE_SERVICE_KEY,
    bucket: env.STORAGE_BUCKET ?? "articles",
    dataDirectory: env.DATA_DIRECTORY ?? ".local",
    openRouterKey: env.OPENROUTER_API_KEY || undefined,
    contextModel: env.READING_CONTEXT_MODEL || "google/gemini-3.8-flash",
    contextDailyLimit: dailyLimit(env.READING_CONTEXT_DAILY_LIMIT, 30, "READING_CONTEXT_DAILY_LIMIT"),
    contextBackgroundDailyLimit: dailyLimit(
      env.READING_CONTEXT_BACKGROUND_DAILY_LIMIT,
      300,
      "READING_CONTEXT_BACKGROUND_DAILY_LIMIT",
    ),
    contextMaxTokens: maxTokens(env.READING_CONTEXT_MAX_TOKENS),
  };
}

function dailyLimit(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined || value === "") return fallback;
  const limit = Number(value);
  if (!Number.isInteger(limit) || limit < 0 || limit > 1000)
    throw new Error(`${name} must be a whole number from 0 to 1000.`);
  return limit;
}

function maxTokens(value: string | undefined): number {
  if (value === undefined || value === "") return 16_000;
  const tokens = Number(value);
  if (!Number.isInteger(tokens) || tokens < 1_000 || tokens > 64_000)
    throw new Error("READING_CONTEXT_MAX_TOKENS must be a whole number from 1000 to 64000.");
  return tokens;
}
