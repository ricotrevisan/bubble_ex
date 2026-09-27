# Replay kit: owner checklist

The Bubble replay driver (`BubbleEx.Verify.Replay`, WTF-384) records how
your Bubble app really behaves, so the migrated app can be compared with it.
It never runs against your live app or the shared `test` version. It runs
only on a child branch whose name starts with `wtfreplay`, and only after
this kit is in place (decisions D1 and D3 on WTF-358). Allow about
20 minutes.

The harness checks the items marked *(preflight)* before it writes
anything. Items marked *(you confirm)* can't be read through the API, so
you confirm them.

## 1. Create the replay branch

- [ ] In the editor, create a new branch off `test` named exactly
      `wtfreplay` (or `wtfreplay-<something>`: lowercase letters, digits,
      `-`, `_`). Never add the kit to `test` or live, and never merge the
      replay branch into `test`: Data API exposure settings travel with a
      merge.
- [ ] Note the branch's **ID**. Bubble serves a child branch at
      `/version-<branch ID>/` (a short ID such as `4k2xq`, shown next to
      the branch name in the branch list), not at its name. Give the
      harness both, with the marker nonce of step 3:
      `Target.new(app, "wtfreplay", token, branch_id: "4k2xq", marker_nonce: nonce)`.
      The driver checks the name, builds every URL from the ID, and never
      looks the ID up itself; `live` and `test` are refused, and an ID
      needs at least one letter and one digit. The marker workflow
      (step 3) proves the ID is the replay branch's.
- [ ] Check the host. By default the driver calls
      `https://<app>.bubbleapps.io/version-<branch ID>/`. If the app has a
      custom domain, `bubbleapps.io` redirects to it and the driver, which
      follows no redirects, stops. Then confirm the domain the branch is
      served from and pass it: `host: "app.example.com"`. The driver
      accepts only a bare DNS name, calls it over HTTPS, re-checks the
      exact host on every request and still builds only
      `/version-<branch ID>/api/1.1/` URLs under it.
- [ ] Some Bubble plans limit the number of branches. If creating the
      branch is refused, or it is created but not accessible, free a slot
      first; don't retry under another name.
- [ ] *(you confirm)* Branches share the **development database** with
      `test`. The driver creates records there and deletes only the ones it
      created (the seed ledger). If you keep real people's data in
      development, use a copy of the app instead.

## 2. Expose the Data API for the types under test *(preflight)*

**Exposing a type on a branch exposes the shared development database.**
The Data API answers anyone, with no token, as far as the privacy rules
allow. On a real app, a type whose rules let everyone see or search it
(an "everyone can view" rule, a condition that holds when both sides are
empty, or no rules at all) showed its development records, fields
included, to anonymous callers as soon as it was exposed on a branch. So:

- [ ] Before exposing a type, check its privacy rules: expose only types
      whose rules show a logged-out visitor nothing. Leave every other type
      unexposed and record it as "needs a decision".
- [ ] Check the **database triggers** of every type the seed writes.
      Seeding creates, updates and deletes records through the Data API,
      and Bubble runs the app's "a thing is modified" backend workflows
      for those changes, like any other change: they can call external
      services (analytics, billing, integrations) and create records the
      ledger does not know. The driver calls no app workflow itself, but
      it cannot stop these. Prefer types without triggers, or check that
      no trigger condition holds for the seed's records.
- [ ] Settings → API → enable **Data API** and tick only those types.
      The preflight runs two checks on each type under test:
      - a search that matches no records (`_id in [0x0]`, as admin) needs
        HTTP 200 (the type is exposed);
      - the **anonymous exposure probe**: up to 200 records (pages of
        100) as a logged-out caller, keeping only field names and counts.
        It fails closed:
        - any field beyond `_id`, `Created Date` and `Modified Date`:
          `:exposed`, with the field names. Untick that type at once;
        - records with only IDs and dates: Bubble leaves empty fields out,
          so this passes only when `/meta` lists no other field for the
          type, or the type is **proven hidden** (`anonymous_proof:`, e.g.
          from `Kit.anonymous_proof/1` on the app's Model: every rule,
          `everyone` included, grants no field and no search). Otherwise
          `:may_leak`;
        - no record at all: nothing shows the rules hide the fields (they
          may open no record yet), so `:unproven`, unless the type is
          proven hidden or you accept it with `allow_unproven:` (reported
          as a warning).
- [ ] **User.** The driver signs personas up and can delete them (and
      find a sign-up whose answer was lost) only through the `User` Data
      API. A seed with users therefore needs `User` exposed and passing
      the anonymous probe (`persona_cleanup` check). If `User` can't be
      exposed safely, record logged-out only: a seed without users.
      The exceptional owner acceptance below is the only way an unsafe
      User exposure can permit persona cleanup.
### Exceptional mm-137 owner acceptance (not the default)

**Only if the owner expressly accepts development emails/JWT exposure:**
The `mm-137` app's `wtfreplay` branch (ID `33kpg`) on
`beta.mocharymethod.com` may use an explicit, expiring
`BubbleEx.Verify.Replay.ExposureWaiver` for selected type descriptors.
This is not a privacy fix: anonymous visitors may read development data.
Do not enable it for another app, branch, ID, host or type; never merge
this replay branch into test/live. Revoke exposure after recording.

Construct `%ExposureWaiver{owner_accepted: true, expires_at: expiry,
types: ["user", ...]}` and pass `exposure_waiver: waiver` to **both**
`Recorder.plan/4` and `Recorder.record/4`. `expiry` is a UTC `DateTime`
after now but no more than seven days away. Use exact type descriptors
(for example `"user"`, `"custom.task"`), not Data API paths; unknown or
unrequested descriptors, invalid scope, absent acceptance and expired
waivers fail before any write. Include `"user"` explicitly if personas
need cleanup; accepting another type does **not** accept User. Only
`:exposed` and `:may_leak` probes for named types can be accepted. The
anonymous probe still runs: its actual status, counts and field names
remain in `report.preflight.checks`, with conspicuous warnings in
`report.preflight.warnings`. Never treat accepted exposure as safe. The
waiver is bound into the reviewed dry-run hash. Tokenless target
verification and call/cleanup budgets are unchanged.

- [ ] *(you confirm)* **Don't change any privacy rule.** The recording is
      only worth something if the branch's rules match the parent's. Don't
      tick "ignore privacy rules" anywhere.

## 3. Add the marker, sign-up and login API workflows *(preflight)*

Settings → API → enable **Workflow API**. Then, in Backend workflows:

- [ ] `wtf_replay_marker`: exposed as a public API workflow, **with** "This
      workflow can be run without authentication" checked. No parameters.
      - Step 1: **Return data from API**: `branch` = the branch's name
        typed as text (`wtfreplay`), `nonce` = a random value you choose
        (16 to 128 letters, digits, `-`, `_`), typed as text. Give the
        same value to the harness as `marker_nonce:`.
      - It returns nothing else and exists only on the replay branch.
        Before any request carries a token, the driver checks without a
        token that the host answers Bubble's `/meta` and that this
        workflow, at `/version-<branch ID>/`, returns exactly that branch
        name and nonce. A mistyped host or branch ID fails there, and the
        admin token is never sent to it.
- [ ] Only for a seed with users (personas): `wtf_replay_signup` and
      `wtf_replay_login` below. A seed without users needs only the
      marker.
- [ ] `wtf_replay_signup`: exposed as a public API workflow. Leave "This
      workflow can be run without authentication" **unchecked**, so only
      the admin token can call it.
      - Parameters: `email` (text), `password` (text).
      - Step 1: **Sign the user up** with those parameters.
      - Step 2: **Return data from API**: `user_id` = Result of step 1's
        unique id.
- [ ] `wtf_replay_login`: same exposure, same parameters.
      - Step 1: **Log the user in** with `email` and `password`.
      - Step 2: **Return data from API**: `token`, `user_id` and `expires`
        from the login step.
- [ ] The preflight reads `/version-<branch ID>/api/1.1/meta` (as admin,
      after the marker check) and, for a seed with users, needs the
      sign-up and login names among the exposed workflows.

The driver signs personas up with emails like
`alice+<run>@replay.wtf.invalid` and random passwords that are never stored.
No email reaches a real person.

## 4. Create a dedicated replay admin token *(you confirm)*

- [ ] Settings → API → **Generate a new API token** named
      `wtf-replay`. Use it only for replay and revoke it after cutover.
      The token works across the whole app, which is why the harness
      enforces the branch in code.
- [ ] Give it to the harness through the environment (for example
      `WTF_REPLAY_ADMIN_TOKEN`). Never commit it. The driver keeps it in
      memory, redacts it from inspection and telemetry, and refuses to
      write any output that contains it (the credential scan).

## What Bubble does (observed on a real branch, WTF-385)

- `/meta` answers without a token on a branch: `get` lists the exposed
  types by Data API path (`00.thing`, `🎙️msgs`: the display name
  lowercased without spaces), `post` lists workflow objects named by
  `endpoint`, `types` gives each exposed or referenced type's fields as
  `{id, display, type}` objects (built-in fields included, `_id` as
  `unique ID`, deleted fields left out) and `app_data.use_captions_for_get`
  says whether the Data API keys fields by display name.
- Option-set values are written and read by their **display text**; a
  create with the stored key (`db_value`) is refused (400 `INVALID_DATA`).
- A create stores the fields' defaults; `PATCH` with a field set to `null`
  clears it (204, and the field is gone when read back).
- A Data API create with the admin token sets `Created By`.
- A record the privacy rules hide from the caller answers `GET` by ID with
  200 and only `_id`, not 404; a search leaves it out. The driver records
  that as not visible. This rests on one observation (logged-out callers,
  rules that grant nothing): a rule granting search or some fields without
  "view all" may produce the same ID-only answer, so "not visible" may
  merge "hidden" with "findable but no field visible" (unverified; listed
  on WTF-358).
- A branch's Data API setting and type list are its own: exposing or
  hiding types on the replay branch leaves `test` unchanged.

## 5. Dry run, then record

1. `Replay.Recorder.plan/4` validates the scenarios against the seed and
   the target (app, branch name, branch ID, host) and estimates the number
   of calls. It makes no requests.
   Review the plan. The driver calls no workflow of your app, only the
   kit's (database triggers still run: see "Check the database triggers"
   in section 2 of this checklist): scenarios that call app workflows are refused until they can
   be classified as replay-safe (V7).
2. `Replay.Recorder.record/4` needs the plan's `sha256` and a
   `:ledger_dir`. It runs the preflight (refusing the run if the kit is
   incomplete, a type is exposed to logged-out callers, or personas can't
   be cleaned up), then records every scenario twice from a fresh seed
   each time. A seed field that must be empty (`null`, e.g. a field with
   a default that a scenario needs empty) is cleared after the record is
   created, since Bubble stores the default on creation; the clear is
   journaled, and a clear Bubble refuses makes the scenarios that depend
   on that record incomplete. Before each create it writes an intent to
   the run's journal (`<ledger_dir>/<run id>.jsonl`, fsynced). It masks
   what differs between the two runs, deletes the records of each run
   (even after a crash) and writes recordings under
   `.wtf/verification/recordings/`.
3. Check `report.leftovers`. It lists what cleanup couldn't delete (type
   and, when known, Bubble ID), including creates whose answer was lost.
   The driver never searches for those, so delete them by hand.
4. If the process died mid-run, run `Replay.Cleanup.resume/2` on the run's
   journal. It deletes only the IDs the journal confirms, and finds
   unconfirmed sign-ups by their exact per-run email.
