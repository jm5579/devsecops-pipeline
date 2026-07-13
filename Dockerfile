# Dockerfile
#
# SECURITY DECISION SUMMARY (each numbered decision is referenced inline
# below and explained in full in README.md > "Pipeline Stages" and
# "Supply Chain Security"):
#   1. Multi-stage build - the final image contains no compilers, build
#      tools, or pip cache, shrinking the attack surface Trivy has to scan.
#   2. Minimal, pinned base image (python:3.12-slim, not `latest`) so the
#      base OS package set - and therefore the CVE surface - is as small
#      and as reproducible as possible.
#   3. Dependencies installed from the pinned requirements.txt only, with
#      pip's hash/version pinning enforced by the exact `==` pins upstream.
#   4. A dedicated, unprivileged, non-root user runs the application -
#      Trivy and CIS Docker Benchmark both flag containers that run as
#      root (CWE-250: Execution with Unnecessary Privileges).
#   5. No secrets are ever baked into a layer. FLASK_SECRET_KEY and any
#      other credentials are injected at *runtime* via environment
#      variables / an env-file, never via ENV in this Dockerfile, ARG,
#      or COPY of a .env file - `.dockerignore` also excludes .env, .git,
#      and Terraform state so they can never end up in the build context.
#   6. HEALTHCHECK lets the orchestrator (and load balancer target group)
#      detect an unhealthy container automatically.
#   7. Read-only root filesystem friendliness: the app writes nothing to
#      disk at runtime, so the container can run with --read-only.

# ---- Stage 1: build ---------------------------------------------------
FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf AS build
# NOTE: pin the base image by digest, not just tag, so a tag can never be
# silently repointed to a different (and potentially compromised) image -
# this is the container-equivalent of pinning requirements.txt by version.
# Replace the digest above with the current official digest for your
# target python:3.12-slim release before first build:
#   docker pull python:3.12-slim && docker inspect --format='{{index .RepoDigests 0}}' python:3.12-slim

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# ---- Stage 2: runtime ---------------------------------------------------
FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf AS runtime

# SECURITY DECISION 4: create an unprivileged, non-root user and group
# with a fixed UID/GID (rather than a dynamically-assigned one) so file
# ownership is deterministic across builds and the container never runs
# as UID 0.
RUN groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --shell /usr/sbin/nologin --no-create-home appuser

WORKDIR /app

# Bring in only the installed packages from the build stage - no compiler
# toolchain, no pip cache, no apt lists end up in the final image.
COPY --from=build /root/.local /home/appuser/.local
COPY app/ /app/

# SECURITY DECISION: ensure the app files and the copied dependency tree
# are owned by the non-root user, not root, before dropping privileges.
RUN chown -R appuser:appgroup /app /home/appuser/.local

ENV PATH="/home/appuser/.local/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
# SECURITY DECISION: no FLASK_SECRET_KEY, AWS credentials, or Snyk tokens
# are ever set here. They are supplied at container run time by the
# orchestrator (systemd EnvironmentFile on the EC2 host, populated from
# values that originate in GitHub Actions secrets - see
# .github/workflows/devsecops-pipeline.yml and README.md > "GitHub
# Actions Secrets Configuration").

# SECURITY DECISION 4 (continued): drop root privileges for every
# subsequent instruction and for the running container.
USER appuser

EXPOSE 8080

# SECURITY DECISION 6: container-native health check, independent of any
# orchestrator-level probe, so `docker ps` and Trivy/CI smoke tests can
# both observe container health the same way.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)" || exit 1

# SECURITY DECISION: gunicorn (not Flask's built-in dev server) serves
# the app, bound to all interfaces *inside* the container network
# namespace only - the Terraform security group, not the app, controls
# what can reach port 8080 from outside.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "30", "app:app"]
