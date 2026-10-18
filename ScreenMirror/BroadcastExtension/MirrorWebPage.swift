/// The page a browser gets at http://<phone-ip>:8080 — the live screen, full-window.
enum MirrorWebPage {
    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Screen Mirror</title>
    <style>
      html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
      img { width: 100%; height: 100%; object-fit: contain; display: block; }
      #hint { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%);
              font: 14px -apple-system, system-ui, sans-serif; color: #ccc;
              background: rgba(0,0,0,.6); padding: 8px 14px; border-radius: 8px;
              transition: opacity 1s; }
    </style>
    </head>
    <body>
    <img id="screen" alt="Phone screen">
    <div id="hint">Click to go full screen</div>
    <script>
      const img = document.getElementById('screen');
      function connect() { img.src = '/mjpeg?t=' + Date.now(); }
      img.onerror = () => setTimeout(connect, 1000);
      document.body.onclick = () => {
        const el = document.documentElement;
        (el.requestFullscreen || el.webkitRequestFullscreen || function () {}).call(el);
      };
      setTimeout(() => { document.getElementById('hint').style.opacity = 0; }, 4000);
      connect();
    </script>
    </body>
    </html>
    """
}
