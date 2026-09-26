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
      harness both: `Target.new(app, "wtfreplay", token, branch_id: "4k2xq")`.
      The driver checks the name, builds every URL from the ID, and never
      looks the ID up itself; `live` and `test` are refused.
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
- [ ] Settings → API → enable **Data API** and tick only those types.
      The preflight runs two checks on each type under test:
      - a search that matches no records (`_id in [0x0]`, as admin) needs
        HTTP 200 (the type is exposed);
      - the **anonymous exposure probe**: one page (25 records) as a
        logged-out caller, keeping only field names and counts. If any
        field beyond `_id`, `Created Date` and `Modified Date` comes back,
        the preflight fails with `anonymous_exposure: :exposed` and the
        field names. Untick that type at once.
- [ ] **User.** The driver signs personas up and can delete them (and
      find a sign-up whose answer was lost) only through the `User` Data
      API. A seed with users therefore needs `User` exposed and passing
      the anonymous probe (`persona_cleanup` check). If `User` can't be
      exposed safely, record logged-out only: a seed without users.
- [ ] *(you confirm)* **Don't change any privacy rule.** The recording is
      only worth something if the branch's rules match the parent's. Don't
      tick "ignore privacy rules" anywhere.

## 3. Add the sign-up and login API workflows *(preflight)*

Settings → API → enable **Workflow API**. Then, in Backend workflows:

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
- [ ] The preflight reads `/version-<branch ID>/api/1.1/meta` and needs
      both names among the exposed workflows.

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

## 5. Dry run, then record

1. `Replay.Recorder.plan/4` validates the scenarios against the seed and
   the target (app, branch name, branch ID, host) and estimates the number
   of calls. It makes no requests.
   Review the plan. The driver calls no workflow of your app, only the
   kit's two: scenarios that call app workflows are refused until they can
   be classified as replay-safe (V7).
2. `Replay.Recorder.record/4` needs the plan's `sha256` and a
   `:ledger_dir`. It runs the preflight (refusing the run if the kit is
   incomplete, a type is exposed to logged-out callers, or personas can't
   be cleaned up), then records every scenario twice from a fresh seed
   each time. Before each create it writes an intent to
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
