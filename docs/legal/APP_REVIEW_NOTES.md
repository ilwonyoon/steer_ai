# App Review Notes Draft

Last updated: May 10, 2026

Use this as the basis for the App Store Connect "Notes for Review" field.

## Review Summary

Steer is an action inbox for local Mac coding agents. The iPhone app lets a user sign in with Apple, review synced action cards from their own Mac, and send replies that are queued through the Steer relay and delivered by Steer for Mac.

Steer is not a remote terminal, remote desktop client, or live shell mirror. The iPhone app does not execute commands directly and does not provide an arbitrary terminal UI. The Mac app owns local session capture and local instruction delivery.

The product is intentionally scoped to action cards and replies. It does not stream the full Mac screen, does not expose a general shell prompt, and does not let the iPhone browse or launch arbitrary Mac commands.

## Companion App Explanation

Live delivery requires Steer for Mac because the coding agent sessions run locally on the user's Mac. The iPhone app still provides native functionality: sign-in, card inbox, card detail, reply composer, queued/delivery state, account management, and launch demo/offline sample mode once enabled.

## Suggested Reviewer Flow

1. Open Steer on iPhone.
2. Tap Try Demo if review credentials or a prepared Mac are not provided.
3. View the sample or synced action card inbox.
4. Open a card detail.
5. Review the terminal excerpt and suggested replies.
6. Send a reply.
7. Observe that the reply is queued or delivered depending on Mac availability.
8. Open account/settings and verify Privacy Policy, Terms, Sign Out, and Delete Account.

## Review Credentials

TODO: Add final demo mode instructions before submission.

If a live relay review account is provided, include:

- Apple ID or review account setup instructions.
- Whether a prepared Mac is online.
- What card should appear after sign-in.
- Expected reply status behavior.

If no live account is provided, Demo Mode must be complete enough to review the app's core functionality without signing in.

## Important Limits

- No live terminal mirror.
- No arbitrary command launcher from iPhone.
- No remote desktop streaming.
- No third-party advertising or tracking SDK.
- No raw transcript sync by default beyond card excerpts needed for action context.
- No team sharing or cross-user collaboration in v1.
- Live delivery only targets sessions launched and owned by the user's own Steer for Mac setup.

## Privacy Notes

Steer uses Sign in with Apple and a Cloudflare Workers relay. The relay stores account identifiers, action cards, short terminal excerpts, replies, session metadata, and delivery status so the user's own Mac and iPhone can sync.

The Privacy Policy and Terms are available in the app and in App Store Connect metadata.
