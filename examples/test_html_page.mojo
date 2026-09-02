comptime test_html_page = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Test page</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #232332;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .container {
            background-color: white;
            padding: 40px;
            border-radius: 16px;
            box-shadow: 0 8px 24px rgba(0,0,0,0.1);
            text-align: center;
            max-width: 500px;
        }
        h1 {
            color: #2c3e50;
        }
        p {
            color: #555;
            font-size: 18px;
        }
        .status {
            display: inline-block;
            background-color: #27ae60;
            color: white;
            padding: 8px 20px;
            border-radius: 20px;
            font-weight: bold;
            margin-top: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Mojelly🍇</h1>
        <p>This is test HTML-page</p>
        <p>If you see this, everything works!</p>
        <div class="status">Status: OK</div>
        <p style="margin-top: 25px; font-size: 14px; color: #999;">
            Generated: <span id="date"></span>
        </p>
    </div>

    <script>
        document.getElementById('date').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
"""
