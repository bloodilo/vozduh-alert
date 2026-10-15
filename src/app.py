"""active.json из Redis. Единственный маршрут; наплыв гасит nginx-микрокэш."""
import os

import redis.asyncio as aioredis
from aiohttp import web

r = aioredis.from_url("redis://" + os.environ.get("REDIS_HOST", "127.0.0.1") + ":6379")
EMPTY = b'{"updated": null, "cities": []}'


async def active(request):
    data = await r.get("active_json")
    return web.Response(
        body=data or EMPTY,
        content_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


async def health(request):
    ts = await r.get("active_ts")
    return web.Response(text=(ts or b"none").decode())


app = web.Application()
app.router.add_get("/active.json", active)
app.router.add_get("/healthz", health)
web.run_app(app, port=8080, access_log=None)
