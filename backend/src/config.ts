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
}
export function supabaseHeaders(key: string): Record<string,string> {
  // Modern sb_secret keys are API keys, not JWT bearer tokens.
  return key.startsWith('eyJ') ? {apikey:key,Authorization:`Bearer ${key}`} : {apikey:key};
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
  };
}
