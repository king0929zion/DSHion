package ai.deepseek.harness

import android.content.Context
import android.system.Os
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.xz.XZCompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

class UbuntuManager(
    private val context: Context,
    private val log: (String) -> Unit
) {
    private val rootfs = File(context.filesDir, "ubuntu")
    private val runtimeDir = File(context.filesDir, "runtime")
    private val installedMarker = File(rootfs, ".dshion-installed-v2")
    private var process: Process? = null
    private val stopping = AtomicBoolean(false)

    fun prepare() {
        if (!installedMarker.exists()) {
            log("首次运行：正在部署 Ubuntu 环境…")
            rootfs.deleteRecursively()
            rootfs.mkdirs()
            extractTarXzAsset("ubuntu-rootfs-arm64.tar.xz", rootfs)
            installedMarker.writeText("2")
        }
        prepareRuntimeLibraries()
        ensureRuntimeDirectories()
        log("Ubuntu 环境已就绪")
    }

    private fun prepareRuntimeLibraries() {
        val marker = File(runtimeDir, ".proot-libs-v1")
        if (marker.exists()) return
        runtimeDir.deleteRecursively()
        runtimeDir.mkdirs()
        runCatching { extractTarXzAsset("proot-libs-arm64.tar.xz", runtimeDir) }
            .onFailure { log("未发现额外 PRoot 动态库，将尝试直接启动") }
        marker.writeText("1")
    }

    private fun ensureRuntimeDirectories() {
        listOf("root", "tmp", "var/tmp", "root/.cache", "root/.config", "root/.local/share/dsh")
            .forEach { File(rootfs, it).mkdirs() }
    }

    private fun extractTarXzAsset(assetName: String, destination: File) {
        val input = context.assets.open(assetName)
        TarArchiveInputStream(XZCompressorInputStream(BufferedInputStream(input))).use { tar ->
            var entry = tar.nextTarEntry
            while (entry != null) {
                val out = File(destination, entry.name).canonicalFile
                require(out.path == destination.canonicalPath || out.path.startsWith(destination.canonicalPath + File.separator)) {
                    "非法归档路径: ${entry.name}"
                }
                when {
                    entry.isDirectory -> out.mkdirs()
                    entry.isSymbolicLink -> {
                        out.parentFile?.mkdirs()
                        runCatching { Os.symlink(entry.linkName, out.absolutePath) }
                    }
                    entry.isLink -> {
                        val target = File(destination, entry.linkName).canonicalFile
                        out.parentFile?.mkdirs()
                        if (target.exists()) target.copyTo(out, overwrite = true)
                    }
                    else -> {
                        out.parentFile?.mkdirs()
                        FileOutputStream(out).use { tar.copyTo(it) }
                        if ((entry.mode and 0b001_001_001) != 0) out.setExecutable(true, false)
                    }
                }
                entry = tar.nextTarEntry
            }
        }
    }

    @Synchronized
    fun startHarness() {
        if (process?.isAlive == true) return
        stopping.set(false)
        log("正在启动 DeepSeek Harness…")

        val proot = File(context.applicationInfo.nativeLibraryDir, "libproot.so")
        require(proot.exists()) { "APK 缺少 PRoot ARM64 runtime" }

        val prootTmp = File(context.cacheDir, "proot-tmp").apply { mkdirs() }
        val hostFiles = context.filesDir.absolutePath
        val command = listOf(
            proot.absolutePath,
            "--kill-on-exit", "--link2symlink", "-0",
            "-r", rootfs.absolutePath,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "/storage", "-b", "/sdcard",
            "-b", "$hostFiles:/host-files",
            "-w", "/root",
            "/usr/bin/env", "-i",
            "HOME=/root", "USER=root", "LOGNAME=root",
            "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "TERM=xterm-256color",
            "TMPDIR=/tmp",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "/bin/bash", "-lc",
            "ulimit -n 8192 2>/dev/null || true; mkdir -p /tmp /root/.cache /root/.config; exec dsh web"
        )

        process = ProcessBuilder(command)
            .redirectErrorStream(true)
            .apply {
                environment()["PROOT_TMP_DIR"] = prootTmp.absolutePath
                environment()["LD_LIBRARY_PATH"] = runtimeDir.absolutePath
            }
            .start()

        Thread({
            runCatching {
                process?.inputStream?.bufferedReader()?.forEachLine { line ->
                    if (!stopping.get()) log(line.take(240))
                }
            }
        }, "dshion-proot-log").start()
    }

    @Synchronized
    fun stopHarness() {
        stopping.set(true)
        process?.destroy()
        runCatching { process?.waitFor() }
        process = null
    }
}
