# DSHion

DSHion packages the DeepSeek Harness Web UI as an Android ARM64 application.

## Architecture

`Android WebView -> 127.0.0.1:3080 -> dsh web -> Node.js -> Ubuntu 24.04 ARM64 userspace -> PRoot`

The Android layer stays intentionally thin. Harness remains the source of truth for the application UI and behavior; Android is responsible for bootstrapping the local Linux userspace, lifecycle management, localhost-only WebView navigation, safe-area handling, and phone layout fixes.

## Mobile behavior

- WebView uses the original Harness Web UI rather than a second native UI.
- Safe-area and display-cutout aware edge-to-edge layout.
- 44dp minimum touch targets.
- 16px form controls to avoid unintended WebView zoom.
- Responsive dialog/sidebar/toolbar constraints.
- Horizontal containment for terminal, code, and tables.
- Android back gesture first navigates WebView history.
- External URLs are blocked from loading inside the privileged local WebView.

## Embedded Linux environment

The APK is ARM64-only. On first launch it extracts an Ubuntu 24.04 ARM64 rootfs into app-private storage. The image contains Node.js 22.19.0 and `@deepseek-ai/dsh`.

This is a **PRoot userspace**, not a VM and not a rooted Android environment. It is intended for sideloading/internal distribution. `targetSdk 28` is deliberate because modern Android child-process execution restrictions make this architecture unsuitable for a conventional Play Store release.

## GitHub Actions

`.github/workflows/android.yml` automatically:

1. resolves and packages the current Termux ARM64 PRoot runtime and its dynamic libraries;
2. downloads the current Ubuntu 24.04 ARM64 base filesystem;
3. injects official Node.js 22.19.0 ARM64;
4. installs DeepSeek Harness in the ARM64 rootfs under QEMU/binfmt;
5. builds an installable debug-signed ARM64 APK;
6. uploads the APK and SHA-256 checksum as a GitHub Actions artifact;
7. on `v*` tags, also attaches the APK to a GitHub Release.

The heavy generated runtime is cached by DSH and Node version and is deliberately excluded from Git.

### Manual build workflow

Open **Actions -> Android APK -> Run workflow**. You may optionally provide another published `@deepseek-ai/dsh` version.

### Release

```bash
git tag v0.2.0
git push origin v0.2.0
```

The tag build creates a GitHub Release containing the APK.

## Local build

To reproduce the CI build on Ubuntu x86_64:

```bash
bash ./scripts/prepare-proot.sh "$PWD"
bash ./scripts/prepare-rootfs.sh "$PWD"
gradle assembleDebug
```

Android Studio can build the project once the generated runtime files exist.

## Upstream

DeepSeek Harness: https://github.com/deepseek-ai/deepseek-harness

DSHion does not change the upstream Harness license. Third-party binaries and packages retain their respective licenses.
