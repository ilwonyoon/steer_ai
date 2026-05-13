# Steer Privacy Policy

Effective date: May 10, 2026

This Privacy Policy explains how Steer collects, uses, stores, and deletes information when you use the Steer iPhone app, Steer for Mac, and Steer's relay service.

Publication details:

- Legal operator: `Ilwon Yoon`
- Contact email: `superwedge.labs@gmail.com`
- Published URL: `https://steer.ai/privacy` *(serve via GitHub Pages until the canonical site is live)*

## What Steer Does

Steer is an action inbox for local Mac coding agents. The Mac app observes Steer-managed CLI sessions, turns waiting or blocked moments into action cards, and can deliver replies back to the local session when the user sends a reply from Steer.

The iPhone app is not a remote terminal and does not mirror a live shell. It shows synced action cards, lets you write replies, and shows delivery status.

## Information We Collect

Steer collects the minimum information needed to authenticate you and sync action cards between your own devices.

### Account Information

When you sign in with Apple, Steer receives and stores:

- Apple's stable user identifier for your account.
- Your Apple relay email or real email, if Apple provides it.
- Your display name, if Apple provides it and you choose to share it.

Steer stores a session token in the device Keychain so you can stay signed in.

### Action Card And Session Information

If you enable iPhone sync, Steer may send the following from your Mac to the Steer relay:

- Action card IDs and session IDs.
- Card category, priority, title, summary, state, and timestamps.
- Short terminal excerpts used to explain why the card needs attention.
- Suggested reply options.
- Project display label, provider label, and branch label.

Terminal excerpts and project labels may contain sensitive coding context, local path fragments, repository names, errors, command output, or other information shown by your CLI tools. Do not enable sync for sessions that may expose data you do not want transmitted to the relay.

### Replies And Delivery Status

When you send a reply from iPhone, Steer stores:

- The reply text.
- The target session ID.
- The instruction ID.
- Queued, injected, or failed delivery status.
- Failure reason, if delivery fails.

The Mac app later reads queued replies from the relay and injects them into the matching local Steer-managed session.

### Local Mac Data

Steer for Mac stores local session data on your Mac, including the local SQLite database and session transcript logs under the user's Steer data directory. Local transcript logs are not sent to the relay unless they are turned into synced card fields or terminal excerpts.

### Diagnostics

Steer does not currently use third-party analytics SDKs or advertising SDKs. The relay provider and platform infrastructure may process operational request metadata, such as IP address, timestamps, request paths, and error logs, to operate and secure the service.

## How We Use Information

Steer uses collected information to:

- Authenticate your devices.
- Sync action cards between your Mac and iPhone.
- Queue replies from iPhone and deliver them through your Mac.
- Show delivery status and errors.
- Maintain service reliability, prevent abuse, and debug operational issues.

Steer does not sell your personal information. Steer does not use your synced card content, terminal excerpts, or replies for advertising. Steer does not use your content to train AI models.

## Third-Party Services

Steer uses the following service providers:

- Apple Sign in with Apple, for authentication.
- Cloudflare Workers, D1, and Durable Objects, for the Steer relay, database, and WebSocket fanout.

These providers process information as needed to provide their services to Steer.

Third-party coding tools that you use with Steer, such as Claude Code, Codex CLI, Gemini CLI, or other command-line tools, are governed by their own terms and privacy policies. Steer does not control those services.

## Data Retention

Steer keeps relay account data and synced action data while your account is active or until you delete your account. Resolved cards and historical instruction records may remain in the relay until deleted through account deletion or future cleanup tools.

Local Mac transcripts and databases remain on your Mac until you delete them or use a Steer cleanup feature.

## Account Deletion

You can delete your Steer relay account from the app once the account deletion UI is enabled for launch. Deleting your account removes your relay user record and associated relay cards, instructions, and sessions from Steer's database, unless retention is required by law.

Deleting your relay account does not automatically delete local files on your Mac. You may separately remove local Steer data from your Mac.

## Security

Steer uses Sign in with Apple for authentication. Session tokens are stored in the device Keychain. Network requests to the relay use HTTPS or secure WebSocket connections.

No system can be guaranteed perfectly secure. You should avoid syncing sessions that display secrets, private keys, customer data, confidential code, or other highly sensitive information.

## Children's Privacy

Steer is intended for developers and is not directed to children.

## Changes

We may update this Privacy Policy when Steer's product, data practices, or service providers change. The effective date above will be updated when material changes are made.

## Contact

For privacy questions or deletion requests, contact `superwedge.labs@gmail.com`.
