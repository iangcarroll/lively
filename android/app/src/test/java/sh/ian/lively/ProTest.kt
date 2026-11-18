package sh.ian.lively

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import sh.ian.lively.model.Pro

class ProTest {
    @Test fun yearlySavingIsRoundedDown() {
        // $39.99 a year against $4.99 a month saves 33.2%.
        assertEquals("Save 33%", Pro.savingBadge(yearlyMicros = 39_990_000, monthlyMicros = 4_990_000))
        // 33.9% is still 33%: the badge never overstates.
        assertEquals("Save 33%", Pro.savingBadge(yearlyMicros = 79_320_000, monthlyMicros = 10_000_000))
        assertEquals("Save 50%", Pro.savingBadge(yearlyMicros = 60_000_000, monthlyMicros = 10_000_000))
    }

    @Test fun smallSavingsGetNoBadge() {
        // 4.9%.
        assertNull(Pro.savingBadge(yearlyMicros = 114_100_000, monthlyMicros = 10_000_000))
        assertEquals("Save 5%", Pro.savingBadge(yearlyMicros = 114_000_000, monthlyMicros = 10_000_000))
    }

    @Test fun noBadgeWithoutASaving() {
        assertNull(Pro.savingBadge(yearlyMicros = 120_000_000, monthlyMicros = 10_000_000))
        assertNull(Pro.savingBadge(yearlyMicros = 150_000_000, monthlyMicros = 10_000_000))
    }

    @Test fun noBadgeWithoutAMonthlyPrice() {
        assertNull(Pro.savingBadge(yearlyMicros = 39_990_000, monthlyMicros = 0))
        assertNull(Pro.savingBadge(yearlyMicros = 39_990_000, monthlyMicros = -1))
    }
}
