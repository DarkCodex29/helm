# Device validation checklist — one pass on the S22

Everything in `feat/upload-queue-2026-10` ran against test doubles. This is
the ordered list for a single hardware session, so nothing needs a second
pass. Written because the user's preference is explicit: validate once, at
the end, all of it together.

Steps run in document order, top to bottom; numbering restarts per section.
Nothing below is a claim that the feature works. These are the exact things
only a device can answer.

## Before anything

1. Attach the phone over USB and confirm `adb devices -l` lists it. Every
   measurement in this block was made without a device attached, which is
   why some of it is guesswork marked as such.
2. Record `adb shell getprop ro.build.version.release` and
   `ro.build.version.sdk`. **This single number decides whether a whole code
   path is dead or live:** the native Photo Picker needs API 33+, and below
   that the app takes the filtered document-picker fallback. The fallback
   was built because the version could not be read; if the S22 is on 13 or
   newer, that branch is untested-and-unreachable here rather than untested-
   and-reachable, which is worth knowing before anyone invests in it.
3. `flutter install` after a clean build. Note the paid-for trap: a
   `--no-codesign` build poisons later builds, and `flutter install`
   UNINSTALLS the app before it fails, which once left the phone with no
   helm at all.

## SFTP writes — never exercised on hardware, not even before this block

These were already unverified when the block started; the queue only added
to them.

1. Create a folder, rename an entry, delete a file, delete a non-empty
   directory (must be refused with its own message).
2. Download a file and confirm it reaches the chosen folder, and that the
   name reported is the name actually written.

## Upload — the point of the whole block

1. Upload button opens the source modal with exactly two options:
   documents, and photos and videos.
2. **Document branch**: pick a document, confirm it lands and the listing
   refreshes by itself.
3. **Media branch**: open the gallery picker. This is the thing that could
   not be tested at all — `MediaStore.ACTION_PICK_IMAGES` reaches a method
   channel no test host has. Confirm it is the real gallery and that NO
   storage-permission prompt appears.
4. **Multi-select**: pick at least five photos. Confirm all five enqueue,
   that exactly ONE uploads at a time, and that the strip shows the active
   name and percent plus counts for the rest.
5. **Collision**: upload the same photo twice. The second must land as
    `name(1).ext` and the strip must SAY the new name. Verifying the copy is
    the point: it used to lie, telling the user to rename the file on the
    host.
6. **Cancel one** mid-queue: that item stops, the queue continues with the
    next.
7. **Cancel all** mid-queue: the active transfer stops and no pending item
    starts.
8. Confirm no `.helmpart` file is left behind on the host after a cancel.
    Cleanup is best-effort and logged, so a server that refuses removal can
    retain one — check rather than assume.
9. **Large file over mobile data**, not Wi-Fi. The per-chunk watchdog is 30
    seconds and nothing has ever exercised it on a real link.

## Floating keyboard

1. The FAB opens and closes the panel, and does not cover the terminal's
    last line when closed.
2. **The claim to check first**: the panel overlaps the terminal rather
    than resizing it. Measured as 30x41 open, closed and resized with zero
    PTY resize calls — but against a fake SSH service. Confirm against a
    live PTY with `who` + `stty -f /dev/ttyNNN size`. Do NOT use
    `herdr pane layout`: it reports the desktop window's geometry and does
    not change when an SSH client attaches.
3. Drag by the handle. Confirm a drag starting near a key does not fire
    that key, and that a key press is not swallowed as a micro-drag.
4. Resize to the minimum. Confirm the seven top-bar keys still measure 48dp
    or more and the letter keys 44dp or more, and that hitting the limit
    SAYS so rather than feeling broken.
5. Resize to the maximum, then rotate to landscape and back. The panel must
    stay fully on screen and its handle and grip must stay reachable.
6. Kill the app and reopen it: the position and size must come back.
7. Reset must be reachable and must work from the worst states it exists to
    recover from — smallest size, dragged into a corner, partially off-screen
    after rotation.

## Known traps from previous sessions, so they are not rediscovered

- Three times a reported "bug" was a bad measurement: a port truncated to
  `2` in a screenshot when it was `22`, a phone called offline on Tailscale
  while already connected, and an auto-hold called broken while the app
  waited on a fingerprint. Measure twice before filing.
- Absence of a warning can be absence of EXECUTION. Confirm `VM Service`
  and `Syncing files` appear before concluding a run was clean.
- Tailscale IPs are stable per NODE REGISTRATION, not per machine. Use
  MagicDNS names in profiles.
