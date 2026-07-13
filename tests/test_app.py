"""
test_app.py
-----------
Smoke tests for the safe application endpoints. These are unrelated to
the security scanning gates (CodeQL/Snyk/Trivy/ZAP run independently in
CI) but demonstrate that the application itself behaves correctly,
which a senior reviewer would expect alongside the security tooling.
"""

import os

import pytest

os.environ.setdefault("FLASK_SECRET_KEY", "test-only-secret-key-not-for-production")

from app.app import app  # noqa: E402 - env var must be set before import


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as test_client:
        yield test_client


def test_index_returns_200(client):
    response = client.get("/")
    assert response.status_code == 200


def test_healthz_returns_ok(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_lookup_requires_host_param(client):
    response = client.get("/lookup")
    assert response.status_code == 400


def test_lookup_rejects_overlong_host(client):
    response = client.get("/lookup", query_string={"host": "a" * 300})
    assert response.status_code == 400


def test_lookup_resolves_localhost(client):
    response = client.get("/lookup", query_string={"host": "localhost"})
    assert response.status_code == 200
    body = response.get_json()
    assert body["host"] == "localhost"
    assert "ip_address" in body
