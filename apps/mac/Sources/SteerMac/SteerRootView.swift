import SwiftUI
import SteerCore

struct SteerRootView: View {
    private let store = LocalSteerStore()
    private let notificationService = ActionNotificationService.shared
    @ObservedObject private var status = SteerAppDelegate.status

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
    /// Per-chip snapshot of (fingerprint, lastPublishedAt). We dedupe
    /// on the fingerprint to avoid spam, but we ALSO force a publish
    /// every ~30s so the relay's last_activity_at stays fresh — its
    /// listLiveSessions cutoff drops sessions whose row hasn't been
    /// touched in 90s, and dedupe alone would let a steadily running
    /// session fall off that cliff and stop showing on iPhone.
    @State private var lastPublishedChipFingerprints: [String: (fp: String, at: Date)] = [:]
    @State private var liveChipsExpanded = false
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

    var body: some View {
        ZStack(alignment: .top) {
            SteerColors.appBackground
                .ignoresSafeArea()

            Text("Steer")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SteerColors.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 28)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                if let lastError {
                    ErrorBanner(message: lastError, onDismiss: { self.lastError = nil })
                }

                if !liveChips.isEmpty {
                    LiveSessionChipRow(
                        chips: liveChips,
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
            EmptyStateView(message: emptyStateMessage, detail: emptyStateDetail)
        }
    }

    private var emptyStateMessage: String {
        if let lastError {
            return lastError
        }
        if !liveChips.isEmpty {
            return "No waiting actions"
        }
        return "No Steer sessions yet"
    }

    private var emptyStateDetail: String {
        if !liveChips.isEmpty {
            return "Running sessions appear here when they stop."
        }
        return "In a terminal:\n  cd ~/your/project\n  steer codex   # or steer claude"
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
        let loadedChipsRaw = await store.loadLiveSessions(excluding: activeSessionIds)
        // Belt-and-suspenders: loadLiveSessions runs a separate sqlite3
        // subprocess from loadCards, so a session that flipped from
        // `running` to `waiting` between the two queries can briefly
        // show up in BOTH lists ("1 running · 1 waiting" for what is
        // really one session). Filter the chip list one more time
        // here, in the same tick, against the cards we just observed.
        let loadedChips = loadedChipsRaw.filter { !activeSessionIds.contains($0.sessionId) }
        cards = loadedCards
        liveChips = loadedChips
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
                || !lastPublishedChipFingerprints.isEmpty
            {
                lastPublishedCardIds.removeAll()
                lastPublishedCardHashes.removeAll()
                lastPublishedChipFingerprints.removeAll()
            }
        }
        // Outbound mirroring respects the toggle — that's a privacy
        // promise the iPhone Sync section makes. Inbound instructions
        // do NOT respect it: if the user once signed in and an iPhone
        // queued a reply, we drain regardless. Otherwise queued
        // instructions pile up forever and the iPhone shows a stale
        // "delivered" state. Sign out is the real off switch.
        if signedIn {
            if toggleOn {
                // Diff-based publish. Only PUT the cards/chips that
                // actually changed since our last successful publish,
                // and only DELETE rows the iPhone still believes are
                // active. SwiftUI tick runs every 2s but most ticks
                // observe the same set of cards with identical
                // contents; without this gate we re-publish them all
                // on every tick and the iPhone sees a fresh WS upsert
                // burst every two seconds.
                let (cardsToPublish, idsToResolve) = diffCardsForPublish(
                    loadedCards: loadedCards
                )
                let chipsToPublish = diffChipsForPublish(loadedChips: loadedChips)
                if !cardsToPublish.isEmpty || !idsToResolve.isEmpty {
                    await syncToiPhone(
                        publishCards: cardsToPublish,
                        idsToResolve: idsToResolve
                    )
                }
                if !chipsToPublish.isEmpty {
                    await syncLiveSessionsToiPhone(chips: chipsToPublish)
                }
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
        }
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

    /// Push the running-session chip list to the relay so the iPhone
    /// can render the "1 running" badge inside its connection chip.
    /// LiveSessionChip is what RunningBadge already consumes locally;
    /// we lift the same shape to the wire as SessionSnapshot.
    private func syncLiveSessionsToiPhone(chips: [LiveSessionChip]) async {
        for chip in chips {
            let snapshot = SessionSnapshot(
                sessionId: chip.sessionId,
                provider: chip.provider.rawValue,
                projectName: chip.project,
                branchLabel: nil,
                runState: chip.runState,
                lastActivityAt: Int64(chip.lastActivityAt.timeIntervalSince1970 * 1000)
            )
            await SyncClient.shared.publishSession(snapshot)
        }
    }

    /// Diff helper. Splits the freshly loaded card set against the
    /// last-published snapshot into (cards that changed → PUT now)
    /// and (card ids that disappeared locally → DELETE on the relay).
    /// Updates the snapshots as a side effect so the next tick sees
    /// the new baseline.
    private func diffCardsForPublish(
        loadedCards: [ActionCard]
    ) -> (publish: [ActionCard], resolve: [String]) {
        let currentIds = Set(loadedCards.map(\.id))
        let cardsToPublish = loadedCards.filter { card in
            let hash = SteerCardMapping.payload(from: card).publishFingerprint
            let prev = lastPublishedCardHashes[card.id]
            return prev != hash
        }
        let idsToResolve = Array(lastPublishedCardIds.subtracting(currentIds))
        // Update the snapshots so the next tick doesn't re-publish
        // these. We update OPTIMISTICALLY here; if a PUT/DELETE fails
        // the request layer retries on its own and the next tick
        // will catch any drift (the hashes still match if nothing
        // actually changed server-side).
        for card in cardsToPublish {
            lastPublishedCardHashes[card.id] = SteerCardMapping.payload(from: card).publishFingerprint
        }
        for id in idsToResolve {
            lastPublishedCardHashes.removeValue(forKey: id)
        }
        lastPublishedCardIds = currentIds
        return (cardsToPublish, idsToResolve)
    }

    /// Diff helper for live-session chips. Two reasons we may
    /// publish a chip on a given reload tick:
    ///
    /// 1. Its content fingerprint changed since last publish
    ///    (runState / project / provider). Standard dedupe path.
    /// 2. Its content is unchanged but more than 30s elapsed since
    ///    the last publish. This is the heartbeat path: the relay's
    ///    listLiveSessions cutoff drops sessions whose row hasn't
    ///    been touched in 90s, so without a periodic re-publish a
    ///    healthy long-running session would fall off the iPhone
    ///    chip's "N running" count after ~90s of no activity.
    private func diffChipsForPublish(
        loadedChips: [LiveSessionChip]
    ) -> [LiveSessionChip] {
        var next: [LiveSessionChip] = []
        let now = Date()
        let heartbeatInterval: TimeInterval = 30
        for chip in loadedChips {
            let fp = "\(chip.runState)|\(chip.project)|\(chip.provider.rawValue)"
            let prev = lastPublishedChipFingerprints[chip.sessionId]
            let staleHeartbeat = prev.map { now.timeIntervalSince($0.at) > heartbeatInterval } ?? true
            if prev?.fp != fp || staleHeartbeat {
                next.append(chip)
                lastPublishedChipFingerprints[chip.sessionId] = (fp, now)
            }
        }
        // Prune snapshots for chips that no longer exist locally so
        // the dictionary doesn't grow unbounded across long-running
        // sessions.
        let liveIds = Set(loadedChips.map(\.sessionId))
        for key in lastPublishedChipFingerprints.keys where !liveIds.contains(key) {
            lastPublishedChipFingerprints.removeValue(forKey: key)
        }
        return next
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
                RunningBadge(chips: chips)
                Spacer(minLength: 0)
            }
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(!isExpanded)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

private struct RunningBadge: View {
    let chips: [LiveSessionChip]

    private var runningCount: Int {
        chips.filter { $0.runState == "running" }.count
    }
    private var waitingCount: Int {
        chips.filter { $0.runState == "waiting" }.count
    }
    private var blockedCount: Int {
        chips.filter { $0.runState == "blocked" }.count
    }

    private var dominantColor: Color {
        if blockedCount > 0 { return SteerColors.blocked }
        if runningCount > 0 { return SteerColors.running }
        return SteerColors.waiting
    }

    private var label: String {
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        if blockedCount > 0 { parts.append("\(blockedCount) blocked") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dominantColor)
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
        .accessibilityLabel("\(chips.count) live session\(chips.count == 1 ? "" : "s"); \(label)")
        .accessibilityHint("Tap to expand")
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
    let message: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SteerColors.tertiaryInk)
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

#Preview {
    SteerRootView()
}
