"""
app.py
------
Target Flask web application for the DevSecOps pipeline demo.

IMPORTANT (READ FIRST):
This application intentionally contains a small number of well-known,
clearly-commented vulnerability patterns. They exist so that the security
gates in the CI/CD pipeline (CodeQL, Snyk, Trivy, OWASP ZAP) have real
findings to catch, demonstrating that the pipeline actually works rather
than passing trivially on a "hello world" app. Each intentional weakness
is flagged with a "VULNERABLE-BY-DESIGN" comment and cross-referenced in
the README's "Security Findings Examples" section, including the fix.

Do not deploy this file's vulnerable endpoint as-is in a real product.
"""

import os
import socket
import subprocess  # noqa: S404 - required for the intentionally vulnerable demo endpoint

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

# SECURITY DECISION: Flask's SECRET_KEY must never be hardcoded in source.
# We read it from an environment variable injected at deploy time via
# GitHub Actions secrets -> Terraform -> EC2 user-data / systemd
# EnvironmentFile. If the variable is absent (e.g. local dev), we fail
# closed with a loud error rather than silently using a weak default,
# which is itself a common CWE-798 (hardcoded credentials) finding.
app.config["SECRET_KEY"] = os.environ.get("FLASK_SECRET_KEY")
if not app.config["SECRET_KEY"]:
    raise RuntimeError(
        "FLASK_SECRET_KEY is not set. Refusing to start with a missing "
        "or default secret key (see README > Supply Chain & Secrets)."
    )


@app.route("/")
def index():
    """Landing page. Renders a static template only - no user input reflected."""
    return render_template("index.html")


@app.route("/healthz")
def healthz():
    """
    Liveness/readiness probe used by the container HEALTHCHECK and by
    load balancer target group health checks in the Terraform EC2 module.
    Intentionally returns no sensitive information (no stack traces,
    versions, or internal hostnames) to avoid information disclosure.
    """
    return jsonify(status="ok"), 200


@app.route("/lookup")
def lookup():
    """
    Resolve a hostname to an IP address using Python's own resolver.

    SECURITY DECISION: This is the SAFE version of a "network diagnostics"
    feature. It uses socket.gethostbyname() - a library call, not a shell
    command - so user input can never reach an OS shell. Compare this to
    the intentionally vulnerable /diagnostics endpoint below, which is
    kept only to give the SAST/DAST tools something real to catch.
    """
    host = request.args.get("host", "")
    if not host or len(host) > 253:
        return jsonify(error="A valid 'host' query parameter is required"), 400
    try:
        ip_address = socket.gethostbyname(host)
    except socket.gaierror:
        return jsonify(error="Could not resolve host"), 422
    return jsonify(host=host, ip_address=ip_address)


@app.route("/diagnostics")
def diagnostics():
    """
    VULNERABLE-BY-DESIGN (CWE-78: OS Command Injection).

    This endpoint shells out to `ping` using untrusted, attacker-controlled
    input concatenated directly into a shell command string. It is left in
    the codebase on purpose so that:
      - CodeQL's SAST query `py/command-line-injection` flags it during
        the "CodeQL SAST scan" pipeline stage.
      - OWASP ZAP's active scan can additionally confirm exploitability
        at runtime during the DAST stage against the running container.

    See README.md > "Security Findings Examples" for the actual Snyk/
    CodeQL/Trivy output this produces and the remediation (replace with
    the /lookup implementation above, which never touches a shell).

    DO NOT copy this pattern into production code.
    """
    host = request.args.get("host", "127.0.0.1")
    # VULNERABLE-BY-DESIGN: shell=True + string interpolation of user input.
    command = f"ping -c 1 {host}"
    result = subprocess.run(  # noqa: S602 - intentional, see docstring above
        command, shell=True, capture_output=True, text=True, timeout=5
    )
    return jsonify(command=command, output=result.stdout, error=result.stderr)


if __name__ == "__main__":
    # SECURITY DECISION: debug mode and host binding are controlled by
    # environment variables so that production (systemd/container) always
    # runs with debug=False. Flask's debugger exposes a Werkzeug console
    # that allows arbitrary code execution if left on in production
    # (CWE-489: Active Debug Code) - a classic Snyk/Bandit finding.
    debug_mode = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="127.0.0.1", port=5000, debug=debug_mode)
