import { test } from "node:test";
import assert from "node:assert/strict";
import { databaseConnection } from "../src/config.js";
test("database URI templates safely encode reserved characters in runtime passwords", () => {
  const password = "synthetic:@/#?[]% test";
  const result = databaseConnection({
    DATABASE_URL:
      "postgresql://postgres.project:[YOUR-PASSWORD]@database.example:5432/postgres?sslmode=verify-full",
    DATABASE_PASSWORD: password,
  });
  const url = new URL(result!);
  assert.equal(decodeURIComponent(url.password), password);
  assert.equal(url.hostname, "database.example");
  assert.equal(url.searchParams.get("sslmode"), "verify-full");
});
test("missing runtime password is reported without leaking the connection URI", () => {
  assert.throws(
    () =>
      databaseConnection({
        DATABASE_URL:
          "postgresql://postgres:[YOUR-PASSWORD]@database.example/postgres",
      }),
    /^Error: Set DATABASE_PASSWORD in runtime secrets\.$/,
  );
  assert.equal(databaseConnection({}), undefined);
});
test("ordinary connection URIs remain compatible", () => {
  const url = "postgresql://postgres:test@localhost/postgres";
  assert.equal(databaseConnection({ DATABASE_URL: url }), url);
});
