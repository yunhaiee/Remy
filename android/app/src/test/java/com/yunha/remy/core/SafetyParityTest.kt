package com.yunha.remy.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// Ports of FingerFlexionTests, HotSurfaceWindowTests, KnifeCurlGateTests, HandContinuityTests, DishAssessmentTests,
// KnifeTrackingTests, FastObjectPresentationTests, ReachTrackerTests and ItemBoxTests (iPhone ChefCore, 1d038b4).

class FingerFlexionTest {
    private fun hand(straight: Set<HandFinger> = HandFinger.entries.toSet()): List<HandPoint3> {
        val points = MutableList(21) { HandPoint3(0.0, 0.0, 0.0) }
        for ((i, finger) in HandFinger.entries.withIndex()) {
            val b = 1 + i * 4; val y = i * 4.0
            points[b] = HandPoint3(0.0, y, 0.0); points[b + 1] = HandPoint3(1.0, y, 0.0)
            points[b + 2] = if (finger in straight) HandPoint3(2.0, y, 0.0) else HandPoint3(1.0, y + 1, 0.0)
            points[b + 3] = if (finger in straight) HandPoint3(3.0, y, 0.0) else HandPoint3(0.0, y + 1, 0.0)
        }
        return points
    }

    @Test fun testStraightAndCurledForAllFiveFingers() {
        assertEquals(listOf(0, 0, 0, 0, 0), FingerFlexion.estimate(hand()).map { it.percent })
        assertEquals(listOf(100, 100, 100, 100, 100), FingerFlexion.estimate(hand(emptySet())).map { it.percent })
    }

    @Test fun testBendIsInvariantToRotationTranslationAndScale() {
        val points = hand(setOf(HandFinger.INDEX, HandFinger.RING))
        val transformed = points.map { HandPoint3(it.z * 0.02 + 8, it.y * 0.02 - 3, -it.x * 0.02 + 1) }
        val a = FingerFlexion.estimate(points); val b = FingerFlexion.estimate(transformed)
        assertEquals(a.map { it.finger }, b.map { it.finger })
        for ((x, y) in a.zip(b)) assertEquals(x.fraction, y.fraction, 0.00001)
    }

    @Test fun testMissingInvalidAndDegenerateGeometryDoesNotCreateValues() {
        assertTrue(FingerFlexion.estimate(emptyList()).isEmpty())
        assertTrue(FingerFlexion.estimate(List(21) { HandPoint3(0.0, 0.0, 0.0) }).isEmpty())
        val points = hand().toMutableList(); points[8] = HandPoint3(Double.NaN, 0.0, 0.0)
        assertNull(FingerFlexion.estimate(points).firstOrNull { it.finger == HandFinger.INDEX })
        assertEquals(4, FingerFlexion.estimate(points).size)
    }

    @Test fun testShortStableHoldProducesSpecificOrGeneralGuidance() {
        for (finger in HandFinger.entries) {
            val watch = FingerCurlWatch()
            watch.update(hand(setOf(finger)), 1.0, 1.0)
            assertNull(watch.guidance)
            watch.update(hand(setOf(finger)), 1.15, 1.15)
            assertEquals("Try curling your ${finger.raw} inward.", watch.guidance)
        }
        val watch = FingerCurlWatch()
        watch.update(hand(setOf(HandFinger.INDEX, HandFinger.MIDDLE)), 1.0, 1.0)
        watch.update(hand(setOf(HandFinger.INDEX, HandFinger.MIDDLE)), 1.15, 1.15)
        assertEquals("Try curling your index and middle inward.", watch.guidance)
        watch.reset()
        watch.update(hand(), 2.0, 2.0)
        watch.update(hand(), 2.15, 2.15)
        assertEquals("Try curling your fingertips inward.", watch.guidance)
    }

    @Test fun testCurlingClearsGuidanceAndStaleOrMissingHandClearsValues() {
        val watch = FingerCurlWatch()
        watch.update(hand(), 1.0, 1.0)
        watch.update(hand(), 1.15, 1.15)
        assertNotNull(watch.guidance)
        watch.update(hand(emptySet()), 1.25, 1.25)
        assertNull(watch.guidance)
        watch.update(hand(), 1.3, 2.0)
        assertTrue(watch.values.isEmpty()); assertNull(watch.guidance)
        watch.update(hand(), 3.0, 3.0)
        watch.update(emptyList(), 3.1, 3.1)
        assertTrue(watch.values.isEmpty())
    }

    @Test fun testTrackingGapRestartsPersistenceAndDuplicateFramesCannotAccumulate() {
        val watch = FingerCurlWatch()
        watch.update(hand(), 1.0, 1.0)
        watch.update(hand(), 1.0, 1.0)
        assertNull(watch.guidance)
        watch.update(hand(), 2.0, 2.0)
        assertNull(watch.guidance)
        watch.update(hand(), 2.15, 2.15)
        assertNotNull(watch.guidance)
    }
}

class HotSurfaceWindowTest {
    private val plan: RecipePlan get() = RecipePlan("A longer generated dish", listOf(Ingredient("pasta", "Pasta", "one box")),
        (1..5).map { RecipeStep(id = "step_$it", title = "Step $it", instruction = "Do step $it.", doneWhen = "Done") })

    @Test fun testWindowSpansAllRemainingStepsRatherThanOnlyThePreset() {
        val session = CookingSession(); session.start(plan)
        assertFalse(session.cookerSafetyArmed)
        session.beginCooking(); assertFalse(session.cookerSafetyArmed)
        for (i in 1 until 5) { session.nextStep(); assertTrue(session.cookerSafetyArmed) }
        session.nextStep(); assertTrue(session.isComplete); assertFalse(session.cookerSafetyArmed)
        session.selectStep(1); assertFalse(session.cookerSafetyArmed)
    }

    @Test fun testSkippingStepOneDoesNotPretendItWasCompleted() {
        val session = CookingSession(); session.start(plan); session.beginCooking()
        session.selectStep(2); assertFalse(session.cookerSafetyArmed)
        session.nextStep(); assertFalse(session.cookerSafetyArmed)
        session.selectStep(0); session.nextStep(); assertTrue(session.cookerSafetyArmed)
    }

    @Test fun testWindowSurvivesPersistenceAndReturningToAnEarlierStep() {
        var session = CookingSession(); session.start(plan); session.beginCooking(); session.nextStep()
        session = CookingSession.fromJson(session.toJson())!!
        assertTrue(session.cookerSafetyArmed)
        session.selectStep(0); assertTrue(session.cookerSafetyArmed)
        session.start(plan); assertFalse(session.cookerSafetyArmed)
    }

    @Test fun testHotHandRuleRemainsIndependentOfCurledKnifeFingers() {
        val hot = HazardWatch().apply { anyPartOverlap = true; minimumContactDuration = 0.0; holdsAlertUntilExit = true }
        val zone = HazardZone("pan", 0.1, 0.1, 0.2, 0.2)
        val hand = HazardWatch.Hand("left", List(21) { Point2(0.2, 0.2) })
        val knife = ItemBox("knife", 0.1, 0.1, 0.2, 0.2)
        val points = (0 until 21).associateWith { Point2(0.2, 0.2) }
        val bends = HandFinger.entries.map { FingerBend(it, 0.6) }
        assertFalse(KnifeHandWatch.overlapsUncurledFinger(knife, points, bends))
        assertNotNull("curled fingers trigger heat caution on the first overlapping frame", hot.check(listOf(hand), listOf(zone), 1.0, 1.0))
        assertNotNull("warning remains active during overlap", hot.check(listOf(hand), listOf(zone), 1.03, 1.03))
        assertNull("exit clears immediately", hot.check(emptyList(), listOf(zone), 1.06, 1.06))
        assertNotNull("fresh reentry has no heat-warning cooldown", hot.check(listOf(hand), listOf(zone), 1.09, 1.09))
    }

    @Test fun testImmediateHotWarningAcceptsAnyPartButRejectsStaleOrUncertainHands() {
        val hot = HazardWatch().apply { anyPartOverlap = true; holdsAlertUntilExit = true }
        val zone = HazardZone("pan", 0.4, 0.4, 0.2, 0.2)
        var points = MutableList(21) { Point2(0.2, 0.2) }
        points[8] = Point2(0.5, 0.5)
        val hand = HazardWatch.Hand("right", points)
        assertNull("stale video cannot trigger a current alarm", hot.check(listOf(hand), listOf(zone), 1.0, 1.4))
        assertNull(hot.check(listOf(HazardWatch.Hand("unknown", points)), listOf(zone), 2.0, 2.0))
        assertNotNull("one fingertip is enough on the first reliable frame", hot.check(listOf(hand), listOf(zone), 2.03, 2.03))
        assertNull(hot.check(listOf(HazardWatch.Hand("right", List(21) { Point2(0.2, 0.2) })), listOf(zone), 2.06, 2.06))
        // A finger segment crossing the box counts even when both endpoints are outside it.
        points = MutableList(21) { Point2(0.2, 0.5) }; points[8] = Point2(0.8, 0.5)
        assertNotNull(hot.check(listOf(HazardWatch.Hand("right", points)), listOf(zone), 2.09, 2.09))
    }

    @Test fun testExpandedSafetyBoundaryMatchesEarlyEntryAndClipsToImage() {
        val detected = HazardZone("pan", 0.3, 0.3, 0.4, 0.2)
        val boundary = detected.expanded(1.2)
        assertEquals(0.48, boundary.width, 1e-9)
        assertEquals(0.24, boundary.height, 1e-9)
        assertEquals(detected.center.x, boundary.center.x, 1e-9)
        assertEquals(detected.center.y, boundary.center.y, 1e-9)
        val hand = HazardWatch.Hand("left", listOf(Point2(0.27, 0.4)))
        val hot = HazardWatch().apply { anyPartOverlap = true; holdsAlertUntilExit = true }
        assertFalse(detected.intersectsHand(hand.points))
        assertNotNull("the displayed expanded boundary is also the trigger boundary", hot.check(listOf(hand), listOf(boundary), 1.0, 1.0))
        val edge = HazardZone("pan", 0.0, 0.0, 0.2, 0.2).expanded(1.2)
        assertEquals(0.0, edge.x, 0.0); assertEquals(0.0, edge.y, 0.0)
        assertEquals(0.22, edge.width, 1e-9)
        assertEquals(0.22, edge.height, 1e-9)
    }
}

class KnifeCurlGateTest {
    private val box = ItemBox("knife", 0.4, 0.4, 0.2, 0.1)
    private val index = mapOf(7 to Point2(0.3, 0.45), 8 to Point2(0.5, 0.45))

    @Test fun testOverlappingFingerStopsWarningAtDisplayedTwentyFivePercent() {
        for (fraction in listOf(0.25, 0.3, 0.4, 0.7, 1.0, 0.246)) {
            assertFalse(KnifeHandWatch.overlapsUncurledFinger(box, index, listOf(FingerBend(HandFinger.INDEX, fraction))))
        }
        assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, index, listOf(FingerBend(HandFinger.INDEX, 0.24))))
    }

    @Test fun testAnotherStraightFingerOutsideBoxCannotOverrideCurledIndex() {
        val points = index.toMutableMap()
        points[19] = Point2(0.1, 0.1); points[20] = Point2(0.2, 0.1)
        val bends = listOf(FingerBend(HandFinger.INDEX, 0.6), FingerBend(HandFinger.PINKY, 0.0))
        assertFalse(KnifeHandWatch.overlapsUncurledFinger(box, points, bends))
        points[19] = Point2(0.4, 0.45); points[20] = Point2(0.5, 0.45)
        assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, points, bends))
    }

    @Test fun testPalmOnlyDoesNotBecomeFingerWarning() {
        assertFalse(KnifeHandWatch.overlapsUncurledFinger(box, mapOf(0 to Point2(0.5, 0.45)), emptyList()))
    }

    @Test fun testMissingCurlDoesNotClaimFingerIsCurled() {
        assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, index, emptyList()))
        assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, index, listOf(FingerBend(HandFinger.INDEX, Double.NaN))))
    }

    @Test fun testCurlingClearsHeldAlarmImmediatelyAndStraighteningRearmsAfterCooldown() {
        val watch = KnifeHandWatch(); val id = "knife-1"
        for ((i, fraction) in listOf(0.1, 0.25, 0.8, 0.2).withIndex()) {
            val overlap = KnifeHandWatch.overlapsUncurledFinger(box, index, listOf(FingerBend(HandFinger.INDEX, fraction)))
            val t = listOf(1.0, 1.1, 1.2, 2.2)[i]
            assertEquals(fraction < 0.25, watch.update(id, box, if (overlap) listOf(index) else emptyList(), t, t))
        }
    }

    @Test fun testThresholdAppliesIndependentlyToAllFiveFingers() {
        for ((i, finger) in HandFinger.entries.withIndex()) {
            val b = 1 + i * 4
            val points = mapOf(b + 2 to Point2(0.3, 0.45), b + 3 to Point2(0.5, 0.45))
            val threshold = if (finger == HandFinger.THUMB) 0.1 else 0.25
            assertFalse(KnifeHandWatch.overlapsUncurledFinger(box, points, listOf(FingerBend(finger, threshold))))
            assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, points, listOf(FingerBend(finger, threshold - 0.01))))
        }
    }

    @Test fun testRelaxedThumbNoLongerWarnsAtFifteenPercentCurl() {
        val thumb = mapOf(3 to Point2(0.3, 0.45), 4 to Point2(0.5, 0.45))
        assertFalse(KnifeHandWatch.overlapsUncurledFinger(box, thumb, listOf(FingerBend(HandFinger.THUMB, 0.15))))
        assertTrue(KnifeHandWatch.overlapsUncurledFinger(box, thumb, listOf(FingerBend(HandFinger.THUMB, 0.09))))
    }
}

class HandContinuityTest {
    private fun hand(id: String = "left", x: Double = 0.3) =
        HandDisplayPose(id, (0 until 21).associateWith { Point2(x + (it % 4) * 0.01, 0.3 + (it / 4) * 0.01) })

    @Test fun testBriefDropoutCoastsThenExpiresWithoutInventingAnObservation() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0)
        val observed = tracker.update(listOf(hand("left", 0.32)), 1.04)
        assertFalse(observed[0].estimated)
        val estimated = tracker.update(emptyList(), 1.08)
        assertEquals(1, estimated.size); assertTrue(estimated[0].estimated)
        assertEquals(0.04, estimated[0].observationAge, 0.00001)
        assertTrue(estimated[0].points[0]!!.x > observed[0].points[0]!!.x)
        assertTrue(tracker.update(emptyList(), 1.25).isEmpty())
    }

    @Test fun testSingleUnconfirmedDetectionCannotCreateAGhostHand() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0)
        assertTrue(tracker.update(emptyList(), 1.04).isEmpty())
    }

    @Test fun testPredictedPoseCannotBeFedBackAsMeasuredEvidence() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0); tracker.update(listOf(hand()), 1.04)
        val estimated = tracker.update(emptyList(), 1.08)
        val next = tracker.update(estimated, 1.12)
        assertEquals(0.08, next[0].observationAge, 0.00001)
        assertTrue(next[0].estimated)
        assertTrue(tracker.update(next, 1.26).isEmpty())
    }

    @Test fun testUnknownHandednessKeepsDisplayIdentityWithoutChangingInput() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0); tracker.update(listOf(hand()), 1.04)
        val raw = hand("unknown", 0.31)
        val output = tracker.update(listOf(raw), 1.08)
        assertEquals("left", output[0].id); assertEquals("unknown", raw.id)
        assertFalse(output[0].estimated)
    }

    @Test fun testReacquisitionAndSourceResetDoNotCarryOldPredictions() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0); tracker.update(listOf(hand()), 1.04)
        tracker.update(emptyList(), 1.08)
        val restored = tracker.update(listOf(hand("left", 0.65)), 1.12)
        assertFalse(restored[0].estimated); assertEquals(0.65, restored[0].points[0]!!.x, 0.00001)
        tracker.reset(); assertTrue(tracker.update(emptyList(), 2.0).isEmpty())
    }

    @Test fun testAtMostTwoHandsAndNoCrossHandDuplicateAssignment() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand("left", 0.2), hand("right", 0.7)), 1.0)
        tracker.update(listOf(hand("left", 0.2), hand("right", 0.7)), 1.04)
        val result = tracker.update(listOf(hand("unknown", 0.21), hand("unknown", 0.71)), 1.08)
        assertEquals(setOf("left", "right"), result.map { it.id }.toSet())
        assertEquals(2, result.size)
        assertTrue(tracker.update(listOf(hand("unknown", 0.45)), 1.12).size <= 2)
    }

    @Test fun testMalformedAndRepeatedTimesCannotRefreshExpiredEvidence() {
        val tracker = HandContinuity()
        tracker.update(listOf(hand()), 1.0)
        assertTrue(tracker.update(listOf(hand()), 1.0).isEmpty())
        val bad = HandDisplayPose("left", mapOf(0 to Point2(Double.NaN, 0.0)))
        assertTrue(tracker.update(listOf(bad), 1.03).isEmpty())
        assertTrue(tracker.update(emptyList(), Double.NaN).isEmpty())
    }
}

class DishAssessmentTest {
    private fun json(stars: Double = 4.5) =
        """{"dishVisible":true,"stars":$stars,"summary":"Visible pasta salad.","ingredientBalance":"Pasta leads.","cutConsistency":"Some pieces differ.","portionPresentation":"Bowl partly filled.","improvements":"Dice more evenly."}"""

    @Test fun testRatingsAndFences() {
        for (score in listOf(0.0, 2.5, 5.0)) assertEquals(score, DishAssessment.decode("```json\n" + json(score) + "\n```").stars, 0.0)
    }

    @Test fun testInvalidAndIncompleteReportsAreRejected() {
        for (score in listOf(-1.0, 5.1)) assertThrows(Exception::class.java) { DishAssessment.decode(json(score)) }
        assertThrows(Exception::class.java) { DishAssessment.decode(json().replace("Pasta leads.", "")) }
        assertThrows(Exception::class.java) { DishAssessment.decode("{}") }
    }

    @Test fun testNoDishCanBeReportedWithoutPretendingItWasVisible() {
        assertFalse(DishAssessment.decode(json(0.0).replace("true", "false")).dishVisible)
    }

    @Test fun testReadyDeclarationsDoNotMatchQuestionsOrNegations() {
        for (text in listOf("ready", "I'm ready", "It’s ready!", "I'm done mixing", "Okay ready now", "Here is my dish it is ready")) {
            assertTrue(text, DishReadySignal.matches(text))
        }
        for (text in listOf("not ready", "almost ready", "is it ready?", "I'm not ready", "ready when you are?", "I am ready but wait", "how do I know it's ready")) {
            assertFalse(text, DishReadySignal.matches(text))
        }
    }

    @Test fun testNonDishCannotReceiveAnInventedRating() {
        assertThrows(Exception::class.java) { DishAssessment.decode(json(4.0).replace("true", "false")) }
    }

    @Test fun testEvidenceRequiresEveryObservationAndExplicitUncertainty() {
        val valid = """{"dishVisible":true,"ingredients":"Pasta and red pieces visible.","cuts":"Uneven cubes.","presentation":"Bowl half full.","uncertainty":"Lemon juice cannot be seen."}"""
        assertTrue(DishPhotoEvidence.decode(valid).dishVisible)
        assertThrows(Exception::class.java) { DishPhotoEvidence.decode(valid.replace("Uneven cubes.", "")) }
        assertThrows(Exception::class.java) { DishPhotoEvidence.decode("{}") }
    }

    @Test fun testOverlongReviewIsRejectedRatherThanClippedOnScreen() {
        val tooLong = List(36) { "word" }.joinToString(" ")
        assertThrows(Exception::class.java) { DishAssessment.decode(json().replace("Pasta leads.", tooLong)) }
    }
}

class KnifeTrackingTest {
    private fun knife(x: Double = 0.2, y: Double = 0.4, w: Double = 0.3, h: Double = 0.04) = ItemBox("knife", x, y, w, h)

    @Test fun testKnifeLabelAndGeometryValidation() {
        assertTrue(KnifeAssociation.isKnife("chef's knife"))
        assertTrue(KnifeAssociation.isKnife("knives"))
        for (label in listOf("fork", "spoon", "knifeholder", "knife_edge_prediction")) assertFalse(label, KnifeAssociation.isKnife(label))
        assertTrue(KnifeAssociation.valid(knife()))
        assertFalse(KnifeAssociation.valid(knife(-0.1)))
        assertFalse(KnifeAssociation.valid(knife(Double.NaN)))
        assertFalse(KnifeAssociation.valid(knife(w = 0.0)))
        assertFalse(KnifeAssociation.valid(knife(0.0, 0.0, 1.0, 1.0)))
    }

    @Test fun testStrongCandidateCanSeedImmediatelyButWeakNeedsThreeFreshConsistentFrames() {
        val gate = KnifeCandidateGate()
        assertTrue(gate.accepts(KnifeCandidate(knife(), 0.6), 1.0))
        gate.reset()
        assertFalse(gate.accepts(KnifeCandidate(knife(), 0.3), 2.0))
        assertFalse(gate.accepts(KnifeCandidate(knife(0.21), 0.3), 2.1))
        assertTrue(gate.accepts(KnifeCandidate(knife(0.22), 0.3), 2.2))
    }

    @Test fun testWeakCandidateCannotAccumulateAcrossGapsOtherTargetsOrRepeatedFrames() {
        val gate = KnifeCandidateGate()
        assertFalse(gate.accepts(KnifeCandidate(knife(), 0.3), 1.0))
        assertFalse(gate.accepts(KnifeCandidate(knife(), 0.3), 1.0))
        assertFalse(gate.accepts(KnifeCandidate(knife(), 0.3), 1.1))
        assertFalse(gate.accepts(KnifeCandidate(knife(), 0.3), 2.0))
        assertFalse(gate.accepts(KnifeCandidate(knife(0.7), 0.3), 2.1))
        assertFalse(gate.accepts(KnifeCandidate(knife(0.7), 0.1), 2.2))
        assertFalse(gate.accepts(KnifeCandidate(knife(0.7), 0.3), 2.3))
    }

    @Test fun testReDetectionKeepsCurrentIdentityRatherThanSwitchingToHigherScoringFarKnife() {
        val current = knife()
        val matching = KnifeCandidate(knife(0.21), 0.6)
        val other = KnifeCandidate(knife(0.7, 0.1, 0.2, 0.03), 0.99)
        assertEquals(matching.box, KnifeAssociation.select(listOf(other, matching), current)?.box)
        assertNull(KnifeAssociation.select(listOf(other), current))
        assertEquals(other.box, KnifeAssociation.select(listOf(other, matching), null)?.box)
    }

    @Test fun testRotationAndModerateMotionCanMatchButExplodingBoxesCannot() {
        assertTrue(KnifeAssociation.matches(knife(0.3, 0.3, 0.04, 0.3), knife()))
        assertTrue(KnifeAssociation.matches(knife(0.24), knife()))
        assertFalse(KnifeAssociation.matches(knife(0.0, 0.0, 0.9, 0.9), knife()))
        assertFalse(KnifeAssociation.matches(knife(0.7, 0.8, 0.2, 0.03), knife()))
    }

    @Test fun testAnyLandmarkOrFingerSegmentCounts() {
        val box = knife(0.4, 0.4, 0.2, 0.2)
        for (index in 0 until 21) assertTrue(KnifeHandWatch.overlaps(box, mapOf(index to Point2(0.5, 0.5))))
        assertTrue(KnifeHandWatch.overlaps(box, mapOf(5 to Point2(0.3, 0.5), 6 to Point2(0.7, 0.5))))
        assertFalse(KnifeHandWatch.overlaps(box, mapOf(7 to Point2(0.3, 0.3), 8 to Point2(0.7, 0.3))))
        assertFalse(KnifeHandWatch.overlaps(box, mapOf(0 to Point2(Double.NaN, 0.5))))
        assertFalse(KnifeHandWatch.overlaps(box, emptyMap()))
    }

    @Test fun testPalmInteriorCountsWithoutEdgeCrossing() {
        val palm = mapOf(0 to Point2(0.5, 0.7), 5 to Point2(0.3, 0.4), 9 to Point2(0.4, 0.3), 13 to Point2(0.6, 0.3), 17 to Point2(0.7, 0.4))
        assertTrue(KnifeHandWatch.overlaps(knife(0.48, 0.48, 0.04, 0.04), palm))
        assertFalse(KnifeHandWatch.overlaps(knife(0.1, 0.1, 0.04, 0.04), palm))
    }

    @Test fun testOnlyOneConfidentLeftHandIsEligible() {
        assertTrue(KnifeHandWatch.eligibleHand("left", listOf("right", "left")))
        assertFalse(KnifeHandWatch.eligibleHand("right", listOf("right", "left")))
        assertFalse(KnifeHandWatch.eligibleHand("unknown", listOf("unknown")))
        assertFalse(KnifeHandWatch.eligibleHand("left", listOf("left", "left")))
    }

    @Test fun testImmediateEntryHeldAlertExitAndOneSecondReentryCooldown() {
        val watch = KnifeHandWatch(); val id = "k"; val box = knife()
        val hand = mapOf(0 to Point2(0.3, 0.42))
        assertTrue(watch.update(id, box, listOf(hand), 1.0, 1.0))
        assertTrue(watch.alertActive)
        assertTrue(watch.update(id, box, listOf(hand), 1.1, 1.1))
        assertFalse(watch.update(id, box, emptyList(), 1.2, 1.2))
        assertFalse(watch.alertActive); assertFalse(watch.hasContact)
        assertFalse(watch.update(id, box, listOf(hand), 1.3, 1.3))
        assertTrue(watch.update(id, box, listOf(hand), 2.2, 2.2))
    }

    @Test fun testStaleAndInvalidEvidenceClearAlert() {
        val watch = KnifeHandWatch(); val id = "k"; val hand = mapOf(0 to Point2(0.3, 0.42))
        assertTrue(watch.update(id, knife(), listOf(hand), 1.0, 1.0))
        assertFalse(watch.update(id, knife(), listOf(hand), 1.1, 2.0))
        assertFalse(watch.alertActive)
        assertTrue(watch.update(id, knife(), listOf(hand), 3.0, 3.0))
        assertFalse(watch.update(id, knife(Double.NaN), listOf(hand), 3.1, 3.1))
        watch.reset(); assertFalse(watch.hasContact); assertFalse(watch.alertActive)
    }

    @Test fun testCooldownSurvivesTrackingRecoveryWithoutHoldingOldAlert() {
        val watch = KnifeHandWatch(); val id = "k"; val hand = mapOf(8 to Point2(0.3, 0.42))
        assertTrue(watch.update(id, knife(), listOf(hand), 1.0, 1.0))
        watch.clearContact(1.1); assertFalse(watch.alertActive)
        assertFalse(watch.update(id, knife(), listOf(hand), 1.2, 1.2))
        watch.clearContact(1.3)
        assertFalse(watch.update(id, knife(), listOf(hand), 2.0, 2.0))
        assertTrue(watch.update(id, knife(), listOf(hand), 2.1, 2.1))
        assertFalse(watch.update(id, knife(), emptyList(), 2.11, 2.11))
        assertFalse(watch.alertActive)
    }
}

class FastObjectPresentationTest {
    @Test fun testGenericFoodGuessesCannotBecomeSpecificIngredientIdentity() {
        for (label in listOf("banana", "apple", "orange", "broccoli", "carrot", " BANANA ")) {
            assertEquals("Produce", FastObjectPresentation.displayLabel(label))
            assertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
        for (label in listOf("sandwich", "hot dog", "pizza", "donut", "cake")) {
            assertEquals("Food", FastObjectPresentation.displayLabel(label))
            assertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
        for (label in listOf("  ", "Produce", "Food")) assertFalse(FastObjectPresentation.isSpecificIdentityReliable(label))
    }

    @Test fun testPresentationNeverFabricatesARecipeIngredientOrChangesGeometry() {
        val bananaGuess = ItemBox("banana", 0.1, 0.2, 0.3, 0.4)
        val display = FastObjectPresentation.displayBox(bananaGuess)
        assertEquals("Produce", display.label)
        assertNotEquals("cucumber", display.label)
        assertEquals(bananaGuess.x, display.x, 0.0); assertEquals(bananaGuess.y, display.y, 0.0)
        assertEquals(bananaGuess.width, display.width, 0.0); assertEquals(bananaGuess.height, display.height, 0.0)
        assertEquals("raw evidence remains unchanged", "banana", bananaGuess.label)
    }

    @Test fun testNonFoodLabelsRetainTheirGenericDetectorCategory() {
        for (label in listOf("knife", "bowl", "cup", "microwave")) {
            assertEquals(label, FastObjectPresentation.displayLabel(label))
            assertTrue(FastObjectPresentation.isSpecificIdentityReliable(label))
        }
    }
}

class ReachTrackerTest {
    @Test fun testReachTriggersBeforeEntryButNotBeforeSaltingOrMovingAway() {
        val zone = GuardZone(Point2(0.7, 0.5), 0.1)
        val reach = ReachTracker()
        assertFalse(reach.update(Point2(0.3, 0.5), 1.0, zone, true))
        assertTrue(reach.update(Point2(0.4, 0.5), 1.1, zone, true))
        assertFalse(reach.update(Point2(0.5, 0.5), 1.2, zone, true))
        val unarmed = ReachTracker()
        unarmed.update(Point2(0.3, 0.5), 1.0, zone, false)
        assertFalse(unarmed.update(Point2(0.4, 0.5), 1.1, zone, false))
        val away = ReachTracker()
        away.update(Point2(0.4, 0.5), 1.0, zone, true)
        assertFalse(away.update(Point2(0.3, 0.5), 1.1, zone, true))
    }

    @Test fun testLostOrStaleHandCannotCreateFalseVelocity() {
        val reach = ReachTracker(); val zone = GuardZone(Point2(0.7, 0.5))
        reach.update(Point2(0.3, 0.5), 1.0, zone, true)
        assertFalse(reach.update(null, 1.1, zone, true))
        assertFalse(reach.update(Point2(0.5, 0.5), 1.2, zone, true))
        assertFalse(reach.update(Point2(0.6, 0.5), 4.0, zone, true))
    }
}

class ItemBoxTest {
    @Test fun testParsesGemmaBoxes() {
        val reply = "```json\n[\n  {\"box_2d\": [454, 192, 706, 333], \"label\": \"the cucumber\"}\n]\n```"
        val box = ItemBox.parse(reply).first()
        assertEquals("cucumber", box.label)
        assertEquals(0.192, box.x, 0.001); assertEquals(0.454, box.y, 0.001)
        assertEquals(0.141, box.width, 0.001); assertEquals(0.252, box.height, 0.001)
    }

    @Test fun testSeveralSingleAndNone() {
        assertEquals(2, ItemBox.parse("""[{"box_2d":[1,2,3,4],"label":"a"},{"box_2d":[10,20,30,40]}]""").size)
        assertEquals("knife", ItemBox.parse("""{"box_2d":[100,100,500,500],"label":"knife"}""").first().label)
        assertEquals(emptyList<ItemBox>(), ItemBox.parse("I did not find any bounding box detections for avocado."))
        assertEquals("whole image means unknown", emptyList<ItemBox>(), ItemBox.parse("""[{"box_2d":[0,0,1000,1000],"label":"the bowl"}]"""))
    }
}
