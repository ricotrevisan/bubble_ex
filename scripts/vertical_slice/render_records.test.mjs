// node --test scripts/vertical_slice/render_records.test.mjs
// (run by test/scripts/vertical_slice_test.exs): render_records.js on a synthetic page object.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("./render_records.js", import.meta.url), "utf8");

// A fake Bubble page: its page item's db holds the client record cache.
const run = (locals, { user = "u1", pageItem = true } = {}) => {
  const db = { _locals: locals };
  const datasources = {
    current_page_item: () => (pageItem ? { db } : null),
    current_user: () => ({ raw: () => ({ _id: user }), db }),
  };
  const page = { bubble_data: { bubble_instance: { _p_context: { datasources } } } };
  const document = {
    querySelector: (s) => (s === ".bubble-element.Page" ? page : null),
    querySelectorAll: () => [page],
  };
  const out = vm.runInNewContext(source, { document, location: { pathname: "/demo", search: "?x=1" } });
  return JSON.parse(out);
};

test("captures each record's type and raw fields, keeps reference prefixes for the loader", () => {
  const cycle = {};
  cycle.self = cycle;
  const d = run({
    t1: { type: "custom.thing", raw: { _id: "t1", name_text: "A", owner_user: "1__LOOKUP__u1", _private: 1, deep: cycle } },
    r1: { type: "custom.role", raw: { name_text: "no _id on the client" } },
    junk: "not a record",
  });
  assert.equal(d.source, "bubble");
  assert.equal(d.path, "/demo");
  assert.equal(d.user_id, "u1");
  assert.deepEqual(Object.keys(d.records).sort(), ["r1", "t1"]);
  assert.equal(d.records.t1.type, "custom.thing");
  assert.equal(d.records.t1.raw.owner_user, "1__LOOKUP__u1");
  assert.equal(d.records.t1.raw._private, undefined);
  assert.equal(d.records.r1.raw._id, undefined);
});

test("a user's authentication keeps its email, confirmed status and provider names only", () => {
  const d = run({
    u1: {
      type: "user",
      raw: {
        _id: "u1",
        authentication: {
          email: { email: "a@example.test", email_confirmed: true, temp_password: "secret" },
          google: { email: "a@example.test", id: "g1" },
        },
      },
    },
    u2: { type: "user", raw: { _id: "u2", authentication: { email: "b@example.test" } } },
  });
  assert.deepEqual(d.records.u1.raw.authentication, {
    email: { email: "a@example.test", email_confirmed: true },
    google: {},
  });
  assert.deepEqual(d.records.u2.raw.authentication, { email: { email: "b@example.test" } });
  assert.ok(!JSON.stringify(d).includes("secret"));
});

test("falls back to the user's db, and says when there is no cache", () => {
  assert.equal(Object.keys(run({ a: { type: "user", raw: {} } }, { pageItem: false }).records).length, 1);
  assert.match(run(undefined).error, /no client record cache/);
});
