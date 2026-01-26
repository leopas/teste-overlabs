from __future__ import annotations

import pytest


@pytest.mark.asyncio
async def test_readyz_reflects_dependencies(client, app_test):
    r = await client.get("/readyz")
    assert r.status_code == 200

    class BadCache:
        def ping(self):
            raise RuntimeError("down")

        def rate_limit_allow(self, ip, limit_per_minute):
            return True

        def get_json(self, key):
            return None

        def set_json(self, key, value, ttl_seconds):
            return None

    app_test.state.cache = BadCache()
    r2 = await client.get("/readyz")
    assert r2.status_code == 503

