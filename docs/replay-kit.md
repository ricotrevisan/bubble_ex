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
- [ ] **Only if the owner accepts anonymous exposure (not the default).**
      If a type the scenarios need, such as `User`, can't pass the
      anonymous probe, the owner may accept its exposure on the replay
      branch **for one run window**. Anonymous visitors can then read that
      type's development data, so this is not a privacy fix. It needs an
      owner exposure waiver (`BubbleEx.Verify.Replay.ExposureWaiver`),
      which the driver never writes:
      - **The file is the consent record, and nothing proves who wrote
        it.** Any process running as your user can write one, agents
        included. The driver checks that it is private and outside any
        repository, not who wrote it. Write it only **after** the owner's
        approval has been recorded (a message, a ticket comment), and
        quote that approval, with its date, in `approval_reference`.
      - The owner, or an operator acting on the owner's recorded
        approval, writes it by hand as a JSON file in a private directory
        outside any git checkout (the directory's real path is checked, so
        a symlink into a checkout is refused), for example
        `~/.local/share/wtf-v5/waivers/<name>.json`. The directory must be
        `0700`, the file `0600` with a single link (no hard link), both
        owned by the user running the driver. A file that changes while it
        is read is refused.
      - It names the exact `app`, `branch`, `branch_id` and `host` of the
        target and the exact type descriptors with their Data API paths
        (`"types": {"user": "user"}`), with no wildcard. `live` and `test`
        are refused. `issued_at` and `expires_at` are UTC (`Z`) and at most
        24 hours apart. It also has `approved_by` and an
        `approval_reference` that quotes the owner's approval and gives
        its date. See the module doc for the full format.
      - Load it with `ExposureWaiver.load_waiver(path)` and pass
        `exposure_waiver:` to both `plan/4` and `record/4`. The file is
        read again at every use: at `plan/4`, before the preflight, before
        each run and between scenarios. Editing or deleting the file
        revokes the waiver, and expiry has the same effect: the run stops
        and cleanup still runs.
      - It accepts only `:exposed` and `:may_leak` for the types it lists.
        The probe still runs, and its actual status, counts and field names
        stay in the report with a warning. `:unproven` and missing types
        are still refused.
      - The file's SHA-256 is in the dry-run hash, `report.exposure_waiver`
        and each run's ledger journal.
      - After the run, remove the exposure on the branch and delete the
        waiver. Never merge the replay branch into test or live.
      - Disable the app's database-trigger workflows **on the replay
        branch only** if the owner asks. The parent versions keep theirs.
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
      - No other step. With no "Return data from API" step, Bubble answers
        a workflow that logs a user in with `token`, `user_id` and
        `expires` itself (observed on a branch, WTF-385). Buildprint's
        BubbleScript exposes no result for the login step, so a return
        step can't read it anyway.
- [ ] If you edit the branch with Buildprint, set both workflows'
      authentication to `adminOnly`, and the marker's to `none`.
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
- A Data API create with the admin token sets `Created By` itself;
  naming a creator is refused.
- A record the privacy rules hide from the caller answers `GET` by ID with
  200 and only `_id`, not 404; a search leaves it out. The driver records
  that as not visible. This rests on one observation (logged-out callers,
  rules that grant nothing): a rule granting search or some fields without
  "view all" may produce the same ID-only answer, so "not visible" may
  merge "hidden" with "findable but no field visible". A later run
  observed that merge: an `everyone` rule granting search and two
  listed fields, both empty on the record, answered `GET` with `_id`
  only (the built-in dates weren't listed, so they were hidden too), and
  the search found the record. So "not visible" from an ID-only answer
  can mean "readable, but no granted field holds a value". Use a search
  op to tell the two apart.
- A branch's Data API setting and type list are its own: exposing or
  hiding types on the replay branch leaves `test` unchanged.
- **Creating a record as a persona needs "Create via API".** The
  seeder creates a record whose `Created By` is a seeded user with
  that user's token, so Bubble sets the creator. Bubble answered such a
  create with 401 on a type none of whose privacy rules grants "Create
  via API" (that app grants it nowhere). The same run's admin-token
  creates worked. The run then stops at seeding with
  `reason: :user_create_refused` and the type. That is a strong hint,
  not proof: an expired persona token gets the same answer. A refusal
  without Bubble's JSON (a firewall's page) is `:user_create_not_bubble`.
  An admin-token create can't stand in for it: Bubble refused a create
  that set `Created By` explicitly (400 `ERROR`, nothing stored). So a
  seed record whose creator is a persona can only be created where the
  type grants "Create via API". Changing privacy rules on the branch
  would make the recording worthless, so leave such records, and the
  scenarios that depend on them, out of the run.
- **An empty value on the user's side equals an empty record value.**
  A logged-out user, or a user without the value a condition reads,
  matches a record whose value is empty too: `Current User's team =
  This Thing's team` grants a logged-out user the records with no
  team (the calibration refuted the fail-safe reading, 14 ops
  agreeing and 69 not). The interpreter now predicts this; the generated
  policies deliberately keep denying (see step 6).
- **The `everyone` rule reaches every user** (the 2026-10-01 run,
  WTF-467). Its grants add to what the other rules grant, also for a
  user another rule matches; they are not limited to the users no other
  rule matches (0 of 19 dependent ops agreed with that reading). The
  compiler's guard on that reach (the record values the other rules read
  must be non-empty) has nothing to guard either (0 of 18).
- **A logged-out user is a temporary user**, not an empty one: it equals
  no record's user, so `This Thing's Creator = Current User` does not
  grant it a record with no creator (0 of 12 agreed with the empty
  reading).
- **An empty yes/no reads as no**: `x is no` holds on a record whose x
  is empty (0 of 5 agreed otherwise, after 0 of 2 on 2026-09-29).
- With these four flipped, the interpreter agrees with 1,354 of the
  run's 1,392 ops (97.3%); the generated policies keep the stricter
  reading of each, as intended differences (`BubbleEx.Verify.Difference`).
- The sign-up workflow's "Return data from API" of step 1's unique ID
  returns the new user's ID, and the login workflow above returns a
  working token (observed while seeding six personas).

## Editing the branch with Buildprint

- Ticking a type for the Data API changes that type's file, and
  `buildprint check` then re-validates the whole file, **including its
  unchanged privacy rules**. Buildprint refuses (BSP8020) a rule that
  grants search when its condition reads "This Thing's X's Y", and there
  is no way to suppress that. Such a type can't be exposed through
  Buildprint without editing the rule, which this checklist forbids.
  Leave such types out of the run: tick them in the editor only if you
  can also untick them there afterwards.
- Behind a custom domain, a firewall may answer some Data API paths
  itself: `/obj/fileupload` got an HTML 403, not Bubble's JSON.

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
   incomplete, a type is exposed to logged-out callers without an owner
   waiver, or personas can't be cleaned up), then records every scenario twice from a fresh seed
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

## 6. Compare with the interpreter and the generated app

- **Calibrate the interpreter.** `BubbleEx.Verify.Calibration.compare/4`
  compares the recordings with what the privacy interpreter predicts,
  per op and per assumption flag (the ops that depend on it, how many
  agree, and what flipping it would fix or break), with a suggested
  verdict. It compares as the Data API shows records
  (`BubbleEx.Verify.DataApi`): only the fields the record holds (empty
  fields are omitted), and a readable record with no field to show as
  the ID-only answer a hidden record gets. It counts those ambiguous
  answers, and how many the scenario's search resolved. It never changes
  a flag: flipping one is a code change to
  `BubbleEx.Verify.Interpreter.Assumptions`, with the counts recorded in
  its `evidence/0`. Flags with too few samples stay as they are; the
  privacy matrix adds witnesses for them, so the next run has more.
- **Refresh the export first.** Disagreements also come from privacy
  rules changed since the export the matrix was built from (68 of the
  first run's 154). Build the matrix from a fresh export before a run.
- **Stricter than Bubble by design.** Where Bubble grants access through
  an empty user-side value, the generated policies deny, by the owner's
  decision (`BubbleEx.Verify.Difference`). Verification reports each
  such case as a known, intended difference, never as a failure:
  `matrix.differences` (and `.wtf/verification/differences/`), the
  generated matrix tests (tagged `stricter_than_bubble`, expecting the
  stricter value), results with status `intended_difference`
  (`Result.intended_differences/1` lists them), and the structural
  report's `intended_differences`. A generated app that grants what
  Bubble grants there fails.
