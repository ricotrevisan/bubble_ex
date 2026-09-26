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
      `-`, `_`). Never add the kit to `test` or live.
- [ ] Check that the branch's URL is
      `https://<app>.bubbleapps.io/version-wtfreplay/`. The driver builds
      only that URL. It refuses custom domains (they serve live at the root)
      and doesn't follow redirects.
- [ ] *(you confirm)* Branches share the **development database** with
      `test`. The driver creates records there and deletes only the ones it
      created (the seed ledger). If you keep real people's data in
      development, use a copy of the app instead.

## 2. Expose the Data API for the types under test *(preflight)*

- [ ] Settings → API → enable **Data API**.
- [ ] Tick every data type the verification covers (for the privacy
      matrix, every type in the seed, including **User**). The preflight
      runs a search that matches no records (`_id in []`) on each type and
      needs HTTP 200.
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
- [ ] The preflight reads `/version-wtfreplay/api/1.1/meta` and needs both
      names among the exposed workflows.

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
   the target and estimates the number of calls. It makes no requests.
   Review the plan. The driver calls no workflow of your app, only the
   kit's two: scenarios that call app workflows are refused until they can
   be classified as replay-safe (V7).
2. `Replay.Recorder.record/4` needs the plan's `sha256` and a
   `:ledger_dir`. It runs the preflight, then records every scenario twice
   from a fresh seed each time. Before each create it writes an intent to
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
