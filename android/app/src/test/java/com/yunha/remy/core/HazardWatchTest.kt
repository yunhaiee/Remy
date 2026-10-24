package com.yunha.remy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// JUnit port of RemyCore/Tests/RemyCoreTests/HazardWatchTests.swift, test for test.
class HazardWatchTest {
    private val pot = HazardZone("pot", 0.4, 0.4, 0.2, 0.2)
    private fun hand(x: Double, y: Double, id: String = "right", reliable: Boolean = true) =
        HazardWatch.Hand(id, (0 until 21).map { Point2(x + (it % 4) * 0.005, y + (it / 4) * 0.005) }, reliable)
    private fun HazardWatch.at(time: Double, vararg hands: HazardWatch.Hand) = check(hands.toList(), listOf(pot), time, time)

    @Test fun wholeHandWarnsOnceAndRearmsOnlyAfterItLeaves() {
        val watch = HazardWatch()
        assertNull(watch.at(0.0, hand(0.1, 0.1)))
        assertEquals("pot", watch.at(1.0, hand(0.45, 0.45))?.label)
        assertNull("still inside: quiet", watch.at(2.0, hand(0.45, 0.45)))
        assertNull("cooldown alone must not re-arm", watch.at(6.0, hand(0.45, 0.45)))
        assertNull(watch.at(7.0, hand(0.1, 0.1)))
        assertNull("back too soon to re-arm", watch.at(7.5, hand(0.45, 0.45)))
        assertNull(watch.at(8.0, hand(0.1, 0.1)))
        assertEquals("pot", watch.at(9.2, hand(0.45, 0.45))?.label)
    }

    @Test fun fingertipsInsideButWristOutsideDoesNotWarn() {
        val points = hand(0.45, 0.45).points.toMutableList()
        points[0] = Point2(0.39, 0.5)
        assertNull(HazardWatch().at(1.0, HazardWatch.Hand("right", points)))
        // Every landmark is required, not merely a palm/tip majority.
        for (index in 1 until 21) {
            val partial = hand(0.45, 0.45).points.toMutableList()
            partial[index] = Point2(0.601, 0.5)
            assertNull("landmark $index", HazardWatch().at(1.0, HazardWatch.Hand("right", partial)))
        }
    }

    @Test fun approachAndNearbyHandDoNotWarnBeforeWholeHandEnters() {
        val watch = HazardWatch()
        assertNull(watch.at(0.0, hand(0.12, 0.5)))
        assertNull("projection into the pot must not trigger", watch.at(0.1, hand(0.22, 0.5)))
        assertNull("old 10% outside margin must not trigger", watch.at(0.2, hand(0.32, 0.5)))
        assertEquals("pot", watch.at(0.3, hand(0.45, 0.45))?.label)
    }

    @Test fun missingInvalidUnreliableAndDuplicateHandsCannotTrigger() {
        val good = hand(0.45, 0.45)
        val invalid = good.points.toMutableList().also { it[0] = Point2(Double.NaN, 0.5) }
        val cases = listOf(
            listOf(HazardWatch.Hand("right", good.points.drop(1))),
            listOf(HazardWatch.Hand("right", good.points + Point2(0.5, 0.5))),
            listOf(HazardWatch.Hand("right", invalid)),
            listOf(hand(0.45, 0.45, id = "unknown")),
            listOf(hand(0.45, 0.45, reliable = false)),
            listOf(good, good),
        )
        for (hands in cases) assertNull(HazardWatch().check(hands, listOf(pot), 1.0, 1.0))
        assertEquals("one complete hand suffices", "pot", HazardWatch().at(1.0, hand(0.1, 0.1, id = "left"), good)?.label)
    }

    @Test fun staleFutureAndOutOfOrderFramesCannotTrigger() {
        val inside = hand(0.45, 0.45)
        val watch = HazardWatch()
        assertNull("stale", watch.check(listOf(inside), listOf(pot), 1.0, 1.31))
        assertNull("future", watch.check(listOf(inside), listOf(pot), 2.0, 1.0))
        assertNull("invalid clock", watch.check(listOf(inside), listOf(pot), Double.NaN, 1.0))
        assertNull(watch.at(3.0, hand(0.1, 0.1)))
        assertNull("repeated frame", watch.check(listOf(inside), listOf(pot), 3.0, 3.01))
        assertNull("out of order", watch.check(listOf(inside), listOf(pot), 2.99, 3.01))
        assertEquals("pot", watch.check(listOf(inside), listOf(pot), 3.1, 3.2)?.label)
    }

    @Test fun partialContactAndStaleGapDoNotRearm() {
        val watch = HazardWatch()
        assertEquals("pot", watch.at(1.0, hand(0.45, 0.45))?.label)
        val partial = hand(0.45, 0.45).points.toMutableList().also { it[0] = Point2(0.2, 0.2) }
        assertNull(watch.at(4.0, HazardWatch.Hand("right", partial)))
        assertNull("contact never cleared", watch.at(5.0, hand(0.45, 0.45)))
        assertNull(watch.at(6.0))
        assertNull("stale empty frame is not evidence of clear time", watch.check(emptyList(), listOf(pot), 6.1, 8.0))
        assertNull(watch.at(8.1, hand(0.45, 0.45)))
        watch.reset()
        assertNull("reset keeps the recent-alert protection", watch.at(8.2, hand(0.45, 0.45)))
    }

    @Test fun noOrInvalidZonesCannotTrigger() {
        assertNull(HazardWatch().check(listOf(hand(0.45, 0.45)), emptyList(), 1.0, 1.0))
        for (bad in listOf(HazardZone("pan", Double.NaN, 0.4, 0.2, 0.2), HazardZone("pan", 0.4, 0.4, 0.0, 0.2),
                HazardZone("pan", -0.1, 0.4, 1.0, 0.2))) {
            assertNull(HazardWatch().check(listOf(hand(0.45, 0.45)), listOf(bad), 1.0, 1.0))
        }
    }

    @Test fun onlyHeatWordsBecomeHotZones() {
        for (name in listOf("pot", "frying pan", "electric cooker", "kettle", "stove burner", "boiling water", "hot plate")) {
            assertTrue(name, HazardZone.looksHot(name))
        }
        for (name in listOf("knife", "cutting board", "bowl", "tomato", "chef's knife", "scissors")) {
            assertFalse(name, HazardZone.looksHot(name))
        }
    }

    @Test fun twoNamesForOneObjectOverlap() {
        assertTrue(pot.overlaps(HazardZone("pan", 0.41, 0.4, 0.2, 0.21)))
        assertFalse(pot.overlaps(HazardZone("kettle", 0.0, 0.4, 0.2, 0.2)))
    }

    @Test fun cookerProximityWarnsOutsideBoxAndRequiresClearanceToRearm() {
        val watch = HazardWatch().apply { proximityMargin = 0.07; cooldown = 6.0 }
        assertNull(watch.at(0.0, hand(0.1, 0.5)))
        assertEquals("pot", watch.at(1.0, hand(0.35, 0.45))?.label)
        assertNull("remaining nearby must not repeat", watch.at(9.0, hand(0.35, 0.45)))
        assertNull(watch.at(10.0, hand(0.1, 0.5)))
        assertEquals("pot", watch.at(11.2, hand(0.35, 0.45))?.label)
    }

    @Test fun cookerProximityRejectsStaleIncompleteUnknownAndFarHands() {
        val watch = HazardWatch().apply { proximityMargin = 0.07 }
        val near = hand(0.35, 0.45)
        assertNull(watch.check(listOf(near), listOf(pot), 1.0, 1.4))
        assertNull(watch.at(2.0, HazardWatch.Hand("right", near.points.dropLast(1))))
        assertNull(watch.at(3.0, hand(0.35, 0.45, id = "unknown")))
        assertNull(watch.at(4.0, hand(0.1, 0.5)))
        assertEquals("pot", watch.at(5.0, near)?.label)
    }

    @Test fun cookerTargetsRestoreVesselAliasesWithoutInventingOrDuplicatingBoxes() {
        assertTrue(CookerSafetyTargets.queries.contains("pot"))
        assertTrue(CookerSafetyTargets.zones(emptyList()).isEmpty())
        val zones = CookerSafetyTargets.zones(listOf(ItemBox("pot", 0.4, 0.4, 0.2, 0.2),
            ItemBox("electric cooker", 0.41, 0.4, 0.2, 0.2), ItemBox("onion", 0.1, 0.1, 0.1, 0.1),
            ItemBox("kettle", -0.1, 0.1, 0.2, 0.2)))
        assertEquals(1, zones.size)
        assertEquals("Preserve the visible vessel label", "pot", zones.first().label)
        assertEquals(0.4, zones.first().x, 0.0)
    }

    @Test fun cupAliasRequiresAnActualValidBoxAndDoesNotTreatAllCupsAsHot() {
        assertTrue(CookerSafetyTargets.queries.contains("cup"))
        assertEquals("coffee cup", CookerSafetyTargets.zones(listOf(ItemBox("coffee cup", 0.2, 0.3, 0.2, 0.3))).firstOrNull()?.label)
        assertFalse("Cup proxy is scoped to the requested cooking demo", HazardZone.looksHot("cup"))
        for (label in listOf("cupboard", "potato", "tomato")) {
            assertTrue(label, CookerSafetyTargets.zones(listOf(ItemBox(label, 0.2, 0.2, 0.2, 0.2))).isEmpty())
        }
    }

    @Test fun cookerPowerReportsAcceptStatementsAndRejectQuestionsNegationAndIntentions() {
        for (words in listOf("I turned the kettle off", "I've switched off the kettle", "the kettle is off", "I turned it off",
                "the kettle's off", "it's off", "the cooker is switched off")) {
            assertEquals(words, CookerPowerCommand.OFF, CookerPowerCommand.parse(words))
        }
        for (words in listOf("I turned it back on", "I turned the kettle on", "the kettle is back on", "I've just switched on the cooker")) {
            assertEquals(words, CookerPowerCommand.ON, CookerPowerCommand.parse(words))
        }
        for (words in listOf("Is the kettle off?", "I haven't turned it off", "I didn't turn it on", "Should I turn it off",
                "I will turn it off", "turn it off", "the cup is on the table", "I turned the kettle off and back on", "not off")) {
            assertNull(words, CookerPowerCommand.parse(words))
        }
    }

    @Test fun bowlIsARequestedSafetyProxy() {
        assertTrue(CookerSafetyTargets.queries.contains("bowl"))
        assertEquals("bowl", CookerSafetyTargets.zones(listOf(ItemBox("bowl", 0.2, 0.2, 0.3, 0.3))).firstOrNull()?.label)
        assertFalse("Scoped proxy, not a heat measurement", HazardZone.looksHot("bowl"))
    }

    @Test fun anyPartRequiresHalfSecondOfContinuousOverlap() {
        val watch = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 0.5 }
        val tip = HazardWatch.Hand("right", listOf(Point2(0.5, 0.5)))
        assertNull(watch.at(1.0, tip))
        assertNull(watch.at(1.2, tip))
        assertNull(watch.at(1.49, tip))
        assertEquals("pot", watch.at(1.51, tip)?.label)
        assertNull("staying inside must not repeat", watch.at(3.0, tip))
    }

    @Test fun dwellResetsOnExitTrackingLossAndFrameGaps() {
        val tip = HazardWatch.Hand("right", listOf(Point2(0.5, 0.5)))
        for (loss in listOf("exit", "zones", "stale", "gap", "other hand")) {
            val watch = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 0.5 }
            assertNull(watch.at(1.0, tip))
            assertNull(watch.at(1.2, tip))
            when (loss) {
                "exit" -> assertNull(watch.at(1.3))
                "zones" -> assertNull(watch.check(listOf(tip), emptyList(), 1.3, 1.3))
                "stale" -> assertNull(watch.check(listOf(tip), listOf(pot), 1.3, 2.0))
                "other hand" -> assertNull(watch.at(1.3, HazardWatch.Hand("left", tip.points)))
            }
            assertNull(loss, watch.at(1.6, tip))
        }
    }

    @Test fun skeletalSegmentCrossingCountsButNearbyOutsideDoesNot() {
        val points = MutableList(21) { Point2(0.1, 0.5) }
        points[1] = Point2(0.9, 0.5)
        assertTrue(pot.intersectsHand(points))
        assertFalse("No outside proximity margin in overlap mode", pot.intersectsHand(listOf(Point2(0.39, 0.5))))
        assertFalse(pot.intersectsHand(listOf(Point2(Double.NaN, 0.5))))
    }

    @Test fun visibleFingertipCanDwellWhenOtherLandmarksAreOffscreen() {
        val watch = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 0.5 }
        val partial = HazardWatch.Hand("right", listOf(Point2(-0.1, 0.5), Point2(0.5, 0.5)))
        assertNull(watch.at(1.0, partial))
        assertNull(watch.at(1.2, partial))
        assertNull(watch.at(1.4, partial))
        assertEquals("pot", watch.at(1.51, partial)?.label)
    }

    @Test fun heldAlarmStartsAtOneSecondStaysActiveAndResetsImmediatelyOnExit() {
        val watch = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 1.0; holdsAlertUntilExit = true }
        val hand = HazardWatch.Hand("right", listOf(Point2(0.5, 0.5)))
        for (time in listOf(0.0, 0.2, 0.4, 0.6, 0.8, 0.99)) assertNull(watch.at(time, hand))
        assertTrue(watch.hasContact)
        assertEquals("pot", watch.at(1.0, hand)?.label)
        assertEquals("active on every frame, not a timed toast", "pot", watch.at(1.1, hand)?.label)
        assertEquals("pot", watch.at(1.3, hand)?.label)
        assertNull("leave: immediately clear", watch.at(1.4))
        assertFalse(watch.hasContact)
        for (time in listOf(1.41, 1.6, 1.8, 2.0, 2.2, 2.4)) assertNull(watch.at(time, hand))
        assertEquals("no six-second cooldown or one-second clearance required", "pot", watch.at(2.42, hand)?.label)
    }

    @Test fun heldAlarmClearsOnLostGeometryStaleFramesAndReset() {
        val hand = HazardWatch.Hand("right", listOf(Point2(0.5, 0.5)))
        for (loss in listOf("geometry", "stale", "reset")) {
            val watch = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 1.0; holdsAlertUntilExit = true }
            for (time in listOf(0.0, 0.2, 0.4, 0.6, 0.8)) assertNull(watch.at(time, hand))
            assertNotNull(watch.at(1.0, hand))
            when (loss) {
                "geometry" -> assertNull(watch.check(listOf(hand), emptyList(), 1.1, 1.1))
                "stale" -> assertNull(watch.check(listOf(hand), listOf(pot), 1.1, 1.5))
                else -> watch.reset()
            }
            assertFalse(watch.hasContact)
            assertNull(loss, watch.at(1.2, hand))
        }
    }

    @Test fun itemBoxParsesGemmaBox2d() {
        val boxes = ItemBox.parse("```json\n[{\"box_2d\": [400, 200, 600, 500], \"label\": \"the pot\"}]\n```")
        assertEquals(1, boxes.size)
        assertEquals("pot", boxes[0].label)
        assertEquals(0.2, boxes[0].x, 1e-9); assertEquals(0.4, boxes[0].y, 1e-9)
        assertEquals(0.3, boxes[0].width, 1e-9); assertEquals(0.2, boxes[0].height, 1e-9)
        assertTrue("whole-image box is Gemma not knowing", ItemBox.parse("{\"box_2d\": [0, 0, 1000, 1000]}").isEmpty())
    }
}
