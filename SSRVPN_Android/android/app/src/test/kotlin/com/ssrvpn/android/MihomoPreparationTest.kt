package com.ssrvpn.android

import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class MihomoPreparationTest {
    private fun deadline() = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)

    @Test fun `failed preparation never selects a node`() {
        val result = prepareMihomoForVpn(9090, "fixture", deadline(),
            prepareBridge = { "parse config: fixture" }, ensureCurrent = {},
            selectNode = { fail("failed preparation selected a node") },
            waiter = MihomoApiWaiter { _, _, _ -> error("failed preparation probed API") })
        assertEquals(NativeCoreStartFailureCategory.COMPONENT, result?.category)
    }

    @Test fun `selection follows prepared rule readiness`() {
        val events = mutableListOf<String>()
        val result = prepareMihomoForVpn(9090, "fixture", deadline(),
            prepareBridge = { events.add("prepare"); "" }, ensureCurrent = {},
            selectNode = { events.add("select") },
            waiter = MihomoApiWaiter { _, _, _ -> events.add("ready"); MihomoApiReadiness.READY })
        assertEquals(null, result)
        assertEquals(listOf("prepare", "ready", "select"), events)
    }

    @Test fun `cancellation after preparation does not select or commit`() {
        var canceled = false
        try {
            prepareMihomoForVpn(9090, "fixture", deadline(),
                prepareBridge = { canceled = true; "" },
                ensureCurrent = { if (canceled) throw InterruptedException("fixture") },
                selectNode = { fail("canceled preparation selected a node") })
            fail("cancellation was swallowed")
        } catch (_: InterruptedException) { }
    }

    @Test fun `expired preparation budget rejects the commit`() {
        try {
            requireVpnStartupBudget(System.nanoTime() - 1)
            fail("expired budget allowed commit")
        } catch (_: java.util.concurrent.TimeoutException) { }
    }
}
