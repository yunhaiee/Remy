package com.yunha.remy.core

/** One display owner. A knife event owns the headline for one second; contact/haptics stay separate. Times in seconds. */
class GuidancePillArbiter {
    enum class Source(val raw: Int) {
        IDLE(0), CURL(40), CHEF(70), COACHING(80), SAFETY(90), KNIFE(100);
        val immediate: Boolean get() = this == KNIFE || this == SAFETY || this == CHEF
    }
    data class Entry(val source: Source, val text: String)

    var current: Entry? = null; private set
    private var candidate: Entry? = null
    private var candidateSince = 0.0
    private var knifeNotice: Entry? = null
    private var knifeNoticeUntil = Double.NEGATIVE_INFINITY
    private var knifeWasActive = false

    fun reset() {
        current = null; candidate = null; candidateSince = 0.0; knifeNotice = null
        knifeNoticeUntil = Double.NEGATIVE_INFINITY; knifeWasActive = false
    }

    fun update(entries: List<Entry>, time: Double) {
        if (!time.isFinite()) return
        val valid = entries.filter { it.text.trim().isNotEmpty() }.toMutableList()
        val knife = valid.firstOrNull { it.source == Source.KNIFE }
        if (knife != null && !knifeWasActive) {
            knifeNotice = knife; knifeNoticeUntil = time + 1
        }
        knifeWasActive = knife != null
        // Capture only the entry edge. Incoming instructions cannot shorten this window,
        // and held contact cannot extend it indefinitely or replay it every frame.
        valid.removeAll { it.source == Source.KNIFE }
        val notice = knifeNotice
        if (notice != null && time < knifeNoticeUntil) valid.add(notice) else knifeNotice = null
        val winner = valid.maxByOrNull { it.source.raw }
        if (winner == null) { current = null; candidate = null; return }
        if (winner.source.immediate) { current = winner; candidate = null; return }
        if (current == winner) { candidate = null; return }
        // Other removed alerts and hints clear immediately; only the knife notice has a timed display.
        val shown = current
        if (shown != null && valid.none { it.source == shown.source }) {
            current = valid.filter { it.source == Source.IDLE || it.source == Source.CHEF }.maxByOrNull { it.source.raw }
        }
        if (winner.source == Source.IDLE) { current = winner; candidate = null; return }
        if (candidate != winner) { candidate = winner; candidateSince = time }
        if (time - candidateSince >= 0.35) { current = winner; candidate = null }
    }
}
