package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateApkVerifierTest {
    @Test
    fun acceptsSamePackageAndSigner() {
        val installed = identity(current = setOf(certificate(1)))
        val candidate = identity(current = setOf(certificate(1)))

        assertTrue(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun rejectsDifferentPackage() {
        val installed = identity(current = setOf(certificate(1)))
        val candidate = identity(
            packageName = "com.attacker.app",
            current = setOf(certificate(1)),
        )

        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun rejectsDifferentSigner() {
        val installed = identity(current = setOf(certificate(1)))
        val candidate = identity(current = setOf(certificate(2)))

        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun rejectsAnOlderVersionCode() {
        val installed = identity(current = setOf(certificate(1)), versionCode = 10)
        val candidate = identity(current = setOf(certificate(1)), versionCode = 9)

        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun acceptsForwardCertificateRotationProvenByCandidateHistory() {
        val installed = identity(current = setOf(certificate(1)))
        val candidate = identity(
            current = setOf(certificate(2)),
            history = setOf(certificate(1), certificate(2)),
        )

        assertTrue(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun rejectsDowngradeToPastCertificate() {
        val installed = identity(
            current = setOf(certificate(2)),
            history = setOf(certificate(1), certificate(2)),
        )
        val candidate = identity(current = setOf(certificate(1)))

        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, candidate))
    }

    @Test
    fun requiresExactSignerSetForMultiSignedPackages() {
        val installed = identity(
            current = setOf(certificate(1), certificate(2)),
            multipleSigners = true,
        )
        val exactCandidate = identity(
            current = setOf(certificate(2), certificate(1)),
            multipleSigners = true,
        )
        val partialCandidate = identity(
            current = setOf(certificate(1)),
            multipleSigners = true,
        )
        val singleSignerCandidate = identity(current = setOf(certificate(1)))

        assertTrue(UpdateApkVerifier.isTrustedUpdate(installed, exactCandidate))
        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, partialCandidate))
        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, singleSignerCandidate))
    }

    @Test
    fun rejectsMissingSignerMetadata() {
        val installed = identity(current = setOf(certificate(1)))

        assertFalse(
            UpdateApkVerifier.isTrustedUpdate(
                installed,
                identity(current = emptySet(), history = emptySet()),
            ),
        )
        assertFalse(
            UpdateApkVerifier.isTrustedUpdate(
                identity(current = emptySet(), history = emptySet()),
                identity(current = setOf(certificate(1))),
            ),
        )
    }

    @Test
    fun rejectsSignerMetadataWhoseCurrentCertificateIsMissingFromHistory() {
        val installed = identity(current = setOf(certificate(1)))
        val inconsistentCandidate = identity(
            current = setOf(certificate(2)),
            history = setOf(certificate(1)),
        )

        assertFalse(UpdateApkVerifier.isTrustedUpdate(installed, inconsistentCandidate))
    }

    private fun identity(
        packageName: String = "com.ssrvpn.android",
        current: Set<List<Byte>>,
        history: Set<List<Byte>> = current,
        multipleSigners: Boolean = false,
        versionCode: Long = 1,
    ) = UpdateApkIdentity(
        packageName = packageName,
        versionCode = versionCode,
        currentSigners = current,
        signingHistory = history,
        hasMultipleSigners = multipleSigners,
    )

    private fun certificate(value: Byte): List<Byte> = listOf(value)
}
