package ai.deepseek.harness

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AppCompatActivity() {
    private lateinit var webView: WebView
    private lateinit var statusText: TextView
    private lateinit var loadingPanel: View
    private lateinit var retryButton: Button
    private lateinit var ubuntu: UbuntuManager
    private val booting = AtomicBoolean(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.webView)
        statusText = findViewById(R.id.statusText)
        loadingPanel = findViewById(R.id.loadingPanel)
        retryButton = findViewById(R.id.retryButton)
        configureWebView()

        ubuntu = UbuntuManager(this) { message ->
            runOnUiThread { statusText.text = sanitizeStatus(message) }
        }
        retryButton.setOnClickListener { startHarness() }
        installBackHandler()
        startHarness()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = false
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            userAgentString = "$userAgentString DSHion/${BuildConfig.VERSION_NAME} AndroidWebView"
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(webView.settings, true)
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean = true
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                return !isLocalHarnessUrl(request.url.host, request.url.port)
            }

            override fun onPageFinished(view: WebView, url: String) {
                super.onPageFinished(view, url)
                injectMobileUi(view)
                loadingPanel.visibility = View.GONE
                webView.visibility = View.VISIBLE
            }
        }
        webView.visibility = View.INVISIBLE
    }

    private fun isLocalHarnessUrl(host: String?, port: Int): Boolean {
        val local = host == "127.0.0.1" || host == "localhost"
        return local && (port == -1 || port == 3080)
    }

    private fun startHarness() {
        if (!booting.compareAndSet(false, true)) return
        retryButton.visibility = View.GONE
        loadingPanel.visibility = View.VISIBLE
        webView.visibility = View.INVISIBLE
        statusText.text = getString(R.string.status_preparing)

        Thread({
            try {
                ubuntu.prepare()
                ubuntu.startHarness()
                waitForServer("http://127.0.0.1:3080/", 120_000)
                runOnUiThread {
                    webView.loadUrl("http://127.0.0.1:3080/")
                    booting.set(false)
                }
            } catch (t: Throwable) {
                booting.set(false)
                runOnUiThread {
                    statusText.text = "启动失败\n${t.message ?: t.javaClass.simpleName}"
                    retryButton.visibility = View.VISIBLE
                }
            }
        }, "dshion-bootstrap").start()
    }

    private fun waitForServer(url: String, timeoutMs: Long) {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            try {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 1000
                connection.readTimeout = 1000
                connection.instanceFollowRedirects = false
                connection.requestMethod = "GET"
                connection.connect()
                val code = connection.responseCode
                connection.disconnect()
                if (code in 200..499) return
            } catch (_: Throwable) {
                // Service is still booting.
            }
            Thread.sleep(700)
        }
        error("dsh web 未在 120 秒内监听 127.0.0.1:3080")
    }

    private fun injectMobileUi(view: WebView) {
        val css = assets.open("mobile-webview.css").bufferedReader().use { it.readText() }
        val escaped = css
            .replace("\\", "\\\\")
            .replace("`", "\\`")
            .replace("${'$'}{", "\\${'$'}{")
        val js = """
            (() => {
              document.documentElement.classList.add('dshion-android');
              let meta = document.querySelector('meta[name=viewport]');
              if (!meta) {
                meta = document.createElement('meta');
                meta.name = 'viewport';
                document.head.appendChild(meta);
              }
              meta.content = 'width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover,interactive-widget=resizes-content';
              let style = document.getElementById('dshion-mobile-style');
              if (!style) {
                style = document.createElement('style');
                style.id = 'dshion-mobile-style';
                document.head.appendChild(style);
              }
              style.textContent = `$escaped`;
              window.__DSHION_ANDROID__ = true;
            })();
        """.trimIndent()
        view.evaluateJavascript(js, null)
    }

    private fun installBackHandler() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (webView.canGoBack()) webView.goBack() else finish()
            }
        })
    }

    private fun sanitizeStatus(message: String): String {
        return message.replace(Regex("\\x1B\\[[;\\d]*m"), "").takeLast(500)
    }

    override fun onDestroy() {
        ubuntu.stopHarness()
        webView.stopLoading()
        webView.destroy()
        super.onDestroy()
    }
}
