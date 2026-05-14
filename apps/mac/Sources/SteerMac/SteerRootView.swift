import SwiftUI
import SteerCore

struct SteerRootView: View {
    private let store = LocalSteerStore()
    private let notificationService = ActionNotificationService.shared
    @ObservedObject private var status = SteerAppDelegate.status
    /// Drives the iPhone presence dot's visibility. Observing the
    /// shared SyncClient means the dot appears/disappears the moment
    /// sign-in lands instead of waiting for the next reload tick.
    @ObservedObject private var sync = SyncClient.shared

    @State private var cards: [ActionCard] = []
    @State private var liveChips: [LiveSessionChip] = []
    @State private var focusedSessionId: String? = nil
    @State private var cardDragOffset: CGFloat = 0
    @State private var isLoading = true
    @State private var lastError: String?
    @State private var didLoadInitialCards = false
    @State private var notifiedCardFingerprints = Set<String>()
    /// Snapshots of what we last *published* to the relay. The 2s
    /// reload tick is for local SwiftUI refresh; we publish only when
    /// these snapshots disagree with the freshly loaded cards/chips.
    /// Without this, every tick mirrors all active cards to the
    /// relay regardless of whether anything changed, which is what
    /// made the iPhone carousel jitter every two seconds.
    @State private var lastPublishedCardIds = Set<String>()
    @State private var lastPublishedCardHashes: [String: Int] = [:]
    /// `lastPublishedCardIds` is empty on every cold-start. Without
    /// seeding it from the relay's current active list, any card the
    /// previous Mac process published would never receive a DELETE —
    /// iPhone would keep showing it forever (the "stale active card"
    /// bug we hit in dogfood). On the first successful reload after
    /// sign-in we call `fetchActiveCards` once and treat the result
    /// as our published baseline; the next reconcile pass DELETEs
    /// anything the local store no longer reports active.
    @State private var didSeedFromRelay = false
    /// Per-chip snapshot of (fingerprint, lastPublishedAt). We dedupe
    @State private var liveChipsExpanded = false
    /// Map of `sessionId → instructed-at timestamp (ms)` for sessions
    /// where the user (Mac card reply or iPhone drain) already
    /// successfully injected a reply. Drives the Mac "N running" pill
    /// AND the iPhone chip — both surfaces count the same set.
    ///
    /// Membership is governed entirely by `InstructedSessionDecay`
    /// (SteerCore): the stamp lets the decay distinguish "card from
    /// before the reply" (chip stays) from "card produced after the
    /// reply" (chip falls off). See that helper for the full spec.
    @State private var instructedSessions: [String: InstructedAt] = [:]
    @State private var replyDrafts: [String: String] = [:]
    @State private var attachmentDrafts: [String: [ReplyAttachment]] = [:]
    @Namespace private var sessionTransition

    private var currentIndex: Int {
        guard let focusedSessionId,
              let idx = cards.firstIndex(where: { $0.sessionId == focusedSessionId })
        else {
            return 0
        }
        return idx
    }

    private var currentCard: ActionCard? {
        guard cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    /// Count of sessions the user kicked off (an instruction was
    /// successfully injected) that are still live and have not yet
    /// produced a card. Drives the top "N running" pill.
    ///
    /// Matches iPhone's G15.A invariant exactly:
    ///   running = sessions the user replied to AND no card visible.
    /// `instructedSessions` is the "user-replied" record; subtracting
    /// `cards.sessionId` collapses the chip the instant the terminal
    /// produces a fresh card. The previous `InstructedSessionDecay`
    /// state machine inferred this from card timestamps and could
    /// drift if the decay rule had a hole — cards-derive removes
    /// that surface.
    private var instructedRunningCount: Int {
        let activeCardSessions = Set(cards.map(\.sessionId))
        return instructedSessions.keys.filter { !activeCardSessions.contains($0) }.count
    }

    /// Newest iOS device snapshot polled from /v1/sync/devices, or
    /// nil if no iPhone has ever paired with this account. Drives
    /// the menu-bar iPhone presence dot.
    @State private var iPhoneDevice: DeviceSnapshot?
    @State private var iPhonePopoverVisible: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            SteerColors.appBackground
                .ignoresSafeArea()

            ZStack {
                Text("Steer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .allowsHitTesting(false)

                if sync.isSignedIn {
                    HStack {
                        Spacer()
                        IPhonePresenceDot(
                            device: iPhoneDevice,
                            isPopoverVisible: $iPhonePopoverVisible,
                            hasFetchedOnce: lastDeviceRefreshAt != nil
                        )
                        .padding(.trailing, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 12) {
                if let lastError {
                    ErrorBanner(message: lastError, onDismiss: { self.lastError = nil })
                }

                if instructedRunningCount > 0 {
                    LiveSessionChipRow(
                        chips: liveChips,
                        instructedRunningCount: instructedRunningCount,
                        isExpanded: $liveChipsExpanded
                    )
                    .padding(.leading, 4)
                }

                cardStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ActionCardCarousel(
                    cards: cards,
                    currentIndex: currentIndex,
                    namespace: sessionTransition,
                    onSelect: { tappedIndex in
                        guard cards.indices.contains(tappedIndex) else { return }
                        withAnimation(.snappy(duration: 0.24)) {
                            focusedSessionId = cards[tappedIndex].sessionId
                        }
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)
            .padding(.bottom, 12)
        }
        .frame(width: 375)
        .frame(minHeight: 600, maxHeight: .infinity)
        .background(keyboardShortcuts)
        .animation(.snappy(duration: 0.22), value: currentIndex)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: cards.map(\.sessionId))
        .onChange(of: status.pendingFocusSessionId) { _, newValue in
            guard let sessionId = newValue else { return }
            if cards.contains(where: { $0.sessionId == sessionId }) {
                withAnimation(.snappy(duration: 0.24)) {
                    focusedSessionId = sessionId
                }
            }
            status.pendingFocusSessionId = nil
        }
        .task {
            await refreshLoop()
        }
        // Drain the relay's queued instructions when the WebSocket
        // reports a new one. Without this, drain falls back to the
        // 60s sweeper inside refreshLoop, which is fine for
        // correctness but adds visible reply latency for the first
        // iPhone reply after the Mac launches. Phase A3.
        .onReceive(
            NotificationCenter.default.publisher(for: .syncDidReceiveUpdate)
        ) { _ in
            Task { await drainQueuedInstructions() }
        }
    }

    @ViewBuilder
    private var cardStack: some View {
        if isLoading && cards.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else if let currentCard {
            ActionCardView(
                card: currentCard,
                reply: replyBinding(for: currentCard.sessionId),
                attachments: attachmentsBinding(for: currentCard.sessionId),
                onSend: { text, attachments in sendFromCard(text, attachments: attachments) }
            )
            .matchedGeometryEffect(id: currentCard.sessionId, in: sessionTransition)
            .id(currentCard.id)
            .offset(x: cardDragOffset)
            .rotationEffect(.degrees(cardDragOffset / 34))
            .gesture(cardSwipeGesture)
        } else {
            EmptyStateView(
                icon: emptyStateIcon,
                message: emptyStateMessage,
                detail: emptyStateDetail
            )
        }
    }

    private var emptyStateMessage: String {
        if let lastError {
            return lastError
        }
        if !liveChips.isEmpty {
            return "All clear"
        }
        return "No Steer sessions yet"
    }

    private var emptyStateDetail: String {
        if !liveChips.isEmpty {
            return "Agents are still running."
        }
        return "In a terminal:\n  cd ~/your/project\n  steer codex   # or steer claude"
    }

    /// Empty-state glyph picks the symbol whose meaning maps directly
    /// to *why* the inbox is empty. Two genuinely different states:
    ///   - `liveChips` non-empty → user is connected and has just
    ///     answered everything → green check, "All clear".
    ///   - `liveChips` empty → no agents have ever paired with this
    ///     Mac → terminal glyph, the literal `steer codex` setup hint.
    /// Avoids the prior single-glyph ("terminal") look where both
    /// cases shared the same screen and looked like a setup error.
    private var emptyStateIcon: String {
        if lastError != nil { return "exclamationmark.triangle" }
        if !liveChips.isEmpty { return "checkmark.circle.fill" }
        return "terminal"
    }

    private func replyBinding(for sessionId: String) -> Binding<String> {
        Binding(
            get: { replyDrafts[sessionId] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    replyDrafts.removeValue(forKey: sessionId)
                } else {
                    replyDrafts[sessionId] = newValue
                }
            }
        )
    }

    private func attachmentsBinding(for sessionId: String) -> Binding<[ReplyAttachment]> {
        Binding(
            get: { attachmentDrafts[sessionId] ?? [] },
            set: { newValue in
                if newValue.isEmpty {
                    attachmentDrafts.removeValue(forKey: sessionId)
                } else {
                    attachmentDrafts[sessionId] = newValue
                }
            }
        )
    }

    private func move(_ delta: Int) {
        guard !cards.isEmpty else { return }
        let nextIndex = (currentIndex + delta + cards.count) % cards.count
        focusedSessionId = cards[nextIndex].sessionId
    }

    private var cardSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                cardDragOffset = value.translation.width
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > 82, abs(horizontal) > vertical else {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)) {
                        cardDragOffset = 0
                    }
                    return
                }

                let direction = horizontal < 0 ? 1 : -1
                let exitOffset: CGFloat = horizontal < 0 ? -460 : 460
                withAnimation(.easeIn(duration: 0.16)) {
                    cardDragOffset = exitOffset
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                    move(direction)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        cardDragOffset = 0
                    }
                }
            }
    }

    private func sendFromCard(_ text: String, attachments: [ReplyAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let currentCard else { return }

        Task {
            await send(trimmed, attachments: attachments, to: currentCard.sessionId)
            move(1)
        }
    }

    private func send(_ text: String, attachments: [ReplyAttachment] = [], to sessionId: String) async {
        do {
            try await store.send(text, attachments: attachments.map(\.url), to: sessionId)
            // Both local card replies (this path) and iPhone replies
            // (drainQueuedInstructions) need to mark the target session
            // as "user-kicked-off" so the top pill counts it. Without
            // this hook the pill only ever surfaced iPhone drains and
            // missed every Mac-side card reply.
            instructedSessions[sessionId] = InstructedAt(
                atMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            await reload()
        } catch {
            lastError = "send failed"
        }
    }

    private func refreshLoop() async {
        await reload()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await reload()
        }
    }

    private var keyboardShortcuts: some View {
        ZStack {
            Button("Previous card") { move(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next card") { move(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Refresh") {
                Task { await reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func reload() async {
        let loadedCards = await store.loadCards()
        await notifyForNewCards(loadedCards)
        let activeSessionIds = Set(loadedCards.map(\.sessionId))
        // We need ALL live sessions for the iPhone "N running" chip,
        // including ones that currently have an active card. The chip
        // counts sessions the user already replied to and the terminal
        // is still working on; cards drop in/out of that window but
        // membership in `instructedSessionIds` is the source of truth.
        // Mac UI's chip header (`liveChips`) uses the card-filtered
        // view so we don't double-list a session that has its own card.
        let loadedLive = await store.loadLiveSessions(excluding: [])
        let loadedChips = loadedLive.filter { !activeSessionIds.contains($0.sessionId) }
        cards = loadedCards
        liveChips = loadedChips
        // Decay instructed-session membership. Logic lives in
        // SteerCore.InstructedSessionDecay (with unit tests covering
        // the full spec). Crucially we use the raw `loadedLive` set,
        // not the card-filtered `loadedChips`: if we kept using the
        // filtered set, every reply to an existing card would
        // immediately drop the session from the chip before the
        // terminal had a chance to produce its next response.
        let liveSessionIds = Set(loadedLive.map(\.sessionId))
        let cardSnapshots = loadedCards.map {
            CardUpdateSnapshot(
                sessionId: $0.sessionId,
                updatedAtMs: Int64($0.updatedAt.timeIntervalSince1970 * 1000)
            )
        }
        instructedSessions = InstructedSessionDecay.decay(
            previous: instructedSessions,
            liveSessionIds: liveSessionIds,
            cards: cardSnapshots
        )
        isLoading = false
        // Keep the user's focus stable across reloads. If the previously
        // focused session is gone (resolved / disconnected), fall back to
        // the most recent card (carousel is sorted oldest→newest, so
        // .last is the freshest); otherwise leave focus alone so mid-
        // typing reloads don't yank the user to a different card.
        if let id = focusedSessionId,
           !loadedCards.contains(where: { $0.sessionId == id }) {
            focusedSessionId = loadedCards.last?.sessionId
        } else if focusedSessionId == nil {
            focusedSessionId = loadedCards.last?.sessionId
        }
        // Drop drafts for sessions that no longer have a card.
        let liveIds = Set(loadedCards.map(\.sessionId))
        for key in replyDrafts.keys where !liveIds.contains(key) {
            replyDrafts.removeValue(forKey: key)
        }
        for key in attachmentDrafts.keys where !liveIds.contains(key) {
            for attachment in attachmentDrafts[key] ?? [] {
                AttachmentService.discard(attachment)
            }
            attachmentDrafts.removeValue(forKey: key)
        }
        if !loadedCards.isEmpty || !loadedChips.isEmpty {
            lastError = nil
        }
        SteerAppDelegate.status.waitingCount = loadedCards.count

        let toggleOn = SteerSettings.shared.iPhoneSyncEnabled
        let signedIn = SyncClient.shared.isSignedIn
        SignInDebugLog.write("[reload] toggle=\(toggleOn) signedIn=\(signedIn) cards=\(loadedCards.count)")
        // If we got signed out (or the toggle flipped off) since the
        // last tick, drop our last-published snapshot so the very
        // next sign-in publishes everything fresh. Otherwise the
        // diff thinks the relay already knows about cards it never
        // saw (different account, or pre-account state) and we ship
        // a partial inbox to the iPhone.
        if !signedIn || !toggleOn {
            if !lastPublishedCardIds.isEmpty
                || !lastPublishedCardHashes.isEmpty
            {
                lastPublishedCardIds.removeAll()
                lastPublishedCardHashes.removeAll()
            }
            // Re-seed from relay on the next sign-in / toggle-on
            // cycle (the orphan-cleanup path runs once per
            // sign-in, not just once per process lifetime).
            didSeedFromRelay = false
        }
        // Outbound mirroring respects the toggle — that's a privacy
        // promise the iPhone Sync section makes. Inbound instructions
        // do NOT respect it: if the user once signed in and an iPhone
        // queued a reply, we drain regardless. Otherwise queued
        // instructions pile up forever and the iPhone shows a stale
        // "delivered" state. Sign out is the real off switch.
        if signedIn {
            if toggleOn {
                // First reload after sign-in: seed
                // lastPublishedCardIds from the relay. Without
                // this, any card the previous Mac process
                // published would never receive a DELETE on this
                // process's reconcile pass (its
                // lastPublishedCardIds starts empty), so the
                // iPhone keeps showing yesterday's already-
                // resolved cards. See CardReconciler in SteerCore
                // for the diff logic.
                if !didSeedFromRelay {
                    // First reload after sign-in: seed
                    // lastPublishedCardIds from the relay's active set
                    // so any card the previous Mac process published
                    // (but the current local store no longer reports)
                    // gets DELETEd on the next reconcile pass. See
                    // CardReconciler in SteerCore for the diff logic.
                    let remoteCards = await SyncClient.shared.fetchActiveCards()
                    lastPublishedCardIds = Set(remoteCards.map(\.cardId))
                    didSeedFromRelay = true
                    SignInDebugLog.write(
                        "[reconcile] cold-start seed: relay had \(remoteCards.count) active card(s)"
                    )
                }
                // Cards: diff-based publish so the iPhone doesn't see
                // a fresh WS upsert burst every 2s of the SwiftUI tick.
                let (cardsToPublish, idsToResolve) = diffCardsForPublish(
                    loadedCards: loadedCards
                )
                if !cardsToPublish.isEmpty || !idsToResolve.isEmpty {
                    await syncToiPhone(
                        publishCards: cardsToPublish,
                        idsToResolve: idsToResolve
                    )
                }
                // Chip publishing path is gone — iPhone derives its
                // chip locally from the cards it already receives over
                // WebSocket + its own pendingReplies. The relay's
                // /v1/sync/sessions route is no longer consulted.
            }
            // Drain on every 60s tick at most. The primary drain
            // trigger is the WebSocket instruction.queued message —
            // SyncClient handles that path. This 60s sweeper is the
            // fallback for when the WS connection is dropping
            // reconnects so we never lose an instruction sitting in
            // the relay for more than a minute. Previously this ran
            // every 2s, which made /v1/sync/instructions/queued the
            // single dominant request type on Cloudflare. Phase A3
            // of docs/SYNC_STABILITY_AND_COST_PLAN.md.
            await maybeDrainQueuedInstructions()
        }
        // Heartbeat at most once per 60s; reload runs ~every 2s but we
        // only post when we cross the cooldown.
        if signedIn {
            await maybeHeartbeat(syncEnabled: toggleOn)
            // Refresh the iPhone presence dot on the same cadence —
            // GETting /v1/sync/devices on every 2s tick would be the
            // same kind of Cloudflare spam the heartbeat was. The
            // popover content is "last seen Ns ago" granularity, so a
            // minute of staleness is fine.
            await maybeRefreshIPhoneDevice()
        } else if iPhoneDevice != nil {
            // Drop stale presence the moment we sign out so the dot
            // doesn't keep showing yesterday's iPhone.
            iPhoneDevice = nil
        }
    }

    @State private var lastDeviceRefreshAt: Date? = nil
    private func maybeRefreshIPhoneDevice() async {
        let now = Date()
        // 30 s cadence — iOS heartbeats every 60 s, so polling
        // twice that gives us at most one stale window before the
        // dot updates. Lower than the 60 s heartbeat cooldown and
        // we'd waste relay GETs for no extra freshness.
        if let last = lastDeviceRefreshAt, now.timeIntervalSince(last) < 30 {
            return
        }
        lastDeviceRefreshAt = now
        let devices = await SyncClient.shared.fetchDevices()
        // Pick the most-recently-seen iOS device. Users typically
        // pair one iPhone, but if they sign in on multiple, the one
        // with the freshest heartbeat is the one they actually have
        // in front of them.
        iPhoneDevice = devices
            .filter { $0.platform == "ios" }
            .max(by: { $0.lastSeenAt < $1.lastSeenAt })
    }

    @State private var lastHeartbeatAt: Date? = nil
    private func maybeHeartbeat(syncEnabled: Bool) async {
        let now = Date()
        if let last = lastHeartbeatAt, now.timeIntervalSince(last) < 60 {
            return
        }
        lastHeartbeatAt = now
        await SyncClient.shared.sendDeviceHeartbeat(syncEnabled: syncEnabled)
    }

    /// 60s sweeper. The primary drain trigger is the WS
    /// instruction.queued message; this fallback catches anything
    /// that slipped through during a reconnect or while the WS was
    /// dropped. Was every-tick (2s) before Phase A3 — easily the
    /// dominant request type on Cloudflare per the relay tail.
    @State private var lastDrainAt: Date? = nil
    private func maybeDrainQueuedInstructions() async {
        let now = Date()
        if let last = lastDrainAt, now.timeIntervalSince(last) < 60 {
            return
        }
        lastDrainAt = now
        await drainQueuedInstructions()
    }

    /// Splits the freshly loaded card set against the last-published
    /// snapshot into (cards that changed → PUT now) and (card ids
    /// that disappeared → DELETE on the relay).
    ///
    /// Computes the changed-content set locally (fingerprint diff),
    /// then delegates the (publish, resolve, next-baseline) decision
    /// to `CardReconciler.reconcile` so it can be unit-tested in
    /// SteerCore without standing up the SwiftUI app.
    private func diffCardsForPublish(
        loadedCards: [ActionCard]
    ) -> (publish: [ActionCard], resolve: [String]) {
        let currentIds = Set(loadedCards.map(\.id))
        let changedIds = Set(
            loadedCards
                .filter { card in
                    let hash = SteerCardMapping.payload(from: card).publishFingerprint
                    return lastPublishedCardHashes[card.id] != hash
                }
                .map(\.id)
        )

        let decision = CardReconciler.reconcile(
            currentLocalIds: currentIds,
            lastPublishedIds: lastPublishedCardIds,
            changedIdsSinceLastPublish: changedIds
        )

        // Map publishIds back to full ActionCard payloads. The
        // reconciler intentionally only deals in ids; the caller
        // owns the payload lookup.
        let cardsToPublish = loadedCards.filter { decision.publishIds.contains($0.id) }
        let idsToResolve = Array(decision.resolveIds)

        // Update the fingerprint snapshot OPTIMISTICALLY. If a
        // PUT/DELETE fails the request layer retries on its own and
        // the next tick will catch any drift (the hashes still
        // match if nothing actually changed server-side).
        for card in cardsToPublish {
            lastPublishedCardHashes[card.id] = SteerCardMapping.payload(from: card).publishFingerprint
        }
        for id in decision.resolveIds {
            lastPublishedCardHashes.removeValue(forKey: id)
        }
        lastPublishedCardIds = decision.nextPublishedIds

        return (cardsToPublish, idsToResolve)
    }

    private func syncToiPhone(
        publishCards: [ActionCard],
        idsToResolve: [String]
    ) async {
        SignInDebugLog.write(
            "[syncToiPhone] publishing \(publishCards.count) cards, resolving \(idsToResolve.count) stale"
        )
        for card in publishCards {
            let payload = SteerCardMapping.payload(from: card)
            await SyncClient.shared.publishCard(payload)
        }
        // Reconcile: anything that disappeared from our local DB
        // since the last tick must be DELETEd from the relay so the
        // iPhone stops showing it. We trust our own state — no need
        // to round-trip through fetchActiveCards every tick.
        for id in idsToResolve {
            SignInDebugLog.write("[reconcile] resolving disappeared \(id)")
            await SyncClient.shared.resolveCard(cardId: id)
        }
    }

    /// Reload runs every ~2s, so without this lock a slow `steer send`
    /// subprocess overlaps the next reload tick. The next tick fetches
    /// the same queued row (markInjected hasn't landed yet), spawns a
    /// second `steer send`, and one of the two markInjected POSTs gets
    /// cancelled by URLSession because both share the in-flight task —
    /// surfaces as "markInjected failed: cancelled" in Settings.
    @State private var drainInFlight = false

    private func drainQueuedInstructions() async {
        guard !drainInFlight else { return }
        drainInFlight = true
        defer { drainInFlight = false }

        let queued = await SyncClient.shared.fetchQueuedInstructions()
        for record in queued {
            do {
                try await store.send(record.text, attachments: [], to: record.targetSessionId)
                await SyncClient.shared.markInstructionInjected(instructionId: record.instructionId)
                // Track this session as "user-kicked-off". The next
                // reload tick will check whether it actually entered
                // run_state=running and surface it in the top pill.
                // Membership decays automatically via
                // `InstructedSessionDecay` (see reload()).
                instructedSessions[record.targetSessionId] = InstructedAt(
                    atMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
            } catch {
                await SyncClient.shared.markInstructionFailed(
                    instructionId: record.instructionId,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func notifyForNewCards(_ loadedCards: [ActionCard]) async {
        let notifiableCards = loadedCards.filter(\.shouldNotify)
        let activeFingerprints = Set(notifiableCards.map(notificationFingerprint(for:)))

        guard didLoadInitialCards else {
            notifiedCardFingerprints = activeFingerprints
            didLoadInitialCards = true
            return
        }

        for card in notifiableCards where !notifiedCardFingerprints.contains(notificationFingerprint(for: card)) {
            await notificationService.notify(card: card)
        }

        notifiedCardFingerprints = activeFingerprints
    }
}


private struct CardBackplate: View {
    let offset: CGFloat
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(SteerColors.cardBackplate)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(SteerColors.softSeparator, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: 590)
            .scaleEffect(scale)
            .offset(y: offset)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { item in
                Capsule()
                    .fill(item == index ? Color.accentColor : SteerColors.subtleFill)
                    .frame(width: item == index ? 20 : 7, height: 7)
            }
        }
        .frame(height: 38)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SteerColors.blocked)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SteerColors.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SteerColors.blocked.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SteerColors.blocked.opacity(0.30), lineWidth: 1)
        }
    }
}

private struct LiveSessionChipRow: View {
    let chips: [LiveSessionChip]
    let instructedRunningCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        LiveSessionChipPill(chip: chip)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 4)
            }
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)

            HStack {
                RunningBadge(runningCount: instructedRunningCount)
                Spacer(minLength: 0)
            }
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(!isExpanded)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !chips.isEmpty else { return }
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

private struct RunningBadge: View {
    let runningCount: Int

    private var label: String {
        "\(runningCount) running"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(SteerColors.running)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SteerColors.cardBackground, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(SteerColors.softSeparator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow.opacity(0.5), radius: 6, y: 2)
        .accessibilityLabel(label)
    }
}

private struct LiveSessionChipPill: View {
    let chip: LiveSessionChip

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(chip.project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(SteerColors.cardBackground, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(SteerColors.softSeparator, lineWidth: 1)
        }
        .shadow(color: SteerColors.cardShadow.opacity(0.5), radius: 6, y: 2)
        .accessibilityLabel("\(chip.project), \(chip.runState)")
    }

    private var stateColor: Color {
        switch chip.runState {
        case "blocked": return SteerColors.blocked
        case "waiting": return SteerColors.waiting
        default: return SteerColors.running
        }
    }
}

private struct ActionCardCarousel: View {
    let cards: [ActionCard]
    let currentIndex: Int
    let namespace: Namespace.ID
    let onSelect: (Int) -> Void

    var body: some View {
        if cards.isEmpty {
            Color.clear.frame(height: 0)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            CompactActionCardView(card: card, isCurrent: index == currentIndex)
                                .onTapGesture { onSelect(index) }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                                    removal: .scale(scale: 0.95).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0)
                    .padding(.trailing, 18)
                }
                .frame(height: 100)
            }
        }
    }
}

private struct CompactActionCardView: View {
    let card: ActionCard
    let isCurrent: Bool

    private var headerTint: Color {
        SteerColors.hueTint(hue: card.accentHue, intensity: 1.0)
    }

    private var summaryLine: AttributedString {
        let trimmed = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? card.title : trimmed
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProviderMark(provider: card.provider, size: 14)
                Text(card.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerTint)

            Text(summaryLine)
                .font(.system(size: 11))
                .foregroundStyle(SteerColors.secondaryInk)
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 11)
                .padding(.vertical, 11)
                .background(SteerColors.cardBackground)
        }
        .frame(width: 132, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.accentColor.opacity(0.7) : SteerColors.softSeparator,
                    lineWidth: isCurrent ? 1.5 : 1
                )
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let message: String
    let detail: String

    /// The "all clear" check is the only state we want to lean green
    /// on — it reads as completion, not the muted "nothing here yet"
    /// of the other states.
    private var iconColor: Color {
        icon == "checkmark.circle.fill"
            ? SteerColors.running
            : SteerColors.tertiaryInk
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(iconColor)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SteerColors.secondaryInk)
            // Onboarding command line stays monospaced — it's literal
            // shell text the user will copy. Display copy is SF.
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SteerColors.tertiaryInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: 540)
        .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SteerColors.separator, lineWidth: 1)
        }
    }
}

/// Tiny iPhone-pairing indicator that lives in the top-right of the
/// Mac window's header. Color encodes recency of the iPhone's last
/// heartbeat:
///   - green: heartbeat within 90s — phone is awake nearby
///   - yellow: 90s–10min — phone may be locked or asleep
///   - gray: > 10min, or no iOS device has ever paired
///
/// Tapping the dot opens a popover with the iPhone's device class,
/// "last seen N ago" text, and an unpaired prompt if nothing has
/// ever registered. Intentionally label-less in the header so it
/// reads as a status light, not a button.
private struct IPhonePresenceDot: View {
    let device: DeviceSnapshot?
    @Binding var isPopoverVisible: Bool

    fileprivate enum Freshness { case connecting, fresh, stale, cold, none }

    let hasFetchedOnce: Bool

    fileprivate var freshness: Freshness {
        // First fetch hasn't returned yet: we're still figuring out
        // whether the user has an iPhone paired. Same "we're working
        // on it" semantic as the iPhone's connecting chip.
        if !hasFetchedOnce { return .connecting }
        guard let device else { return .none }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - device.lastSeenAt
        let ageSeconds = Double(ageMs) / 1000
        // Mirror the iPhone chip's tolerance window. iOS heartbeats
        // every 60s while the app is in the foreground, so a 120s
        // window covers one missed beat (jitter, brief background)
        // without flipping the dot to yellow. 5 min of silence is
        // a real "phone is asleep" signal.
        if ageSeconds < 120 { return .fresh }
        if ageSeconds < 300 { return .stale }
        return .cold
    }

    private var dotColor: Color {
        switch freshness {
        case .connecting: return SteerColors.running
        case .fresh: return SteerColors.running
        case .stale: return SteerColors.waiting
        case .cold, .none: return SteerColors.softSeparator
        }
    }

    /// Drives the dot pulse during `.connecting`. Mirrors the
    /// iPhone chip's behavior — only the in-flight state breathes;
    /// fresh/stale/cold/none stay static so the dot doesn't become
    /// a permanent attention-grabber.
    @State private var breathe = false

    var body: some View {
        Button(action: { isPopoverVisible.toggle() }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .opacity(freshness == .connecting && breathe ? 0.45 : 1.0)
                    .animation(
                        freshness == .connecting
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: breathe
                    )
                // SF Mono reads as "metadata / system" — feels like
                // a status line rather than a label competing with
                // the "Steer" wordmark. Kept at tertiaryInk + 50%
                // alpha so it sinks into the chrome.
                Text(labelText)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(SteerColors.tertiaryInk.opacity(0.65))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { breathe = true }
        .popover(isPresented: $isPopoverVisible, arrowEdge: .top) {
            IPhonePresencePopoverContent(device: device, freshness: freshness)
        }
    }

    /// Prefer the actual device name (UIDevice.current.name on iOS,
    /// e.g. "Ilwon's iPhone") because that's the line that makes
    /// the user say "oh, that's my phone." `deviceClass` is the
    /// generic UIDevice.model — usually just "iPhone" — so it's a
    /// fallback, not the first choice. No iPhone paired = "iPhone"
    /// alone, paired with a dimmed gray dot.
    private var labelText: String {
        if freshness == .connecting { return "Connecting" }
        if let display = device?.displayName, !display.isEmpty {
            return display
        }
        return device?.deviceClass ?? "iPhone"
    }

    private var accessibilityLabel: String {
        switch freshness {
        case .connecting: return "Looking for iPhone"
        case .fresh: return "iPhone connected"
        case .stale: return "iPhone idle"
        case .cold: return "iPhone offline"
        case .none: return "iPhone not paired"
        }
    }
}

private struct IPhonePresencePopoverContent: View {
    let device: DeviceSnapshot?
    let freshness: IPhonePresenceDot.Freshness

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if freshness == .connecting {
                Text("Looking for iPhone…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                Text("Checking the relay for a signed-in iPhone.")
                    .font(.system(size: 11))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let device {
                Text(device.displayName ?? device.deviceClass ?? "iPhone")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                Text(statusLine(for: device))
                    .font(.system(size: 11))
                    .foregroundStyle(SteerColors.secondaryInk)
            } else {
                Text("No iPhone paired")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteerColors.ink)
                // Plain hint copy — the public TestFlight / App Store
                // link isn't ready yet, so don't make a button that
                // dead-ends. When the build is live, swap this for a
                // real link.
                Text("Install Steer on iPhone and sign in with the same Apple ID.")
                    .font(.system(size: 11))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 220, alignment: .leading)
    }

    private func statusLine(for device: DeviceSnapshot) -> String {
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - device.lastSeenAt
        let ageSeconds = max(0, Double(ageMs) / 1000)
        let agoText: String
        if ageSeconds < 60 {
            agoText = "just now"
        } else if ageSeconds < 3600 {
            agoText = "\(Int(ageSeconds / 60)) min ago"
        } else if ageSeconds < 86400 {
            agoText = "\(Int(ageSeconds / 3600))h ago"
        } else {
            agoText = "\(Int(ageSeconds / 86400))d ago"
        }
        switch freshness {
        case .connecting: return "Looking for iPhone…"
        case .fresh: return "Connected · last seen \(agoText)"
        case .stale: return "Idle · last seen \(agoText)"
        case .cold: return "Offline · last seen \(agoText)"
        case .none: return "Not paired"
        }
    }
}

#Preview {
    SteerRootView()
}
