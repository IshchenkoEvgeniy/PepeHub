# Android signing key and its rotation (APK Signature Scheme v3).
#
# Releases up to the rotation are signed only with the original project key.
# After `.local\android-signing\use-new-key` exists, every APK is re-signed:
#   * Android 9+ (API 28+) sees the new key plus a lineage signed by the old key,
#     so installed copies accept it as an update;
#   * Android 7-8 keep seeing the original key (they do not support rotation).
# Never remove the marker after a rotated release has been published: devices
# that already moved to the new key cannot go back to the old one.
# See docs\BUILD_AND_RELEASE.md, section "Android signing key rotation".

$pepeOldSignerDigest = 'efeaed93980f9275749f27ec3b663b2f477984375ad3014e44d07c7a0048a620'
$pepeNewSignerDigest = '3db741141f86826ef377cc4816ff4bf43a72ee1f5e80289e13cfb35f31bc4f55'

function Get-PepeSigningRoot([string]$Root) { Join-Path $Root '.local\android-signing' }

function Test-PepeKeyRotation([string]$Root) {
    Test-Path -LiteralPath (Join-Path (Get-PepeSigningRoot $Root) 'use-new-key') -PathType Leaf
}

function Invoke-PepeKeyRotationSigning([string]$Root, [string]$Apk) {
    $signing = Get-PepeSigningRoot $Root
    foreach ($name in @('pepehub-release.p12', 'pepehub-release.pass', 'rotation.lineage')) {
        if (-not (Test-Path -LiteralPath (Join-Path $signing $name) -PathType Leaf)) {
            throw "Key rotation is enabled but .local\android-signing\$name is missing. Restore it from the key backup."
        }
    }
    $oldKey = Join-Path $Root '.tools\android-user\debug.keystore'
    if (-not (Test-Path -LiteralPath $oldKey -PathType Leaf)) { throw 'The original Android signing key is missing.' }
    $apksigner = Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat'
    $signed = "$Apk.rotated.apk"
    if (Test-Path -LiteralPath $signed) { Remove-Item -LiteralPath $signed -Force }
    & $apksigner sign --in $Apk --out $signed --v4-signing-enabled false `
        --ks $oldKey --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android `
        --next-signer --ks (Join-Path $signing 'pepehub-release.p12') `
        --ks-pass "file:$(Join-Path $signing 'pepehub-release.pass')" --ks-key-alias pepehub `
        --lineage (Join-Path $signing 'rotation.lineage') --rotation-min-sdk-version 28
    if ($LASTEXITCODE -ne 0) { throw 'APK signing with the rotated key failed' }
    Move-Item -LiteralPath $signed -Destination $Apk -Force
}

# Throws unless the APK carries exactly the signature this project expects now.
function Assert-PepeApkSigner([string]$Root, [string]$Apk) {
    $apksigner = Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat'
    if (Test-PepeKeyRotation $Root) {
        $legacy = (& $apksigner verify --print-certs --min-sdk-version 24 --max-sdk-version 27 $Apk) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed (Android 7-8)' }
        $modern = (& $apksigner verify --print-certs --min-sdk-version 28 $Apk) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed (Android 9+)' }
        if ($legacy -notmatch "certificate SHA-256 digest: $pepeOldSignerDigest") {
            throw 'Rotated APK must keep the original signer for Android 7-8'
        }
        if ($modern -notmatch "certificate SHA-256 digest: $pepeNewSignerDigest") {
            throw 'Rotated APK must be signed with the new PepeHub key for Android 9+'
        }
    } else {
        $all = (& $apksigner verify --print-certs $Apk) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed' }
        # Existing installations use the project-local key, not the user's global debug key.
        if ($all -notmatch "certificate SHA-256 digest: $pepeOldSignerDigest") {
            throw 'APK signer differs from the previously distributed PepeHub builds'
        }
    }
}
